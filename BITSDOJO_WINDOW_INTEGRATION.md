# bitsdojo_window Integration Guide

## Overview
We've integrated `bitsdojo_window` to provide a modern, customizable window frame for the PeerWave native desktop application.

## What Was Changed

### 1. Package Installation
Added to `pubspec.yaml`:
```yaml
bitsdojo_window: ^0.1.6  # Custom window frame for desktop
```

### 2. Windows Native Configuration
Updated `windows/runner/main.cpp`:
```cpp
#include <bitsdojo_window_windows/bitsdojo_window_plugin.h>
auto bdw = bitsdojo_window_configure(BDW_CUSTOM_FRAME | BDW_HIDE_ON_STARTUP);
```

This configures:
- `BDW_CUSTOM_FRAME`: Removes the default Windows title bar, allowing custom UI
- `BDW_HIDE_ON_STARTUP`: Hides the window initially until Flutter is ready

### 3. Flutter Integration
Added to `lib/main.dart`:
```dart
import 'package:bitsdojo_window/bitsdojo_window.dart';

// In main() after runApp:
if (!kIsWeb) {
  doWhenWindowReady(() {
    const initialSize = Size(1280, 800);
    appWindow.minSize = const Size(800, 600);
    appWindow.size = initialSize;
    appWindow.alignment = Alignment.center;
    appWindow.title = "PeerWave";
    appWindow.show();
  });
}
```

### 4. Custom Title Bar Widget
Created `lib/widgets/custom_window_title_bar.dart`:
- `CustomWindowTitleBar`: Provides a styled title bar with minimize/maximize/close buttons
- `WindowButtons`: Standard window control buttons with hover effects
- `WindowTitleBarWrapper`: Convenience wrapper to add title bar to any widget

The title bar automatically:
- Adapts to your app's theme (light/dark mode)
- Shows the app icon and title
- Provides standard window controls
- Allows dragging the window
- Handles maximize/restore double-click

### 5. Integration in MaterialApp
Modified the `MaterialApp.router` builder to wrap content with the title bar on desktop.

## Features

### Window Control
```dart
// From anywhere in your app:
appWindow.maximize();
appWindow.minimize();
appWindow.restore();
appWindow.close();

// Window size management:
appWindow.size = Size(1024, 768);
appWindow.minSize = Size(800, 600);
appWindow.maxSize = Size(1920, 1080);

// Window positioning:
appWindow.position = Offset(100, 100);
appWindow.alignment = Alignment.center; // Center on screen

// Window state:
bool isMaximized = appWindow.isMaximized;
bool isVisible = appWindow.isVisible;
```

### Customization Options

#### Change Title Bar Colors
```dart
CustomWindowTitleBar(
  title: 'PeerWave',
  backgroundColor: Colors.blue.shade900,
)
```

#### Custom Close Button Action
You can override the close button behavior:
```dart
CloseWindowButton(
  onPressed: () {
    // Show confirmation dialog
    showDialog(...).then((confirmed) {
      if (confirmed) appWindow.close();
    });
  },
)
```

#### Different Title Bar Styles
Create variants for different sections:
```dart
// Dark style for video calls
CustomWindowTitleBar(
  title: 'Video Conference',
  backgroundColor: Colors.black87,
)

// Accent color for important windows
CustomWindowTitleBar(
  title: 'Settings',
  backgroundColor: theme.colorScheme.primaryContainer,
)
```

## Platform Support

- ✅ **Windows**: Fully supported with custom frame
- ✅ **macOS**: Supported (requires additional setup in `macos/runner/MainFlutterWindow.swift`)
- ✅ **Linux**: Supported (requires additional setup in `linux/my_application.cc`)
- ⚠️ **Web**: Not applicable (web apps run in browser)

## macOS Setup (Optional)

If you want to enable on macOS, edit `macos/runner/MainFlutterWindow.swift`:

```swift
import FlutterMacOS
import bitsdojo_window_macos

class MainFlutterWindow: BitsdojoWindow {
  override func bitsdojo_window_configure() -> UInt {
    return BDW_CUSTOM_FRAME | BDW_HIDE_ON_STARTUP
  }
  
  override func awakeFromNib() {
    // ... rest of your code
  }
}
```

## Linux Setup (Optional)

For Linux, edit `linux/my_application.cc`:

```cpp
#include <bitsdojo_window_linux/bitsdojo_window_plugin.h>

// In the activate function:
auto bdw = bitsdojo_window_from(window);
bdw->setCustomFrame(true);
// gtk_window_set_default_size(window, 1280, 720); // Comment this out
gtk_widget_show(GTK_WIDGET(window));
```

## Benefits

1. **Modern Look**: Native-like title bar that matches your app design
2. **Cross-Platform**: Same look across Windows, macOS, and Linux
3. **Customizable**: Full control over colors, icons, and behavior
4. **Themeable**: Automatically adapts to light/dark themes
5. **Lightweight**: No performance impact
6. **Professional**: Gives your app a polished, professional appearance

## Troubleshooting

### Window appears too large/small
Adjust the initial size in `main()`:
```dart
appWindow.size = Size(1280, 800); // Change to preferred size
```

### Title bar height issues
The default height is good for most cases, but you can adjust padding in `custom_window_title_bar.dart`.

### Window doesn't show
Ensure `appWindow.show()` is called in `doWhenWindowReady()`.

### Colors don't match theme
The title bar automatically uses theme colors. If needed, override:
```dart
CustomWindowTitleBar(
  backgroundColor: theme.colorScheme.surface,
)
```

## Next Steps

Consider these enhancements:
1. Add a menu bar to the title bar
2. Show connection status indicator in title bar
3. Add breadcrumb navigation in title bar
4. Implement custom window animations
5. Add window state persistence (remember size/position)

## Resources

- [bitsdojo_window Documentation](https://pub.dev/packages/bitsdojo_window)
- [GitHub Repository](https://github.com/bitsdojo/bitsdojo_window)
- [Example Applications](https://github.com/bitsdojo/bitsdojo_window/tree/main/bitsdojo_window/example)
