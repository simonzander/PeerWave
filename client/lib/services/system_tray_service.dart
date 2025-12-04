import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path/path.dart' as path;

/// Service for managing system tray functionality on desktop platforms
class SystemTrayService with TrayListener {
  static final SystemTrayService _instance = SystemTrayService._internal();
  factory SystemTrayService() => _instance;
  SystemTrayService._internal();

  bool _isInitialized = false;

  /// Initialize system tray and window management
  Future<void> initialize() async {
    if (_isInitialized || kIsWeb) return;

    try {
      debugPrint('[SystemTray] Starting initialization...');
      
      // Get icon path
      final iconPath = _getTrayIconPath();
      debugPrint('[SystemTray] Using icon path: $iconPath');
      
      // Check if icon file exists
      final iconFile = File(iconPath);
      if (!await iconFile.exists()) {
        debugPrint('[SystemTray] ⚠️ WARNING: Icon file does not exist at: $iconPath');
      }
      
      // Initialize tray manager
      debugPrint('[SystemTray] Setting tray icon...');
      await trayManager.setIcon(iconPath);
      debugPrint('[SystemTray] Tray icon set successfully');
      
      trayManager.addListener(this);
      debugPrint('[SystemTray] Listener added');

      // Set up tray menu
      debugPrint('[SystemTray] Setting up tray menu...');
      await _updateTrayMenu();
      debugPrint('[SystemTray] Tray menu set');

      // Configure autostart
      debugPrint('[SystemTray] Configuring autostart...');
      await _setupAutostart();

      _isInitialized = true;
      debugPrint('[SystemTray] ✅ Initialized successfully');
    } catch (e, stackTrace) {
      debugPrint('[SystemTray] ❌ Initialization failed: $e');
      debugPrint('[SystemTray] Stack trace: $stackTrace');
    }
  }

  /// Get platform-specific tray icon path
  String _getTrayIconPath() {
    if (Platform.isWindows) {
      // Get the directory where the executable is located
      final exePath = Platform.resolvedExecutable;
      final exeDir = path.dirname(exePath);
      
      // In development, icon is in windows/runner/resources/
      // In release build, icon should be in data/flutter_assets/ or root
      final devIconPath = path.join(
        path.dirname(path.dirname(exeDir)), // Go up from build/windows/x64/runner/Debug or Release
        'windows',
        'runner',
        'resources',
        'app_icon.ico',
      );
      
      // Check if dev path exists
      if (File(devIconPath).existsSync()) {
        return devIconPath;
      }
      
      // Try release path (next to exe)
      final releaseIconPath = path.join(exeDir, 'app_icon.ico');
      if (File(releaseIconPath).existsSync()) {
        return releaseIconPath;
      }
      
      // Fallback to dev path even if it doesn't exist (will be logged)
      return devIconPath;
    } else if (Platform.isMacOS) {
      return 'assets/icon/app_icon.png';
    } else if (Platform.isLinux) {
      return 'assets/icon/app_icon.png';
    }
    return 'assets/icon/app_icon.png';
  }

  /// Update tray menu items
  Future<void> _updateTrayMenu() async {
    // Check autostart status (may not be supported on all platforms)
    String autostartLabel = 'Start at Login';
    try {
      final isEnabled = await launchAtStartup.isEnabled();
      autostartLabel = isEnabled ? '✓ Start at Login' : 'Start at Login';
    } catch (e) {
      debugPrint('[SystemTray] Autostart status check not supported: $e');
    }
    
    final menu = Menu(
      items: [
        MenuItem(
          key: 'show',
          label: 'Show PeerWave',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'autostart',
          label: autostartLabel,
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: 'Quit PeerWave',
        ),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  /// Setup autostart configuration
  Future<void> _setupAutostart() async {
    try {
      // Configure package name and title for autostart
      launchAtStartup.setup(
        appName: 'PeerWave',
        appPath: Platform.resolvedExecutable,
      );

      debugPrint('[SystemTray] Autostart configured');
    } catch (e) {
      debugPrint('[SystemTray] Failed to setup autostart: $e');
    }
  }

  /// Enable or disable autostart
  Future<void> setAutostart(bool enabled) async {
    try {
      if (enabled) {
        await launchAtStartup.enable();
        debugPrint('[SystemTray] ✅ Autostart enabled');
      } else {
        await launchAtStartup.disable();
        debugPrint('[SystemTray] ❌ Autostart disabled');
      }
      await _updateTrayMenu();
    } catch (e) {
      debugPrint('[SystemTray] Failed to set autostart: $e');
    }
  }

  /// Check if autostart is enabled
  Future<bool> isAutostartEnabled() async {
    try {
      return await launchAtStartup.isEnabled();
    } catch (e) {
      debugPrint('[SystemTray] Autostart check not supported: $e');
      // On Windows, check registry manually if needed
      return false;
    }
  }

  /// Show the application window
  Future<void> showWindow() async {
    appWindow.show();
    appWindow.restore();
  }

  /// Hide the application window
  Future<void> hideWindow() async {
    appWindow.hide();
  }

  /// Quit the application completely
  Future<void> quitApp() async {
    appWindow.close();
  }

  // TrayListener implementation
  @override
  void onTrayIconMouseDown() {
    // Show window on tray icon click
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    // Show context menu on right click
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await showWindow();
        break;
      case 'autostart':
        final isEnabled = await isAutostartEnabled();
        await setAutostart(!isEnabled);
        break;
      case 'quit':
        await quitApp();
        break;
    }
  }



  /// Dispose resources
  void dispose() {
    trayManager.removeListener(this);
  }
}
