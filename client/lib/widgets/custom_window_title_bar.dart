import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:bitsdojo_window/bitsdojo_window.dart';

class CustomWindowTitleBar extends StatelessWidget {
  final String title;
  final Color? backgroundColor;
  
  const CustomWindowTitleBar({
    Key? key,
    this.title = 'PeerWave',
    this.backgroundColor,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Only show on desktop platforms
    if (kIsWeb) {
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
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    children: [
                      // App icon/logo (optional)
                      Icon(
                        Icons.waves,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
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
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buttonColors = WindowButtonColors(
      iconNormal: theme.colorScheme.onSurface,
      mouseOver: theme.colorScheme.surfaceVariant,
      mouseDown: theme.colorScheme.surfaceVariant.withOpacity(0.8),
      iconMouseOver: theme.colorScheme.onSurface,
      iconMouseDown: theme.colorScheme.onSurface,
    );

    final closeButtonColors = WindowButtonColors(
      mouseOver: const Color(0xFFD32F2F),
      mouseDown: const Color(0xFFB71C1C),
      iconNormal: theme.colorScheme.onSurface,
      iconMouseOver: Colors.white,
      iconMouseDown: Colors.white,
    );

    return Row(
      children: [
        MinimizeWindowButton(colors: buttonColors),
        MaximizeWindowButton(colors: buttonColors),
        CloseWindowButton(colors: closeButtonColors),
      ],
    );
  }
}

/// Wrapper widget to handle window title bar for different platforms
class WindowTitleBarWrapper extends StatelessWidget {
  final Widget child;
  final String title;
  
  const WindowTitleBarWrapper({
    Key? key,
    required this.child,
    this.title = 'PeerWave',
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
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
