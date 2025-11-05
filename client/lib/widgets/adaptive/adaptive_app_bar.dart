import 'package:flutter/material.dart';
import '../../config/layout_config.dart';

/// Adaptive AppBar - Material 3 Size Variants
/// 
/// Provides three AppBar sizes following Material 3 guidelines:
/// - Small (64dp): Compact, single-line title, best for mobile
/// - Medium (112dp): Title + subtitle, comfortable spacing, best for tablet
/// - Large (152dp): Large title, extended header, best for desktop
/// 
/// Automatically selects size based on screen width if not specified.
/// 
/// Usage:
/// ```dart
/// AdaptiveAppBar(
///   title: 'My App',
///   size: AppBarSize.medium, // or null for automatic
///   subtitle: 'Dashboard',
///   actions: [IconButton(...)],
/// )
/// ```
class AdaptiveAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// Title text or widget
  final dynamic title;

  /// Optional subtitle (shown in Medium/Large sizes)
  final String? subtitle;

  /// Optional description (shown only in Large size)
  final String? description;

  /// AppBar size (null = automatic based on screen width)
  final AppBarSize? size;

  /// Action buttons in the app bar
  final List<Widget>? actions;

  /// Leading widget (back button, menu, etc.)
  final Widget? leading;

  /// Whether to automatically add leading widget
  final bool automaticallyImplyLeading;

  /// Whether to center the title
  final bool? centerTitle;

  /// Custom background color (null = use theme)
  final Color? backgroundColor;

  /// Custom foreground color (null = use theme)
  final Color? foregroundColor;

  /// Elevation (default: 0, scrolledUnder: 2)
  final double? elevation;

  /// Optional FlexibleSpaceBar for custom header
  final Widget? flexibleSpace;

  /// Optional bottom widget (e.g., TabBar)
  final PreferredSizeWidget? bottom;

  const AdaptiveAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.description,
    this.size,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.centerTitle,
    this.backgroundColor,
    this.foregroundColor,
    this.elevation,
    this.flexibleSpace,
    this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveSize = size ?? _getAutomaticSize(context);
    
    switch (effectiveSize) {
      case AppBarSize.small:
        return _buildSmallAppBar(context);
      case AppBarSize.medium:
        return _buildMediumAppBar(context);
      case AppBarSize.large:
        return _buildLargeAppBar(context);
    }
  }

  /// Determine AppBar size based on screen width
  AppBarSize _getAutomaticSize(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final layoutType = LayoutConfig.getLayoutType(width);
    return LayoutConfig.getRecommendedAppBarSize(layoutType);
  }

  /// Build Small AppBar (64dp) - Mobile
  Widget _buildSmallAppBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return AppBar(
      title: _buildTitle(context, AppBarSize.small),
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      actions: actions,
      centerTitle: centerTitle ?? false,
      elevation: elevation ?? 0,
      scrolledUnderElevation: 2,
      backgroundColor: backgroundColor ?? colorScheme.surface,
      foregroundColor: foregroundColor ?? colorScheme.onSurface,
      bottom: bottom,
    );
  }

  /// Build Medium AppBar (112dp) - Tablet
  Widget _buildMediumAppBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return SizedBox(
      height: preferredSize.height,
      child: AppBar(
        title: _buildTitle(context, AppBarSize.medium),
        leading: leading,
        automaticallyImplyLeading: automaticallyImplyLeading,
        actions: actions,
        centerTitle: centerTitle ?? true,
        elevation: elevation ?? 0,
        scrolledUnderElevation: 2,
        backgroundColor: backgroundColor ?? colorScheme.surface,
        foregroundColor: foregroundColor ?? colorScheme.onSurface,
        flexibleSpace: flexibleSpace,
        bottom: bottom,
      ),
    );
  }

  /// Build Large AppBar (152dp) - Desktop
  Widget _buildLargeAppBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    
    return SizedBox(
      height: preferredSize.height,
      child: AppBar(
        title: null, // We'll use flexibleSpace for custom layout
        leading: leading,
        automaticallyImplyLeading: automaticallyImplyLeading,
        actions: actions,
        elevation: elevation ?? 0,
        scrolledUnderElevation: 2,
        backgroundColor: backgroundColor ?? colorScheme.surface,
        foregroundColor: foregroundColor ?? colorScheme.onSurface,
        flexibleSpace: flexibleSpace ?? FlexibleSpaceBar(
          titlePadding: const EdgeInsets.only(left: 16, bottom: 16, right: 16),
          title: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              _buildTitle(context, AppBarSize.large),
              
              // Subtitle
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              
              // Description (only in large)
              if (description != null) ...[
                const SizedBox(height: 4),
                Text(
                  description!,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        bottom: bottom,
      ),
    );
  }

  /// Build title widget based on size
  Widget _buildTitle(BuildContext context, AppBarSize size) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    
    if (title is Widget) {
      return title as Widget;
    }
    
    final titleText = title.toString();
    final textStyle = _getTitleTextStyle(textTheme, colorScheme, size);
    
    return Text(titleText, style: textStyle);
  }

  /// Get text style for title based on size
  TextStyle? _getTitleTextStyle(
    TextTheme textTheme,
    ColorScheme colorScheme,
    AppBarSize size,
  ) {
    switch (size) {
      case AppBarSize.small:
        return textTheme.titleLarge?.copyWith(
          color: colorScheme.onSurface,
        );
      case AppBarSize.medium:
        return textTheme.headlineSmall?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.bold,
        );
      case AppBarSize.large:
        return textTheme.headlineMedium?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.bold,
        );
    }
  }

  @override
  Size get preferredSize {
    final effectiveSize = size ?? AppBarSize.small;
    final height = LayoutConfig.getAppBarHeight(effectiveSize);
    final bottomHeight = bottom?.preferredSize.height ?? 0;
    return Size.fromHeight(height + bottomHeight);
  }
}

