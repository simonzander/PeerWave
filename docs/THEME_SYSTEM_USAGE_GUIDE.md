# Material 3 Theme System - Usage Guide

## Overview

The PeerWave app now includes a complete Material 3 theme system with:
- **8 Color Schemes**: PeerWave Dark (default), Monochrome Dark/Light, Oceanic Green, Sunset Orange, Lavender Purple, Forest Green, Cherry Red
- **3 Theme Modes**: Light, Dark, System (follows device settings)
- **Automatic Persistence**: Theme preferences are saved and restored on app restart
- **Live Updates**: Theme changes apply instantly without app restart

## Quick Start

### 1. Add Theme Selector to Any Screen

#### Option A: FloatingActionButton (Quick Access)
```dart
import 'package:client/widgets/theme_widgets.dart';

Scaffold(
  appBar: AppBar(title: Text('My Page')),
  body: MyContent(),
  floatingActionButton: const QuickThemeFab(), // Add this!
)
```

#### Option B: AppBar Button
```dart
import 'package:client/widgets/theme_widgets.dart';

AppBar(
  title: Text('My Page'),
  actions: [
    const ThemeToggleButton(), // Add this!
  ],
)
```

#### Option C: Settings Menu Item
```dart
import 'package:client/widgets/theme_widgets.dart';
import 'package:client/pages/theme_settings_page.dart';

ListView(
  children: [
    ThemeMenuItem(
      onTap: () {
        Navigator.push(context, 
          MaterialPageRoute(builder: (_) => ThemeSettingsPage())
        );
      },
    ),
    // ... other menu items
  ],
)
```

### 2. Open Theme Selector Programmatically

```dart
import 'package:client/widgets/theme_selector_dialog.dart';

ElevatedButton(
  onPressed: () => ThemeSelectorDialog.show(context),
  child: Text('Change Theme'),
)
```

### 3. Access Theme Settings Page

```dart
import 'package:client/pages/theme_settings_page.dart';

Navigator.push(
  context,
  MaterialPageRoute(builder: (_) => const ThemeSettingsPage()),
)
```

## Available Color Schemes

| ID | Name | Description | Primary Color |
|---|---|---|---|
| `peerwave_dark` | PeerWave Dark | Default turquoise theme | #00D1B2 |
| `monochrome_dark` | Monochrome Dark | Clean black & white | #FFFFFF |
| `monochrome_light` | Monochrome Light | Pure light theme | #000000 |
| `oceanic_green` | Oceanic Green | Ocean-inspired teal | #00897B |
| `sunset_orange` | Sunset Orange | Warm orange glow | #FB8C00 |
| `lavender_purple` | Lavender Purple | Soft purple tones | #7E57C2 |
| `forest_green` | Forest Green | Deep forest green | #43A047 |
| `cherry_red` | Cherry Red | Bold cherry red | #E53935 |

## Programmatic Theme Control

### Change Theme Mode

```dart
import 'package:provider/provider.dart';
import 'package:client/theme/theme_provider.dart';

// Get provider
final themeProvider = context.read<ThemeProvider>();

// Set specific mode
themeProvider.setLightMode();
themeProvider.setDarkMode();
themeProvider.setSystemMode();

// Or use setThemeMode
themeProvider.setThemeMode(ThemeMode.dark);
```

### Change Color Scheme

```dart
import 'package:provider/provider.dart';
import 'package:client/theme/theme_provider.dart';

final themeProvider = context.read<ThemeProvider>();

// Change to a specific scheme
themeProvider.setColorScheme('peerwave_dark');
themeProvider.setColorScheme('monochrome_dark');
themeProvider.setColorScheme('oceanic_green');
// ... etc
```

### Reset to Defaults

```dart
final themeProvider = context.read<ThemeProvider>();
themeProvider.resetToDefaults(); // Resets to PeerWave Dark + System mode
```

### Get Current Settings

```dart
final themeProvider = context.watch<ThemeProvider>();

// Current theme mode
ThemeMode mode = themeProvider.themeMode;

// Current color scheme ID
String schemeId = themeProvider.colorSchemeId;

// Current scheme details
ColorSchemeOption scheme = themeProvider.currentScheme;
print('Current: ${scheme.name} - ${scheme.description}');

// Get generated themes
ThemeData lightTheme = themeProvider.lightTheme;
ThemeData darkTheme = themeProvider.darkTheme;
```

