import 'package:flutter/material.dart';
import '../../config/layout_config.dart';

/// Adaptive Scaffold - Material 3 Responsive Layout
/// 
/// Automatically switches between three navigation patterns based on screen width:
/// - Mobile (<600px): Bottom NavigationBar
/// - Tablet (600-840px): NavigationRail (left side)
/// - Desktop (>840px): NavigationDrawer (permanent)
/// 
/// Usage:
/// ```dart
/// AdaptiveScaffold(
///   selectedIndex: _selectedIndex,
///   onDestinationSelected: (index) => setState(() => _selectedIndex = index),
///   destinations: [
///     NavigationDestination(icon: Icon(Icons.message), label: 'Messages'),
///     NavigationDestination(icon: Icon(Icons.people), label: 'People'),
///     NavigationDestination(icon: Icon(Icons.folder), label: 'Files'),
///   ],
///   body: _pages[_selectedIndex],
/// )
/// ```
class AdaptiveScaffold extends StatelessWidget {
  /// Current selected destination index
  final int selectedIndex;

  /// Callback when a destination is selected
  final ValueChanged<int> onDestinationSelected;

  /// List of navigation destinations (3-5 recommended)
  final List<NavigationDestination> destinations;

  /// Main content body
  final Widget body;

  /// Optional app bar title (String or Widget)
  final dynamic appBarTitle;

  /// Optional app bar actions
  final List<Widget>? appBarActions;

  /// Optional floating action button
  final Widget? floatingActionButton;

  /// Optional drawer (for mobile hamburger menu)
  final Widget? drawer;

  /// Optional leading widget in navigation (e.g., logo, profile)
  final Widget? navigationLeading;

  /// Optional trailing widget in navigation (e.g., settings)
  final Widget? navigationTrailing;

  /// Whether to show app bar (default: true)
  final bool showAppBar;

  /// AppBar size override (null = automatic based on layout)
  final AppBarSize? appBarSize;

  /// Navigation rail extended (shows labels) - only for tablet
  final bool navigationRailExtended;

  /// Custom app bar (overrides automatic app bar)
  final PreferredSizeWidget? customAppBar;

  const AdaptiveScaffold({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.body,
    this.appBarTitle,
    this.appBarActions,
    this.floatingActionButton,
    this.drawer,
    this.navigationLeading,
    this.navigationTrailing,
    this.showAppBar = true,
    this.appBarSize,
    this.navigationRailExtended = false,
    this.customAppBar,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutType = LayoutConfig.getLayoutType(constraints.maxWidth);
        
        switch (layoutType) {
          case LayoutType.mobile:
            return _buildMobileLayout(context);
          case LayoutType.tablet:
            return _buildTabletLayout(context);
          case LayoutType.desktop:
            return _buildDesktopLayout(context);
        }
      },
    );
  }

  /// Mobile layout: Bottom NavigationBar
  Widget _buildMobileLayout(BuildContext context) {
    return Scaffold(
      appBar: customAppBar ?? (showAppBar ? _buildAppBar(context, AppBarSize.small) : null),
      body: body,
      bottomNavigationBar: _buildBottomNavigationBar(context),
      floatingActionButton: floatingActionButton,
      drawer: drawer,
    );
  }

  /// Tablet layout: NavigationRail (left side)
  Widget _buildTabletLayout(BuildContext context) {
    return Scaffold(
      appBar: customAppBar ?? (showAppBar ? _buildAppBar(context, AppBarSize.medium) : null),
      body: Row(
        children: [
          _buildNavigationRail(context),
          Expanded(child: body),
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }

  /// Desktop layout: NavigationDrawer (permanent)
  Widget _buildDesktopLayout(BuildContext context) {
    return Scaffold(
      appBar: customAppBar ?? (showAppBar ? _buildAppBar(context, AppBarSize.large) : null),
      body: Row(
        children: [
          _buildNavigationDrawer(context),
          Expanded(
            child: body,
          ),
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }

  /// Build AppBar with size variant
  PreferredSizeWidget _buildAppBar(BuildContext context, AppBarSize size) {
    final colorScheme = Theme.of(context).colorScheme;
    final height = LayoutConfig.getAppBarHeight(appBarSize ?? size);

    Widget? titleWidget;
    if (appBarTitle != null) {
      if (appBarTitle is String) {
        titleWidget = Text(
          appBarTitle as String,
          style: _getAppBarTextStyle(context, size),
        );
      } else if (appBarTitle is Widget) {
        titleWidget = appBarTitle as Widget;
      }
    }

    return PreferredSize(
      preferredSize: Size.fromHeight(height),
      child: AppBar(
        title: titleWidget,
        actions: appBarActions,
        centerTitle: size == AppBarSize.small ? false : true,
        elevation: 0,
        scrolledUnderElevation: 2,
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
      ),
    );
  }

  /// Get AppBar text style based on size
  TextStyle? _getAppBarTextStyle(BuildContext context, AppBarSize size) {
    final textTheme = Theme.of(context).textTheme;
    
    switch (size) {
      case AppBarSize.small:
        return textTheme.titleLarge;
      case AppBarSize.medium:
        return textTheme.headlineSmall;
      case AppBarSize.large:
        return textTheme.headlineMedium;
    }
  }

  /// Build Bottom NavigationBar (Mobile)
  Widget _buildBottomNavigationBar(BuildContext context) {
    return NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      destinations: destinations,
      elevation: 3,
    );
  }

  /// Build NavigationRail (Tablet)
  Widget _buildNavigationRail(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      extended: navigationRailExtended,
      leading: navigationLeading,
      trailing: navigationTrailing != null 
        ? Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: navigationTrailing,
              ),
            ),
          )
        : null,
      destinations: destinations.map((destination) {
        return NavigationRailDestination(
          icon: destination.icon,
          selectedIcon: destination.selectedIcon ?? destination.icon,
          label: Text(destination.label),
        );
      }).toList(),
      backgroundColor: colorScheme.surface,
      elevation: 1,
    );
  }

  /// Build NavigationDrawer (Desktop)
  Widget _buildNavigationDrawer(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return SizedBox(
      width: LayoutConfig.navigationDrawerWidth,
      child: NavigationDrawer(
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        children: [
          // Leading (header)
          if (navigationLeading != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: navigationLeading,
            ),
          
          // Destinations
          ...destinations.map((destination) {
            return NavigationDrawerDestination(
              icon: destination.icon,
              selectedIcon: destination.selectedIcon ?? destination.icon,
              label: Text(destination.label),
            );
          }),
          
          // Trailing (footer)
          if (navigationTrailing != null) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: navigationTrailing,
            ),
          ],
        ],
        backgroundColor: colorScheme.surface,
        elevation: 1,
      ),
    );
  }
}

