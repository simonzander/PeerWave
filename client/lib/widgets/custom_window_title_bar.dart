import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:bitsdojo_window/bitsdojo_window.dart';
import '../services/system_tray_service_web.dart'
    if (dart.library.io) '../services/system_tray_service.dart';

class CustomWindowTitleBar extends StatelessWidget {
  final String title;
  final Color? backgroundColor;

  const CustomWindowTitleBar({
    super.key,
    this.title = 'PeerWave',
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    // Only show on desktop platforms
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final bgColor = backgroundColor ?? theme.colorScheme.surface;
    final textColor = theme.colorScheme.onSurface;

    return WindowTitleBarBox(
      child: Container(
        color: bgColor,
        child: Row(
          children: [
            Expanded(
              child: MoveWindow(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Container(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12.0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // App logo
                          Image.asset(
                            'assets/images/peerwave.png',
                            width: 18,
                            height: 18,
                          ),
                          const SizedBox(width: 6),
                          // Title - constrained to prevent overflow
                          Flexible(
                            child: Text(
                              title,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: textColor,
                                decoration: TextDecoration.none,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            // Window control buttons
            WindowButtons(),
          ],
        ),
      ),
    );
  }
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buttonColors = WindowButtonColors(
      iconNormal: theme.colorScheme.onSurface,
      mouseOver: theme.colorScheme.surfaceContainerHighest,
      mouseDown: theme.colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.8,
      ),
      iconMouseOver: theme.colorScheme.onSurface,
      iconMouseDown: theme.colorScheme.onSurface,
    );

    final closeButtonColors = WindowButtonColors(
      mouseOver: theme.colorScheme.error,
      mouseDown: theme.colorScheme.error.withValues(alpha: 0.8),
      iconNormal: theme.colorScheme.onSurface,
      iconMouseOver: theme.colorScheme.onError,
      iconMouseDown: theme.colorScheme.onError,
    );

    return Row(
      children: [
        MinimizeWindowButton(colors: buttonColors),
        MaximizeWindowButton(colors: buttonColors),
        // Custom close button that hides to tray instead of closing
        WindowButton(
          colors: closeButtonColors,
          iconBuilder: (buttonContext) =>
              CloseIcon(color: buttonContext.iconColor),
          onPressed: () async {
            if (!kIsWeb) {
              // Hide to system tray instead of closing
              final systemTray = SystemTrayService();
              await systemTray.hideWindow();
            }
          },
        ),
      ],
    );
  }
}

/// Wrapper widget to handle window title bar for different platforms
class WindowTitleBarWrapper extends StatelessWidget {
  final Widget child;
  final String title;

  const WindowTitleBarWrapper({
    super.key,
    required this.child,
    this.title = 'PeerWave',
  });

  @override
  Widget build(BuildContext context) {
    // Only show custom title bar on desktop platforms
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
      return child;
    }

    return Column(
      children: [
        CustomWindowTitleBar(title: title),
        Expanded(child: child),
      ],
    );
  }
}