## Integration Examples

### Example 1: Dashboard with Theme FAB

```dart
import 'package:flutter/material.dart';
import 'package:client/widgets/theme_widgets.dart';

class DashboardPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Dashboard'),
        actions: [
          const ThemeToggleButton(),
        ],
      ),
      body: Center(
        child: Text('Dashboard Content'),
      ),
      floatingActionButton: const QuickThemeFab(),
    );
  }
}
```

### Example 2: Settings Page with Theme Menu

```dart
import 'package:flutter/material.dart';
import 'package:client/widgets/theme_widgets.dart';
import 'package:client/pages/theme_settings_page.dart';

class SettingsPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Settings')),
      body: ListView(
        children: [
          ThemeMenuItem(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ThemeSettingsPage()),
              );
            },
          ),
          ListTile(
            title: Text('Notifications'),
            leading: Icon(Icons.notifications),
          ),
          ListTile(
            title: Text('Privacy'),
            leading: Icon(Icons.privacy_tip),
          ),
          // ... more settings
        ],
      ),
    );
  }
}
```

### Example 3: Custom Theme Switcher

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:client/theme/theme_provider.dart';
import 'package:client/theme/color_schemes.dart';

class CustomThemeSwitcher extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final schemes = ColorSchemeOptions.all;
    
    return DropdownButton<String>(
      value: themeProvider.colorSchemeId,
      items: schemes.map((scheme) {
        return DropdownMenuItem(
          value: scheme.id,
          child: Row(
            children: [
              Icon(scheme.icon),
              SizedBox(width: 8),
              Text(scheme.name),
            ],
          ),
        );
      }).toList(),
      onChanged: (newSchemeId) {
        if (newSchemeId != null) {
          themeProvider.setColorScheme(newSchemeId);
        }
      },
    );
  }
}
```

## Material 3 Component Themes

All Material 3 components are themed automatically:

### Navigation
- **AppBar**: Surface container with elevation
- **NavigationBar**: Bottom navigation with indicators
- **NavigationRail**: Side navigation for desktop
- **NavigationDrawer**: Drawer menu with rounded items

### Buttons
- **ElevatedButton**: With shadow elevation
- **FilledButton**: Solid primary color
- **OutlinedButton**: With border outline
- **TextButton**: Minimal text-only
- **FloatingActionButton**: Large/small with shadow

### Input
- **TextField**: Outlined with label animation
- **Chip**: Filter/choice/input chips
- **Switch**: Material 3 track & thumb

### Content
- **Card**: Elevated surface with rounded corners
- **Dialog**: Centered modal dialogs
- **BottomSheet**: Slide-up panels
- **SnackBar**: Bottom notification bars

### Lists
- **ListTile**: Enhanced leading/trailing
- **Divider**: Subtle separation lines

## Typography Scale

Material 3 type scale is fully implemented:

```dart
// Display (57px, 45px, 36px)
Text('Large Display', style: Theme.of(context).textTheme.displayLarge)
Text('Medium Display', style: Theme.of(context).textTheme.displayMedium)
Text('Small Display', style: Theme.of(context).textTheme.displaySmall)

// Headline (32px, 28px, 24px)
Text('Large Headline', style: Theme.of(context).textTheme.headlineLarge)
Text('Medium Headline', style: Theme.of(context).textTheme.headlineMedium)
Text('Small Headline', style: Theme.of(context).textTheme.headlineSmall)

// Title (22px, 16px, 14px)
Text('Large Title', style: Theme.of(context).textTheme.titleLarge)
Text('Medium Title', style: Theme.of(context).textTheme.titleMedium)
Text('Small Title', style: Theme.of(context).textTheme.titleSmall)

// Body (16px, 14px)
Text('Large Body', style: Theme.of(context).textTheme.bodyLarge)
Text('Medium Body', style: Theme.of(context).textTheme.bodyMedium)
Text('Small Body', style: Theme.of(context).textTheme.bodySmall)

