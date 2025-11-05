import 'package:flutter/material.dart';

/// A reusable badge widget to display unread message counts
/// 
/// This widget is used throughout the app to show unread message counts:
/// - Navigation bars (collapsed state)
/// - List items (channels, users)
/// - Desktop drawer items
/// 
/// Features:
/// - Auto-hides when count is 0
/// - Displays "99+" for counts > 99
/// - Two sizes: normal and small
/// - Material 3 themed colors
class UnreadBadge extends StatelessWidget {
  /// The number of unread items to display
  final int count;
  
  /// Whether to use small sizing (for list items)
  final bool isSmall;
  
  /// Optional custom background color
  final Color? backgroundColor;
  
  /// Optional custom text color
  final Color? textColor;

  const UnreadBadge({
    super.key,
    required this.count,
    this.isSmall = false,
    this.backgroundColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    // Hide badge if count is 0 or negative
    if (count <= 0) return const SizedBox.shrink();
    
    final colorScheme = Theme.of(context).colorScheme;
    final displayCount = count > 99 ? '99+' : count.toString();
    
    // Size configurations
    final double horizontalPadding = isSmall ? 4 : 6;
    final double verticalPadding = isSmall ? 2 : 4;
    final double minWidth = isSmall ? 16 : 20;
    final double minHeight = isSmall ? 16 : 20;
    final double fontSize = isSmall ? 10 : 12;
    final double borderRadius = isSmall ? 8 : 10;
    
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      decoration: BoxDecoration(
        color: backgroundColor ?? colorScheme.error,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      constraints: BoxConstraints(
        minWidth: minWidth,
        minHeight: minHeight,
      ),
      child: Text(
        displayCount,
        style: TextStyle(
          color: textColor ?? colorScheme.onError,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          height: 1.0, // Tight line height for centered text
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// A badge widget specifically for navigation items
/// 
/// Wraps an icon with an optional badge indicator
/// Used in navigation bars and rails
class NavigationItemBadge extends StatelessWidget {
  /// The icon to display
  final IconData icon;
  
  /// The unread count to show in the badge
  final int count;
  
  /// Whether this item is currently selected
  final bool isSelected;

  const NavigationItemBadge({
    super.key,
    required this.icon,
    required this.count,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    if (count <= 0) {
      return Icon(icon);
    }
    
    final colorScheme = Theme.of(context).colorScheme;
    final displayCount = count > 99 ? '99+' : count.toString();
    
    return Badge(
      label: Text(displayCount),
      backgroundColor: colorScheme.error,
      textColor: colorScheme.onError,
      child: Icon(icon),
    );
  }
}

/// A simple dot badge indicator (no number)
/// 
/// Used when you just need to show "has unread" without the count
class UnreadDotBadge extends StatelessWidget {
  /// Whether to show the dot indicator
  final bool show;
  
  /// Size of the dot
  final double size;
  
  /// Optional custom color
  final Color? color;

  const UnreadDotBadge({
    super.key,
    required this.show,
    this.size = 8,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    if (!show) return const SizedBox.shrink();
    
    final colorScheme = Theme.of(context).colorScheme;
    
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color ?? colorScheme.error,
        shape: BoxShape.circle,
      ),
    );
  }
}

