import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/theme_provider.dart';
import '../widgets/theme_selector_dialog.dart';
import '../widgets/theme_widgets.dart';
import '../pages/theme_settings_page.dart';

/// THEME SYSTEM INTEGRATION EXAMPLES
/// 
/// This file shows various ways to integrate the Material 3 Theme System
/// into your PeerWave screens. Copy the patterns you need!

// ============================================================================
// EXAMPLE 1: Simple Screen with Theme FAB
// ============================================================================
class Example1_SimpleWithFAB extends StatelessWidget {
  const Example1_SimpleWithFAB({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Screen'),
      ),
      body: Center(
        child: Text(
          'Hello PeerWave!',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
      ),
      // Add this line to get a theme selector FAB!
      floatingActionButton: const QuickThemeFab(),
    );
  }
}

// ============================================================================
// EXAMPLE 2: Screen with Theme Toggle in AppBar
// ============================================================================
class Example2_WithAppBarToggle extends StatelessWidget {
  const Example2_WithAppBarToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Screen'),
        actions: [
          // Add this to get a quick theme toggle button!
          const ThemeToggleButton(),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {},
          ),
        ],
      ),
      body: const Center(child: Text('Content here')),
    );
  }
}

// ============================================================================
// EXAMPLE 3: Settings Menu with Theme Item
// ============================================================================
class Example3_SettingsMenu extends StatelessWidget {
  const Example3_SettingsMenu({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // Profile
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('Profile'),
            onTap: () {},
          ),
          
          // Notifications
          ListTile(
            leading: const Icon(Icons.notifications),
            title: const Text('Notifications'),
            onTap: () {},
          ),
          
          // Theme - Add this!
          ThemeMenuItem(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ThemeSettingsPage()),
              );
            },
          ),
          
          // Or use this for a quick dialog:
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Quick Theme Picker'),
            onTap: () => ThemeSelectorDialog.show(context),
          ),
          
          // More settings...
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('Privacy'),
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// EXAMPLE 4: Programmatic Theme Control
// ============================================================================
class Example4_ProgrammaticControl extends StatelessWidget {
  const Example4_ProgrammaticControl({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    
    return Scaffold(
      appBar: AppBar(title: const Text('Theme Control')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Show current theme info
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Current Theme',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text('Scheme: ${themeProvider.currentScheme.name}'),
                  Text('Mode: ${themeProvider.themeMode.name}'),
                  Text('Description: ${themeProvider.currentScheme.description}'),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Theme mode controls
          Text(
            'Change Theme Mode:',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          
          ElevatedButton(
            onPressed: () => themeProvider.setLightMode(),
            child: const Text('Set Light Mode'),
          ),
          const SizedBox(height: 8),
          
          ElevatedButton(
            onPressed: () => themeProvider.setDarkMode(),
            child: const Text('Set Dark Mode'),
          ),
          const SizedBox(height: 8),
          
          ElevatedButton(
            onPressed: () => themeProvider.setSystemMode(),
            child: const Text('Set System Mode'),
          ),
          
          const Divider(height: 32),
          
          // Color scheme controls
          Text(
            'Change Color Scheme:',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          
          ElevatedButton(
            onPressed: () => themeProvider.setColorScheme('peerwave_dark'),
            child: const Text('PeerWave Dark'),
          ),
          const SizedBox(height: 8),
          
          ElevatedButton(
            onPressed: () => themeProvider.setColorScheme('monochrome_dark'),
            child: const Text('Monochrome Dark'),
          ),
          const SizedBox(height: 8),
          
          ElevatedButton(
            onPressed: () => themeProvider.setColorScheme('oceanic_green'),
            child: const Text('Oceanic Green'),
          ),
          
          const Divider(height: 32),
          
          // Reset
          ElevatedButton.icon(
            onPressed: () => themeProvider.resetToDefaults(),
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset to Defaults'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Open full selector
          FilledButton.icon(
            onPressed: () => ThemeSelectorDialog.show(context),
            icon: const Icon(Icons.palette_outlined),
            label: const Text('Open Theme Selector'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// EXAMPLE 5: Using Theme Colors
// ============================================================================
class Example5_UsingColors extends StatelessWidget {
  const Example5_UsingColors({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Scaffold(
      appBar: AppBar(title: const Text('Theme Colors')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ColorCard(
            'Primary',
            color: colorScheme.primary,
            onColor: colorScheme.onPrimary,
          ),
          _ColorCard(
            'Primary Container',
            color: colorScheme.primaryContainer,
            onColor: colorScheme.onPrimaryContainer,
          ),
          _ColorCard(
            'Secondary',
            color: colorScheme.secondary,
            onColor: colorScheme.onSecondary,
          ),
          _ColorCard(
            'Tertiary',
            color: colorScheme.tertiary,
            onColor: colorScheme.onTertiary,
          ),
          _ColorCard(
            'Error',
            color: colorScheme.error,
            onColor: colorScheme.onError,
          ),
          _ColorCard(
            'Surface',
            color: colorScheme.surface,
            onColor: colorScheme.onSurface,
          ),
        ],
      ),
    );
  }
}

class _ColorCard extends StatelessWidget {
  final String name;
  final Color color;
  final Color onColor;

  const _ColorCard(this.name, {required this.color, required this.onColor});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          name,
          style: TextStyle(
            color: onColor,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// EXAMPLE 6: Responsive Layout with Theme
// ============================================================================
class Example6_ResponsiveWithTheme extends StatelessWidget {
  const Example6_ResponsiveWithTheme({super.key});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final colorScheme = Theme.of(context).colorScheme;
    
    // Mobile: FAB
    // Tablet/Desktop: AppBar button
    final isMobile = width < 600;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Responsive Theme'),
        actions: isMobile ? null : [
          const ThemeToggleButton(),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.devices,
              size: 64,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              isMobile ? 'Mobile Layout' : 'Desktop Layout',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Width: ${width.toInt()}px',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: isMobile ? const QuickThemeFab() : null,
    );
  }
}

// ============================================================================
// HOW TO USE THESE EXAMPLES
// ============================================================================
// 
// 1. Import what you need:
//    - For FAB: import 'widgets/theme_widgets.dart';
//    - For Dialog: import 'widgets/theme_selector_dialog.dart';
//    - For Settings Page: import 'pages/theme_settings_page.dart';
//    - For Provider: import 'theme/theme_provider.dart';
//
// 2. Choose the integration style that fits your screen:
//    - Simple screens → Add QuickThemeFab
//    - Main screens → Add ThemeToggleButton to AppBar
//    - Settings → Add ThemeMenuItem or route to ThemeSettingsPage
//    - Custom controls → Use ThemeProvider directly
//
// 3. Access theme colors:
//    final colorScheme = Theme.of(context).colorScheme;
//    colorScheme.primary, .secondary, .tertiary, etc.
//
// 4. Access theme typography:
//    Theme.of(context).textTheme.displayLarge
//    Theme.of(context).textTheme.headlineMedium
//    Theme.of(context).textTheme.bodyLarge
//    etc.
//
// For complete documentation, see: THEME_SYSTEM_USAGE_GUIDE.md

