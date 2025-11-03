# Adaptive Layout System - Migration Examples

## Quick Reference

### Before (Old Custom Layout)
```dart
class DashboardPage extends StatefulWidget {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Row(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              double width = sidebarWidth;
              if (constraints.maxWidth < 600) width = 80;
              return SizedBox(width: width, child: SidebarPanel(...));
            },
          ),
          Expanded(
            child: Container(
              color: const Color(0xFF36393F),  // ❌ Hardcoded
              child: contentWidget,
            ),
          ),
        ],
      ),
    );
  }
}
```

### After (Material 3 Adaptive Layout)
```dart
class DashboardPage extends StatefulWidget {
  @override
  Widget build(BuildContext context) {
    return AdaptiveScaffold(
      selectedIndex: _selectedIndex,
      onDestinationSelected: (index) => setState(() => _selectedIndex = index),
      destinations: [
        NavigationDestination(
          icon: Icon(Icons.message_outlined),
          selectedIcon: Icon(Icons.message),
          label: 'Messages',
        ),
        NavigationDestination(
          icon: Icon(Icons.people_outline),
          selectedIcon: Icon(Icons.people),
          label: 'People',
        ),
        NavigationDestination(
          icon: Icon(Icons.folder_outlined),
          selectedIcon: Icon(Icons.folder),
          label: 'Files',
        ),
      ],
      appBarTitle: 'PeerWave',
      appBarActions: [
        const ThemeToggleButton(),
        IconButton(icon: Icon(Icons.settings), onTap: () {}),
      ],
      body: _pages[_selectedIndex],  // ✅ Theme colors auto-applied
    );
  }
}
```

## Benefits

✅ **Automatic Navigation Pattern**
- Mobile: Bottom NavigationBar
- Tablet: NavigationRail
- Desktop: NavigationDrawer

✅ **Material 3 Colors**
- No hardcoded colors
- Theme-aware automatically
- Responds to theme changes

✅ **Responsive AppBar**
- Small (64dp) on mobile
- Medium (112dp) on tablet
- Large (152dp) on desktop

✅ **Less Code**
- ~300 lines → ~50 lines
- No manual breakpoint handling
- No manual navigation switching

## Migration Steps

### 1. Define Navigation Destinations
```dart
final List<NavigationDestination> _destinations = [
  NavigationDestination(
    icon: Icon(Icons.message_outlined),
    selectedIcon: Icon(Icons.message),
    label: 'Direct Messages',
  ),
  NavigationDestination(
    icon: Icon(Icons.tag_outlined),
    selectedIcon: Icon(Icons.tag),
    label: 'Channels',
  ),
  NavigationDestination(
    icon: Icon(Icons.people_outline),
    selectedIcon: Icon(Icons.people),
    label: 'People',
  ),
  NavigationDestination(
    icon: Icon(Icons.folder_outlined),
    selectedIcon: Icon(Icons.folder),
    label: 'Files',
  ),
];
```

### 2. Track Selected Index
```dart
int _selectedIndex = 0;

void _onDestinationSelected(int index) {
  setState(() {
    _selectedIndex = index;
  });
}
```

### 3. Create Page List
```dart
late final List<Widget> _pages = [
  DirectMessagesScreen(),
  ChannelsScreen(),
  PeopleScreen(),
  FileManagerScreen(),
];
```

### 4. Replace Scaffold
```dart
@override
Widget build(BuildContext context) {
  return AdaptiveScaffold(
    selectedIndex: _selectedIndex,
    onDestinationSelected: _onDestinationSelected,
    destinations: _destinations,
    appBarTitle: 'PeerWave',
    appBarActions: [
      const ThemeToggleButton(),
    ],
    body: _pages[_selectedIndex],
  );
}
```

## Color Migration

### Before → After

| Old | New |
|-----|-----|
| `Colors.grey[850]` | `colorScheme.surface` |
| `Colors.grey[900]` | `colorScheme.surfaceVariant` |
| `Color(0xFF36393F)` | `colorScheme.surfaceContainerHighest` |
| `Colors.white` | `colorScheme.onSurface` |
| `Colors.white54` | `colorScheme.onSurfaceVariant` |
| `Colors.grey[700]` | `colorScheme.outline` |

### Usage
```dart
final colorScheme = Theme.of(context).colorScheme;

Container(
  color: colorScheme.surface,  // ✅ Not Colors.grey[850]
  child: Text(
    'Hello',
    style: TextStyle(color: colorScheme.onSurface),  // ✅ Not Colors.white
  ),
)
```

## Testing Checklist

After migration, test:

- [ ] Resize window from 320px → 2560px
- [ ] Navigation switches at 600px and 840px
- [ ] Selected item highlighted correctly
- [ ] AppBar size changes at breakpoints
- [ ] Theme colors apply everywhere
- [ ] No hardcoded colors remain
- [ ] Navigation persists across layouts
- [ ] No layout overflow errors

## Common Patterns

### With FAB
```dart
AdaptiveScaffold(
  ...
  floatingActionButton: FloatingActionButton(
    onPressed: () {},
    child: Icon(Icons.add),
  ),
)
```

### With Drawer (Mobile)
```dart
AdaptiveScaffold(
  ...
  drawer: Drawer(
    child: ListView(
      children: [
        DrawerHeader(child: Text('Menu')),
        ListTile(title: Text('Settings')),
      ],
    ),
  ),
)
```

### With Custom AppBar
```dart
AdaptiveScaffold(
  ...
  customAppBar: AdaptiveAppBar(
    title: 'Custom Title',
    subtitle: 'With Subtitle',
    size: AppBarSize.large,
  ),
)
```

### With Navigation Header/Footer
```dart
AdaptiveScaffold(
  ...
  navigationLeading: Column(
    children: [
      CircleAvatar(child: Icon(Icons.person)),
      SizedBox(height: 8),
      Text('John Doe'),
    ],
  ),
  navigationTrailing: IconButton(
    icon: Icon(Icons.settings),
    onPressed: () {},
  ),
)
```

## Files Created

1. `config/layout_config.dart` (274 lines)
   - Breakpoints, LayoutType enum, helpers

2. `widgets/adaptive/adaptive_scaffold.dart` (416 lines)
   - AdaptiveScaffold widget
   - AdaptiveNestedScaffold for complex apps
   - Auto navigation switching

3. `widgets/adaptive/adaptive_app_bar.dart` (342 lines)
   - AdaptiveAppBar with size variants
   - SliverAdaptiveAppBar for scrolling

**Total:** 1,032 lines of reusable adaptive layout code

## Next Steps

1. Migrate dashboard_page.dart
2. Test all breakpoints
3. Migrate remaining screens
4. Remove old sidebar_panel.dart
5. Update documentation