/// Adaptive Scaffold with Nested Navigation
/// 
/// For apps with primary and secondary navigation levels.
/// Example: Main nav (Messages/People/Files) + Sub nav (DMs/Channels)
class AdaptiveNestedScaffold extends StatelessWidget {
  final int primarySelectedIndex;
  final ValueChanged<int> onPrimaryDestinationSelected;
  final List<NavigationDestination> primaryDestinations;
  
  final int? secondarySelectedIndex;
  final ValueChanged<int>? onSecondaryDestinationSelected;
  final List<NavigationDestination>? secondaryDestinations;
  
  final Widget body;
  final dynamic appBarTitle;
  final List<Widget>? appBarActions;
  final Widget? floatingActionButton;

  const AdaptiveNestedScaffold({
    super.key,
    required this.primarySelectedIndex,
    required this.onPrimaryDestinationSelected,
    required this.primaryDestinations,
    this.secondarySelectedIndex,
    this.onSecondaryDestinationSelected,
    this.secondaryDestinations,
    required this.body,
    this.appBarTitle,
    this.appBarActions,
    this.floatingActionButton,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutType = LayoutConfig.getLayoutType(constraints.maxWidth);
        final hasSecondary = secondaryDestinations != null && secondaryDestinations!.isNotEmpty;
        
        if (layoutType == LayoutType.desktop && hasSecondary) {
          // Desktop: Show both primary (drawer) and secondary (rail)
          return _buildDesktopNestedLayout(context);
        } else {
          // Mobile/Tablet or no secondary: Use standard scaffold
          return AdaptiveScaffold(
            selectedIndex: primarySelectedIndex,
            onDestinationSelected: onPrimaryDestinationSelected,
            destinations: primaryDestinations,
            body: hasSecondary ? _buildSecondaryNavigation(context) : body,
            appBarTitle: appBarTitle,
            appBarActions: appBarActions,
            floatingActionButton: floatingActionButton,
          );
        }
      },
    );
  }

  Widget _buildDesktopNestedLayout(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Scaffold(
      appBar: AppBar(
        title: appBarTitle is String ? Text(appBarTitle as String) : appBarTitle as Widget?,
        actions: appBarActions,
        elevation: 0,
        backgroundColor: colorScheme.surface,
      ),
      body: Row(
        children: [
          // Primary navigation (drawer)
          SizedBox(
            width: LayoutConfig.navigationDrawerWidth,
            child: NavigationDrawer(
              selectedIndex: primarySelectedIndex,
              onDestinationSelected: onPrimaryDestinationSelected,
              children: primaryDestinations.map((dest) {
                return NavigationDrawerDestination(
                  icon: dest.icon,
                  label: Text(dest.label),
                );
              }).toList(),
            ),
          ),
          
          // Secondary navigation (rail)
          if (secondaryDestinations != null) ...[
            NavigationRail(
              selectedIndex: secondarySelectedIndex ?? 0,
              onDestinationSelected: onSecondaryDestinationSelected ?? (_) {},
              destinations: secondaryDestinations!.map((dest) {
                return NavigationRailDestination(
                  icon: dest.icon,
                  label: Text(dest.label),
                );
              }).toList(),
            ),
          ],
          
          // Content
          Expanded(child: body),
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }

  Widget _buildSecondaryNavigation(BuildContext context) {
    if (secondaryDestinations == null || secondaryDestinations!.isEmpty) {
      return body;
    }
    
    return Column(
      children: [
        // Secondary navigation tabs
        Container(
          height: 48,
          color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: secondaryDestinations!.length,
            itemBuilder: (context, index) {
              final dest = secondaryDestinations![index];
              final isSelected = index == (secondarySelectedIndex ?? 0);
              
              return InkWell(
                onTap: () => onSecondaryDestinationSelected?.call(index),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    border: isSelected 
                      ? Border(
                          bottom: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        )
                      : null,
                  ),
                  child: Row(
                    children: [
                      dest.icon,
                      const SizedBox(width: 8),
                      Text(dest.label),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}
