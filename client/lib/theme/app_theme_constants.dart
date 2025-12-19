import 'package:flutter/material.dart';

/// PeerWave Theme Konstanten
/// 
/// Zentrale Definition aller Design-Tokens für konsistente UI.
class AppThemeConstants {
  // ============================================================================
  // FARBEN - Layout-spezifische Backgrounds
  // ============================================================================
  
  /// Sidebar Background (nur Native Desktop) - #0E1114 sehr dunkel
  static const Color sidebarBackground = Color(0xFF0E1114);
  
  /// Context Panel Background (Channels/People/Files Listen) - #14181D
  static const Color contextPanelBackground = Color(0xFF14181D);
  
  /// Main View Background (Chat/Activity Content) - #181C21
  static const Color mainViewBackground = Color(0xFF181C21);
  
  /// Input Background (TextField, Search) - #181D23
  static const Color inputBackground = Color(0xFF181D23);
  
  /// Background für App (außerhalb Layout-Bereiche) - #0E1218
  static const Color appBackground = Color(0xFF0E1218);
  
  // Text Opacities (als Farben für Performance)
  /// Items/Labels - 85% Weiß
  static const Color textPrimary = Color.fromRGBO(255, 255, 255, 0.85);
  
  /// Überschriften/Headers - 60% Grau
  static const Color textSecondary = Color.fromRGBO(255, 255, 255, 0.6);
  
  /// Aktiver Channel - Türkis 8% Background
  static const Color activeChannelBackground = Color.fromRGBO(14, 132, 129, 0.08);
  
  /// Aktiver Channel - Linker Border (Discord-Style, 2px)
  static const Color activeChannelBorder = Color(0xFF0E8481);
  
  /// Aktiver Channel - Border-Stil
  static Border get activeChannelBorderStyle => const Border(
    left: BorderSide(
      color: activeChannelBorder,
      width: borderWidthThick, // 2px für bessere Sichtbarkeit
    ),
  );
  
  // ============================================================================
  // SPACING - Konsistentes 6/12/20/26 System
  // ============================================================================
  
  /// Extra small spacing - 6px
  static const double spacingXs = 6.0;
  
  /// Small spacing - 12px (Standard für Padding)
  static const double spacingSm = 12.0;
  
  /// Medium spacing - 20px (Zwischen Sections)
  static const double spacingMd = 20.0;
  
  /// Large spacing - 26px (Zwischen großen Blöcken)
  static const double spacingLg = 26.0;
  
  // EdgeInsets Presets
  static const EdgeInsets paddingXs = EdgeInsets.all(spacingXs);
  static const EdgeInsets paddingSm = EdgeInsets.all(spacingSm);
  static const EdgeInsets paddingMd = EdgeInsets.all(spacingMd);
  static const EdgeInsets paddingLg = EdgeInsets.all(spacingLg);
  
  static const EdgeInsets paddingHorizontalXs = EdgeInsets.symmetric(horizontal: spacingXs);
  static const EdgeInsets paddingHorizontalSm = EdgeInsets.symmetric(horizontal: spacingSm);
  static const EdgeInsets paddingHorizontalMd = EdgeInsets.symmetric(horizontal: spacingMd);
  static const EdgeInsets paddingHorizontalLg = EdgeInsets.symmetric(horizontal: spacingLg);
  
  static const EdgeInsets paddingVerticalXs = EdgeInsets.symmetric(vertical: spacingXs);
  static const EdgeInsets paddingVerticalSm = EdgeInsets.symmetric(vertical: spacingSm);
  static const EdgeInsets paddingVerticalMd = EdgeInsets.symmetric(vertical: spacingMd);
  static const EdgeInsets paddingVerticalLg = EdgeInsets.symmetric(vertical: spacingLg);
  
  // ============================================================================
  // BORDER RADIUS - Erwachsener 14px Standard
  // ============================================================================
  
  /// Standard Radius - 14px (Buttons, Cards, Inputs)
  static const double radiusStandard = 14.0;
  
  /// Small Radius - 8px (Badges, kleine Chips)
  static const double radiusSmall = 8.0;
  
  /// Large Radius - 20px (Modals, große Cards)
  static const double radiusLarge = 20.0;
  
  /// Circle - für Avatare
  static const double radiusCircle = 999.0;
  
  // BorderRadius Presets
  static const BorderRadius borderRadiusStandard = BorderRadius.all(Radius.circular(radiusStandard));
  static const BorderRadius borderRadiusSmall = BorderRadius.all(Radius.circular(radiusSmall));
  static const BorderRadius borderRadiusLarge = BorderRadius.all(Radius.circular(radiusLarge));
  
  // ============================================================================
  // ANIMATIONEN - Subtile, schnelle Transitions
  // ============================================================================
  
