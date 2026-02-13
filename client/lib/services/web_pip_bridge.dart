import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';

@JS('peerwaveDocPiPSupported')
external JSBoolean _pipSupported();

@JS('peerwaveDocPiPOpen')
external JSPromise _pipOpen(JSObject options);

@JS('peerwaveDocPiPClose')
external JSPromise _pipClose();

@JS('peerwaveDocPiPSetStatus')
external void _pipSetStatus(JSString text);

@JS('peerwaveDocPiPSetTitle')
external void _pipSetTitle(JSString text);

@JS('peerwaveDocPiPUpdateLayout')
external void _pipUpdateLayout(JSAny? payload);

@JS('peerwaveDocPiPOnClose')
external set _onPipClose(PipCloseCallback callback);

@JS()
extension type PipCloseCallback(JSFunction _) {}

class WebPipBridge {
  WebPipBridge._();

  static final WebPipBridge instance = WebPipBridge._();

  bool get isSupported {
    try {
      return _pipSupported().toDart;
    } catch (_) {
      return false;
    }
  }

  Future<bool> open({
    String? title,
    String? status,
    int width = 360,
    int height = 220,
  }) async {
    if (!isSupported) return false;

    final options = JSObject();
    options.setProperty('title'.toJS, (title ?? 'Video Call').toJS);
    options.setProperty('status'.toJS, (status ?? '').toJS);
    options.setProperty('width'.toJS, width.toJS);
    options.setProperty('height'.toJS, height.toJS);

    try {
      final result = await _pipOpen(options).toDart;
      return result.dartify() == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> close() async {
    try {
      await _pipClose().toDart;
    } catch (_) {}
  }

  void setStatus(String status) {
    try {
      _pipSetStatus(status.toJS);
    } catch (_) {}
  }

  void setTitle(String title) {
    try {
      _pipSetTitle(title.toJS);
    } catch (_) {}
  }

  void registerOnClose(VoidCallback callback) {
    _onPipClose = PipCloseCallback(
      () {
        callback();
      }.toJS,
    );
  }

  void updateLayout(JSAny? payload) {
    try {
      _pipUpdateLayout(payload);
    } catch (_) {}
  }
}
