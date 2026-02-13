import 'package:flutter/foundation.dart';

class WebPipBridge {
  WebPipBridge._();

  static final WebPipBridge instance = WebPipBridge._();

  bool get isSupported => false;

  Future<bool> open({
    String? title,
    String? status,
    int width = 360,
    int height = 220,
  }) async {
    return false;
  }

  Future<void> close() async {}

  void setStatus(String status) {}

  void setTitle(String title) {}

  void registerOnClose(VoidCallback callback) {}

  void updateLayout(Object? payload) {}
}