  /// Fast - 150ms (Hover, Badge updates, kleine State-Änderungen)
  static const Duration animationFast = Duration(milliseconds: 150);
  
  /// Normal - 250ms (Navigation, Selection, Tab-Wechsel)
  static const Duration animationNormal = Duration(milliseconds: 250);
  
  /// Slow - 350ms (Drawer open/close, Modal erscheinen)
  static const Duration animationSlow = Duration(milliseconds: 350);
  
  /// Standard Curve - Smooth & natural
  static const Curve animationCurve = Curves.easeInOutCubic;
  
  /// Fade Curve - für Opacity-Transitions
  static const Curve fadeCurve = Curves.easeOut;
  
  /// Slide Curve - für Position-Transitions
  static const Curve slideCurve = Curves.easeInOutQuart;
  
  // ============================================================================
  // ICONS - Filled Style
  // ============================================================================
  
  /// Standard Icon Size - 24px
  static const double iconSizeStandard = 24.0;
  
  /// Small Icon Size - 20px (in ListTiles)
  static const double iconSizeSmall = 20.0;
  
  /// Large Icon Size - 32px (Headers, Featured)
  static const double iconSizeLarge = 32.0;
  
  // Icon Presets mit filled: true
  static const IconData iconActivity = Icons.bolt;
  static const IconData iconPeople = Icons.people;
  static const IconData iconFiles = Icons.folder;
  static const IconData iconChannels = Icons.tag;
  static const IconData iconMessages = Icons.chat_bubble;
  static const IconData iconSettings = Icons.settings_rounded; // Rounded wirkt gefüllter
  static const IconData iconNotifications = Icons.notifications;
  static const IconData iconSearch = Icons.search;
  static const IconData iconAdd = Icons.add_circle;
  static const IconData iconMore = Icons.more_vert;
  
  // ============================================================================
  // TYPOGRAPHY - Größen & Weights
  // ============================================================================
  
  /// Header 1 - 24px bold
  static const double fontSizeH1 = 24.0;
  static const FontWeight fontWeightH1 = FontWeight.bold;
  
  /// Header 2 - 20px semibold
  static const double fontSizeH2 = 20.0;
  static const FontWeight fontWeightH2 = FontWeight.w600;
  
  /// Header 3 - 16px semibold
  static const double fontSizeH3 = 16.0;
  static const FontWeight fontWeightH3 = FontWeight.w600;
  
  /// Context Panel Header - 11px bold UPPERCASE (für "CHANNELS", "PEOPLE")
  static const double fontSizeContextHeader = 11.0;
  static const FontWeight fontWeightContextHeader = FontWeight.w700;
  static const double letterSpacingContextHeader = 1.5;
  
  /// Body - 14px normal
  static const double fontSizeBody = 14.0;
  static const FontWeight fontWeightBody = FontWeight.normal;
  
  /// Caption - 12px normal
  static const double fontSizeCaption = 12.0;
  static const FontWeight fontWeightCaption = FontWeight.normal;
  
  /// Context Panel Header TextStyle
  static const TextStyle contextHeaderStyle = TextStyle(
    fontSize: fontSizeContextHeader,
    fontWeight: fontWeightContextHeader,
    letterSpacing: letterSpacingContextHeader,
    color: textSecondary,
    height: 1.5,
  );
  
  // ============================================================================
  // LAYOUT - Breakpoints & Dimensions
  // ============================================================================
  
  /// Sidebar Width (Native Desktop) - 72px
  static const double sidebarWidth = 72.0;
  
  /// Context Panel Width - 280px
  static const double contextPanelWidth = 280.0;
  
  /// Mobile Breakpoint
  static const double breakpointMobile = 600.0;
  
  /// Tablet Breakpoint
  static const double breakpointTablet = 840.0;
  
  /// Desktop Breakpoint
  static const double breakpointDesktop = 1200.0;
  
  // ============================================================================
  // ELEVATION & SHADOWS
  // ============================================================================
  
  /// Keine Elevation (flaches Design bevorzugt)
  static const double elevationNone = 0.0;
  
  /// Subtile Elevation für Hover
  static const double elevationHover = 2.0;
  
  /// Modal/Dialog Elevation
  static const double elevationModal = 8.0;
  
  // ============================================================================
  // BORDERS
  // ============================================================================
  
  /// Standard Border Width - 1px
  static const double borderWidthStandard = 1.0;
  
  /// Thick Border Width - 2px
  static const double borderWidthThick = 2.0;
  
  /// Aktiver Channel Border (wird oben als Border verwendet, nicht mehr hier)
  @Deprecated('Use activeChannelBorderStyle instead')
  static BorderSide get activeChannelBorderSide => const BorderSide(
    color: activeChannelBorder,
    width: borderWidthStandard,
  );
  
