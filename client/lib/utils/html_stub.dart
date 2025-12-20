/// Stub implementation for dart:html on non-web platforms
/// This file is used when building for mobile/desktop platforms
library;

class Window {
  dynamic get sessionStorage => throw UnsupportedError('sessionStorage is only available on web');
  dynamic get crypto => throw UnsupportedError('crypto is only available on web');
}

final window = Window();