// Label (14px, 12px, 11px)
Text('Large Label', style: Theme.of(context).textTheme.labelLarge)
Text('Medium Label', style: Theme.of(context).textTheme.labelMedium)
Text('Small Label', style: Theme.of(context).textTheme.labelSmall)
```

## Color System Access

```dart
final colorScheme = Theme.of(context).colorScheme;

// Primary colors
colorScheme.primary
colorScheme.onPrimary
colorScheme.primaryContainer
colorScheme.onPrimaryContainer

// Secondary colors
colorScheme.secondary
colorScheme.onSecondary
colorScheme.secondaryContainer
colorScheme.onSecondaryContainer

// Tertiary colors
colorScheme.tertiary
colorScheme.onTertiary
colorScheme.tertiaryContainer
colorScheme.onTertiaryContainer

// Error colors
colorScheme.error
colorScheme.onError
colorScheme.errorContainer
colorScheme.onErrorContainer

// Surface colors
colorScheme.surface
colorScheme.onSurface
colorScheme.surfaceVariant
colorScheme.onSurfaceVariant
colorScheme.surfaceContainerHighest
colorScheme.surfaceContainerHigh
colorScheme.surfaceContainer
colorScheme.surfaceContainerLow
colorScheme.surfaceContainerLowest

// Background & other
colorScheme.background
colorScheme.onBackground
colorScheme.outline
colorScheme.outlineVariant
colorScheme.shadow
colorScheme.scrim
colorScheme.inverseSurface
colorScheme.onInverseSurface
colorScheme.inversePrimary
```

## Adding New Color Schemes

To add a new color scheme, edit `lib/theme/color_schemes.dart`:

```dart
static ColorScheme myNewScheme(Brightness brightness) {
  if (brightness == Brightness.dark) {
    return const ColorScheme(
      brightness: Brightness.dark,
      primary: Color(0xFF...), // Your primary color
      onPrimary: Color(0xFF...),
      // ... complete all required colors
    );
  } else {
    return const ColorScheme(
      brightness: Brightness.light,
      primary: Color(0xFF...),
      // ... complete all required colors
    );
  }
}
```

Then add it to `ColorSchemeOptions.all`:

```dart
static final List<ColorSchemeOption> all = [
  // ... existing schemes
  ColorSchemeOption(
    id: 'my_new_scheme',
    name: 'My New Scheme',
    description: 'Description here',
    icon: Icons.star, // Choose an icon
    previewColor: Color(0xFF...), // Preview color
    schemeBuilder: AppColorSchemes.myNewScheme,
  ),
];
```

## Testing Theme Changes

```dart
// Print debug info
final themeProvider = context.read<ThemeProvider>();
themeProvider.printDebugInfo();

// Output:
// [ThemeProvider] Current State:
//   Theme Mode: ThemeMode.dark
//   Color Scheme: peerwave_dark (PeerWave Dark)
//   Initialized: true
```

## Troubleshooting

### Theme not applying?
- Ensure ThemeProvider is initialized in main.dart before runApp()
- Check that MultiProvider includes ThemeProvider
- Verify MaterialApp.router uses Consumer<ThemeProvider>

### Theme not persisting?
- Check browser console for IndexedDB errors (web)
- Verify SharedPreferences permissions (mobile)
- Try calling `themeProvider.resetToDefaults()` to reset storage

### Colors look wrong?
- Ensure `useMaterial3: true` is set in ThemeData
- Check if custom theme properties override Material 3 defaults
- Verify ColorScheme has all required colors defined

## Files Structure

```
client/lib/
├── theme/
│   ├── color_schemes.dart      # 8 color schemes + ColorSchemeOption
│   ├── app_theme.dart          # Material 3 ThemeData generator
│   └── theme_provider.dart     # State management + persistence
├── services/
│   └── preferences_service.dart # IndexedDB + SharedPreferences
├── widgets/
│   ├── theme_selector_dialog.dart # Full theme selector dialog
│   └── theme_widgets.dart      # Quick theme access widgets
└── pages/
    └── theme_settings_page.dart # Dedicated theme settings page
```

## Support

For issues or feature requests related to the theme system, please check:
- MATERIAL3_THEME_IMPLEMENTATION_PLAN.md - Implementation details
- Phase 2 is complete, Phase 3-7 may add responsive/adaptive features
