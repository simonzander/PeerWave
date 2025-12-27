// Platform-aware window abstraction
// Uses real bitsdojo_window on desktop, stubs on mobile
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:bitsdojo_window/bitsdojo_window.dart' as bitsdojo;

void doWhenWindowReady(void Function() callback) {
  if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    bitsdojo.doWhenWindowReady(callback);
  }
  // No-op on mobile and web
}

class _AppWindowProxy {
  set minSize(dynamic size) {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      bitsdojo.appWindow.minSize = size;
    }
  }

  set size(dynamic size) {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      bitsdojo.appWindow.size = size;
    }
  }

  set alignment(dynamic alignment) {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      bitsdojo.appWindow.alignment = alignment;
    }
  }

  set title(String title) {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      bitsdojo.appWindow.title = title;
    }
  }

  void show() {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      bitsdojo.appWindow.show();
    }
  }

  void hide() {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      bitsdojo.appWindow.hide();
    }
  }

  void close() {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      bitsdojo.appWindow.close();
    }
  }

  void restore() {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      bitsdojo.appWindow.restore();
    }
  }
}

final appWindow = _AppWindowProxy();
