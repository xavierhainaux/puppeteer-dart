
import 'dart:async';

import 'package:chrome_dev_tools/domains/dom.dart';
import 'package:chrome_dev_tools/domains/runtime.dart';
import 'package:chrome_dev_tools/src/connection.dart';
import 'package:chrome_dev_tools/src/page/dom_world.dart';
import 'package:chrome_dev_tools/src/page/frame_manager.dart';
import 'package:chrome_dev_tools/src/page/js_handle.dart';

const evaluationScriptUrl = '__puppeteer_evaluation_script__';
final RegExp sourceUrlRegExp = RegExp(r'^[\040\t]*\/\/[@#] sourceURL=\s*(\S*?)\s*$', multiLine: true);

class ExecutionContext {
  final Client client;
  final RuntimeApi runtimeApi;
  final DOMApi domApi;
  final ExecutionContextDescription context;
  final DomWorld world;

  ExecutionContext(this.client, this.context, this.world): runtimeApi = RuntimeApi(client), domApi = DOMApi(client);

  PageFrame get frame => world?.frame;

  Future evaluate(String pageFunction, [Map<String, dynamic> args]) async {
    var handle = await evaluateHandle(pageFunction, args);
    var result = await handle.jsonValue;
    await handle.dispose();
    return result;
  }

  Future<JsHandle> evaluateHandle(String pageFunction, [Map<String, dynamic> args]) async {
    String functionDeclaration = 'function(${args.keys.join(', ')}) { $pageFunction }';

    var result = await runtimeApi.callFunctionOn(functionDeclaration,
        executionContextId: context.id, arguments: args.values.map(_convertArgument).toList(),
        returnByValue: false, awaitPromise: true, userGesture: true);

    return _createJsHandle(result.result);
  }

  CallArgument _convertArgument(arg) {
    if (arg is BigInt) {
      return CallArgument(unserializableValue: UnserializableValue('$arg'));
    }
    if (arg is double) {
      if (arg == 0 && arg.isNegative) {
        return CallArgument(unserializableValue: UnserializableValue('-0'));
      }
      if (arg.isInfinite) {
        return CallArgument(
            unserializableValue: UnserializableValue((arg.isNegative ? '-' : '') + 'Infinity'));
      }
      if (arg.isNaN) {
        return CallArgument(
            unserializableValue: UnserializableValue('NaN'));
      }
    }
    if (arg is JsHandle) {
      if (arg.context != this) {
        throw Exception('JSHandles can be evaluated only in the context they were created!');
      }
      if (arg.isDisposed) {
        throw Exception('JSHandle is disposed!');
      }
      if (arg.remoteObject.unserializableValue != null) {
        return CallArgument(unserializableValue: arg.remoteObject.unserializableValue);
      }
      if (arg.remoteObject.objectId != null) {
        return CallArgument(objectId: arg.remoteObject.objectId);
      } else {
        return CallArgument(value: arg.remoteObject.value);
      }
    }
    return CallArgument(value: arg);
  }

  Future<JsHandle> queryObjects(JsHandle prototypeHandle) async {
    assert(!prototypeHandle.isDisposed, 'Prototype JSHandle is disposed!');
    assert(prototypeHandle.remoteObject.objectId != null, 'Prototype JSHandle must not be referencing primitive value');
    var response = await runtimeApi.queryObjects(prototypeHandle.remoteObject.objectId);

    return _createJsHandle(response);
  }

  Future<ElementHandle> adoptElementHandle(ElementHandle elementHandle) async {
    assert(elementHandle.context != this, 'Cannot adopt handle that already belongs to this execution context');
    assert(world != null, 'Cannot adopt handle without DOMWorld');

    var nodeInfo = await domApi.describeNode(objectId: elementHandle.remoteObject.objectId);
    var object = await domApi.resolveNode(backendNodeId: nodeInfo.backendNodeId, executionContextId: context.id);

    return _createJsHandle(object);
  }

  JsHandle _createJsHandle(RemoteObject remoteObject) => JsHandle.fromRemoteObject(this, remoteObject);
}