  // ============================================================================
  // ANIMATIONS - Specific Implementations
  // ============================================================================
  
  /// Page Transition Builder - Slide von rechts
  static Widget buildPageTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1.0, 0.0),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: animation,
        curve: slideCurve,
      )),
      child: FadeTransition(
        opacity: animation,
        child: child,
      ),
    );
  }
  
  /// Badge Appear Animation
  static Widget animatedBadge({
    required Widget child,
    required bool show,
  }) {
    return AnimatedScale(
      scale: show ? 1.0 : 0.0,
      duration: animationFast,
      curve: Curves.easeOut,
      child: AnimatedOpacity(
        opacity: show ? 1.0 : 0.0,
        duration: animationFast,
        curve: fadeCurve,
        child: child,
      ),
    );
  }
  
  /// ListTile Selection Animation
  static Decoration animatedSelectionDecoration({
    required bool selected,
    required Color highlightColor,
  }) {
    return BoxDecoration(
      color: selected ? activeChannelBackground : Colors.transparent,
      borderRadius: borderRadiusStandard,
      border: selected
          ? Border(
              left: BorderSide(
                color: highlightColor,
                width: borderWidthThick,
              ),
            )
          : null,
    );
  }
  
  /// Hover Effect für ListTiles
  static Color getHoverColor(bool isHovered, Color primaryColor) {
    return isHovered 
        ? primaryColor.withValues(alpha: 0.05) 
        : Colors.transparent;
  }
  
  // ============================================================================
  // HELPER METHODS
  // ============================================================================
  
  /// Creates a squared icon container (replaces CircleAvatar for consistent design)
  /// Use this for channel icons, group icons, etc. to match squared profile pictures
  static Widget squaredIconContainer({
    required IconData icon,
    required Color backgroundColor,
    required Color iconColor,
    double size = 40.0,
    double? iconSize,
    double? borderRadius,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(borderRadius ?? radiusSmall), // Default 8px like avatars
      ),
      child: Icon(
        icon,
        color: iconColor,
        size: iconSize ?? (size * 0.5), // Icon is 50% of container size
      ),
    );
  }
  
  /// Erstellt AnimatedContainer mit Standard-Settings
  static Widget animatedContainer({
    required Widget child,
    Duration? duration,
    Curve? curve,
    Color? color,
    Decoration? decoration,
  }) {
    return AnimatedContainer(
      duration: duration ?? animationNormal,
      curve: curve ?? animationCurve,
      color: color,
      decoration: decoration,
      child: child,
    );
  }
  
  /// Erstellt ListTile mit Standard-Styling
  static ListTile styledListTile({
    Widget? leading,
    required Widget title,
    Widget? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
    bool selected = false,
  }) {
    return ListTile(
      dense: true,
      contentPadding: paddingHorizontalSm,
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      onTap: onTap,
      selected: selected,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadiusStandard,
      ),
    );
  }
  
  /// Erstellt InputDecoration mit Standard-Styling
  static InputDecoration inputDecoration({
    String? hintText,
    String? labelText,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hintText,
      labelText: labelText,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: inputBackground,
      border: OutlineInputBorder(
        borderRadius: borderRadiusStandard,
        borderSide: BorderSide.none,
      ),
      contentPadding: paddingSm,
    );
  }
}

/// Extension für schnellen Zugriff auf Theme-Konstanten
extension ThemeConstantsX on BuildContext {
  /// Direkter Zugriff: context.spacing.sm
  AppThemeConstants get constants => AppThemeConstants();
  
  /// Schnellzugriff für Spacing
  _SpacingHelper get spacing => _SpacingHelper();
  
  /// Schnellzugriff für Radius
  _RadiusHelper get radius => _RadiusHelper();
  
  /// Schnellzugriff für Animation
  _AnimationHelper get animation => _AnimationHelper();
}

class _SpacingHelper {
  double get xs => AppThemeConstants.spacingXs;
  double get sm => AppThemeConstants.spacingSm;
  double get md => AppThemeConstants.spacingMd;
  double get lg => AppThemeConstants.spacingLg;
}

class _RadiusHelper {
  double get small => AppThemeConstants.radiusSmall;
  double get standard => AppThemeConstants.radiusStandard;
  double get large => AppThemeConstants.radiusLarge;
  BorderRadius get standardBorder => AppThemeConstants.borderRadiusStandard;
}

class _AnimationHelper {
  Duration get fast => AppThemeConstants.animationFast;
  Duration get normal => AppThemeConstants.animationNormal;
  Duration get slow => AppThemeConstants.animationSlow;
  Curve get curve => AppThemeConstants.animationCurve;
}