/// Sliver Adaptive AppBar - For use with CustomScrollView
/// 
/// Provides collapsing/expanding behavior with size variants.
/// 
/// Usage:
/// ```dart
/// CustomScrollView(
///   slivers: [
///     SliverAdaptiveAppBar(
///       title: 'Scrolling App',
///       size: AppBarSize.large,
///       pinned: true,
///       floating: false,
///     ),
///     SliverList(...),
///   ],
/// )
/// ```
class SliverAdaptiveAppBar extends StatelessWidget {
  final dynamic title;
  final String? subtitle;
  final String? description;
  final AppBarSize? size;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final bool pinned;
  final bool floating;
  final bool snap;
  final Widget? flexibleSpace;
  final PreferredSizeWidget? bottom;

  const SliverAdaptiveAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.description,
    this.size,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.pinned = false,
    this.floating = false,
    this.snap = false,
    this.flexibleSpace,
    this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveSize = size ?? _getAutomaticSize(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final expandedHeight = LayoutConfig.getAppBarHeight(effectiveSize);
    
    return SliverAppBar(
      title: _buildTitle(context, effectiveSize),
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      actions: actions,
      expandedHeight: expandedHeight,
      pinned: pinned,
      floating: floating,
      snap: snap,
      backgroundColor: colorScheme.surface,
      foregroundColor: colorScheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 2,
      flexibleSpace: flexibleSpace ?? (effectiveSize == AppBarSize.large
        ? FlexibleSpaceBar(
            title: _buildLargeTitle(context, textTheme, colorScheme),
            titlePadding: const EdgeInsets.only(left: 16, bottom: 16, right: 16),
            background: Container(
              color: colorScheme.surface,
            ),
          )
        : null),
      bottom: bottom,
    );
  }

  AppBarSize _getAutomaticSize(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final layoutType = LayoutConfig.getLayoutType(width);
    return LayoutConfig.getRecommendedAppBarSize(layoutType);
  }

  Widget _buildTitle(BuildContext context, AppBarSize size) {
    if (title is Widget) return title as Widget;
    
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    
    TextStyle? textStyle;
    switch (size) {
      case AppBarSize.small:
        textStyle = textTheme.titleLarge;
        break;
      case AppBarSize.medium:
        textStyle = textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold);
        break;
      case AppBarSize.large:
        textStyle = textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold);
        break;
    }
    
    return Text(
      title.toString(),
      style: textStyle?.copyWith(color: colorScheme.onSurface),
    );
  }

  Widget _buildLargeTitle(
    BuildContext context,
    TextTheme textTheme,
    ColorScheme colorScheme,
  ) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toString(),
          style: textTheme.headlineMedium?.copyWith(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.bold,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (description != null) ...[
          const SizedBox(height: 4),
          Text(
            description!,
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

