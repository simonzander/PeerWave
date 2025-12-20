/// Layout Configuration for Adaptive/Responsive Design
/// 
/// Defines breakpoints and layout types following Material 3 guidelines.
/// Use this to determine which navigation pattern and UI density to use.
library;

/// Material 3 Breakpoints
/// 
/// Based on Material Design 3 responsive guidelines:
/// - Mobile: < 600px (smartphones in portrait)
/// - Tablet: 600-840px (tablets in portrait, large phones in landscape)
/// - Desktop: > 840px (tablets in landscape, laptops, desktops)
class LayoutBreakpoints {
  LayoutBreakpoints._(); // Private constructor - static class only

  /// Mobile breakpoint (smartphones)
  /// < 600px: Use Bottom NavigationBar, Small AppBar
  static const double mobile = 600;

  /// Tablet breakpoint (small tablets, large phones landscape)
  /// 600-840px: Use NavigationRail, Medium AppBar
  static const double tablet = 840;

  /// Desktop breakpoint (tablets landscape, laptops, desktops)
  /// > 840px: Use NavigationDrawer, Large AppBar
  static const double desktop = 840;

  /// Extra-wide desktop breakpoint (optional)
  /// > 1200px: Use wider margins, multi-column layouts
  static const double desktopWide = 1200;

  /// Minimum supported width (prevent layout collapse)
  static const double minWidth = 320;

  /// Maximum content width (for very wide screens)
  static const double maxContentWidth = 1600;
}

/// Layout Type based on screen width
/// 
/// Determines which navigation pattern and UI density to use:
/// - Mobile: Bottom NavigationBar, compact UI
/// - Tablet: NavigationRail, comfortable UI
/// - Desktop: NavigationDrawer (permanent), spacious UI
enum LayoutType {
  /// Mobile layout (<600px)
  /// - Bottom NavigationBar (3-5 items)
  /// - Small AppBar (64dp)
  /// - Single column content
  /// - Compact padding (8-12dp)
  mobile,

  /// Tablet layout (600-840px)
  /// - NavigationRail (left side, icons + labels)
  /// - Medium AppBar (112dp)
  /// - Single or dual column content
  /// - Comfortable padding (16dp)
  tablet,

  /// Desktop layout (>840px)
  /// - NavigationDrawer (permanent, full labels)
  /// - Large AppBar (152dp, optional extended)
  /// - Multi-column content possible
  /// - Spacious padding (24dp)
  desktop,
}

/// Layout configuration helper
/// 
/// Provides methods to determine layout type, padding, and other
/// responsive design properties based on screen width.
class LayoutConfig {
  LayoutConfig._(); // Private constructor - static class only

  /// Get layout type based on screen width
  /// 
  /// ```dart
  /// final width = MediaQuery.of(context).size.width;
  /// final layoutType = LayoutConfig.getLayoutType(width);
  /// 
  /// switch (layoutType) {
  ///   case LayoutType.mobile:
  ///     // Show bottom nav
  ///   case LayoutType.tablet:
  ///     // Show navigation rail
  ///   case LayoutType.desktop:
  ///     // Show navigation drawer
  /// }
  /// ```
  static LayoutType getLayoutType(double width) {
    if (width < LayoutBreakpoints.mobile) {
      return LayoutType.mobile;
    } else if (width < LayoutBreakpoints.desktop) {
      return LayoutType.tablet;
    } else {
      return LayoutType.desktop;
    }
  }

  /// Get horizontal padding based on layout type
  /// 
  /// Material 3 padding guidelines:
  /// - Mobile: 16dp
  /// - Tablet: 24dp
  /// - Desktop: 24-32dp
  static double getHorizontalPadding(LayoutType type) {
    switch (type) {
      case LayoutType.mobile:
        return 16.0;
      case LayoutType.tablet:
        return 24.0;
      case LayoutType.desktop:
        return 32.0;
    }
  }

  /// Get content max width (for centering on wide screens)
  static double getContentMaxWidth(LayoutType type) {
    switch (type) {
      case LayoutType.mobile:
        return double.infinity; // Full width
      case LayoutType.tablet:
        return 840.0;
      case LayoutType.desktop:
        return LayoutBreakpoints.maxContentWidth;
    }
  }

