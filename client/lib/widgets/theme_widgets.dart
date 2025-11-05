import 'package:flutter/material.dart';
import '../widgets/theme_selector_dialog.dart';

/// Quick Theme FAB
/// 
/// A FloatingActionButton that can be added to any screen
/// for quick access to the theme selector dialog.
/// 
/// Usage:
/// ```dart
/// floatingActionButton: const QuickThemeFab(),
/// ```
class QuickThemeFab extends StatelessWidget {
  const QuickThemeFab({super.key});

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: () => ThemeSelectorDialog.show(context),
      tooltip: 'change theme',
      child: const Icon(Icons.palette_outlined),
    );
  }
}

/// Theme Toggle Button
/// 
/// A simple IconButton that can be added to an AppBar
/// to quickly toggle between light and dark mode.
/// 
/// Usage:
/// ```dart
/// actions: [
///   const ThemeToggleButton(),
/// ],
/// ```
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    
    return IconButton(
      onPressed: () => ThemeSelectorDialog.show(context),
      tooltip: 'change theme',
      icon: Icon(
        brightness == Brightness.dark 
          ? Icons.light_mode_outlined 
          : Icons.dark_mode_outlined,
      ),
    );
  }
}

/// Theme Menu Item
/// 
/// A ListTile that can be added to a settings menu or drawer
/// to navigate to theme settings.
/// 
/// Usage:
/// ```dart
/// ThemeMenuItem(
///   onTap: () {
///     Navigator.push(context, 
///       MaterialPageRoute(builder: (_) => ThemeSettingsPage())
///     );
///   },
/// ),
/// ```
class ThemeMenuItem extends StatelessWidget {
  final VoidCallback? onTap;
  
  const ThemeMenuItem({
    super.key,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return ListTile(
      leading: Icon(
        Icons.palette_outlined,
        color: colorScheme.primary,
      ),
      title: const Text('Theme'),
      subtitle: const Text('Farbschema und Modus anpassen'),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap ?? () => ThemeSelectorDialog.show(context),
    );
  }
}