  /// Get navigation rail width (for tablet layout)
  static double get navigationRailWidth => 80.0;

  /// Get navigation rail width (extended with labels)
  static double get navigationRailWidthExtended => 200.0;

  /// Get navigation drawer width (for desktop layout)
  static double get navigationDrawerWidth => 360.0;

  /// Get AppBar height based on layout type
  /// 
  /// Material 3 AppBar heights:
  /// - Small: 64dp (mobile)
  /// - Medium: 112dp (tablet)
  /// - Large: 152dp (desktop)
  static double getAppBarHeight(AppBarSize size) {
    switch (size) {
      case AppBarSize.small:
        return 64.0;
      case AppBarSize.medium:
        return 112.0;
      case AppBarSize.large:
        return 152.0;
    }
  }

  /// Get recommended AppBar size for layout type
  static AppBarSize getRecommendedAppBarSize(LayoutType type) {
    switch (type) {
      case LayoutType.mobile:
        return AppBarSize.small;
      case LayoutType.tablet:
        return AppBarSize.medium;
      case LayoutType.desktop:
        return AppBarSize.large;
    }
  }

  /// Check if layout should use compact UI
  static bool isCompact(LayoutType type) {
    return type == LayoutType.mobile;
  }

  /// Check if layout should use comfortable UI
  static bool isComfortable(LayoutType type) {
    return type == LayoutType.tablet;
  }

  /// Check if layout should use spacious UI
  static bool isSpacious(LayoutType type) {
    return type == LayoutType.desktop;
  }

  /// Get number of columns for grid layouts
  static int getGridColumns(LayoutType type, {int mobileColumns = 1}) {
    switch (type) {
      case LayoutType.mobile:
        return mobileColumns;
      case LayoutType.tablet:
        return mobileColumns * 2;
      case LayoutType.desktop:
        return mobileColumns * 3;
    }
  }

  /// Get card elevation based on layout type
  /// Material 3 uses subtle elevations
  static double getCardElevation(LayoutType type) {
    return type == LayoutType.mobile ? 1.0 : 2.0;
  }

  /// Get border radius based on layout type
  /// Material 3 shape system: 12-28dp
  static double getBorderRadius(LayoutType type) {
    switch (type) {
      case LayoutType.mobile:
        return 12.0;
      case LayoutType.tablet:
        return 16.0;
      case LayoutType.desktop:
        return 20.0;
    }
  }
}

/// AppBar size variants (Material 3)
/// 
/// Material 3 defines three AppBar heights:
/// - Small: 64dp (default, always visible)
/// - Medium: 112dp (with subtitle or larger text)
/// - Large: 152dp (with extended header, hero images)
enum AppBarSize {
  /// Small AppBar (64dp)
  /// - Single line title
  /// - Standard density
  /// - Best for mobile
  small,

  /// Medium AppBar (112dp)
  /// - Title + subtitle
  /// - More breathing room
  /// - Best for tablet
  medium,

  /// Large AppBar (152dp)
  /// - Large title
  /// - Extended header area
  /// - Optional hero image
  /// - Best for desktop
  large,
}

/// Helper extension on BuildContext for easy layout access
/// 
/// Usage (if uncommented):
/// ```dart
/// final layoutType = context.layoutType;
/// final padding = context.horizontalPadding;
/// ```
/// 
/// Note: Commented out to avoid BuildContext import in config file.
/// To use, uncomment and add: import 'package:flutter/widgets.dart';
// extension LayoutConfigExtensions on BuildContext {
//   LayoutType get layoutType {
//     final width = MediaQuery.of(this).size.width;
//     return LayoutConfig.getLayoutType(width);
//   }
//   
//   double get horizontalPadding {
//     return LayoutConfig.getHorizontalPadding(layoutType);
//   }
//   
//   bool get isMobile => layoutType == LayoutType.mobile;
//   bool get isTablet => layoutType == LayoutType.tablet;
//   bool get isDesktop => layoutType == LayoutType.desktop;
// }

