import 'package:flutter/material.dart';
import '../theme/app_theme_constants.dart';

/// Wiederverwendbare animierte Widgets für konsistente UX
/// 
/// Basierend auf PeerWave Design System:
/// - Fast: 150ms (Hover, Badge)
/// - Normal: 250ms (Navigation, Selection)
/// - Slow: 350ms (Drawer, Modal)

/// Animierter ListTile mit Selection-Highlight
class AnimatedSelectionTile extends StatefulWidget {
  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final Color? highlightColor;

  const AnimatedSelectionTile({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.highlightColor,
  });

  @override
  State<AnimatedSelectionTile> createState() => _AnimatedSelectionTileState();
}

class _AnimatedSelectionTileState extends State<AnimatedSelectionTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final highlightColor = widget.highlightColor ?? colorScheme.primary;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: AppThemeConstants.animationFast,
        curve: AppThemeConstants.animationCurve,
        decoration: BoxDecoration(
          color: widget.selected 
              ? AppThemeConstants.activeChannelBackground
              : (_isHovered 
                  ? highlightColor.withOpacity(0.05) 
                  : Colors.transparent),
          borderRadius: AppThemeConstants.borderRadiusStandard,
          border: widget.selected
              ? Border(
                  left: BorderSide(
                    color: highlightColor,
                    width: AppThemeConstants.borderWidthThick,
                  ),
                )
              : null,
        ),
        child: ListTile(
          dense: true,
          contentPadding: AppThemeConstants.paddingHorizontalSm,
          leading: widget.leading,
          title: widget.title,
          subtitle: widget.subtitle,
          trailing: widget.trailing,
          onTap: widget.onTap,
          selectedColor: highlightColor,
          iconColor: AppThemeConstants.textPrimary,
          textColor: AppThemeConstants.textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: AppThemeConstants.borderRadiusStandard,
          ),
        ),
      ),
    );
  }
}

/// Animiertes Badge mit Appear/Disappear Effect
class AnimatedBadge extends StatelessWidget {
  final int count;
  final bool isSmall;
  final Color? backgroundColor;
  final Color? textColor;

  const AnimatedBadge({
    super.key,
    required this.count,
    this.isSmall = false,
    this.backgroundColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final show = count > 0;

    // Return empty SizedBox if count is 0 to avoid layout issues
    if (!show) {
      return const SizedBox.shrink();
    }

    return AnimatedScale(
      scale: show ? 1.0 : 0.0,
      duration: AppThemeConstants.animationFast,
      curve: Curves.easeOutBack,
      child: AnimatedOpacity(
        opacity: show ? 1.0 : 0.0,
        duration: AppThemeConstants.animationFast,
        curve: AppThemeConstants.fadeCurve,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: isSmall ? 4 : AppThemeConstants.spacingXs,
            vertical: isSmall ? 2 : 4,
          ),
          decoration: BoxDecoration(
            color: backgroundColor ?? colorScheme.error,
            borderRadius: BorderRadius.circular(AppThemeConstants.radiusSmall), // 8px
          ),
          constraints: BoxConstraints(
            minWidth: isSmall ? 16 : 20,
            minHeight: isSmall ? 16 : 20,
          ),
          child: Center(
            child: Text(
              count > 99 ? '99+' : count.toString(),
              style: TextStyle(
                color: textColor ?? colorScheme.onError,
                fontSize: isSmall ? 10 : AppThemeConstants.fontSizeCaption,
                fontWeight: FontWeight.bold,
                height: 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Context Panel Header mit UPPERCASE Styling
class ContextPanelHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final EdgeInsets? padding;

  const ContextPanelHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? AppThemeConstants.paddingHorizontalSm.copyWith(
        top: AppThemeConstants.spacingMd,
        bottom: AppThemeConstants.spacingXs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: AppThemeConstants.contextHeaderStyle,
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Animated Page Route mit Custom Transition
class SlidePageRoute<T> extends PageRoute<T> {
  final WidgetBuilder builder;
  final Offset? startOffset;

  SlidePageRoute({
    required this.builder,
    this.startOffset,
    RouteSettings? settings,
  }) : super(settings: settings);

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final begin = startOffset ?? const Offset(1.0, 0.0); // Von rechts
    const end = Offset.zero;

    final slideAnimation = Tween<Offset>(
      begin: begin,
      end: end,
    ).animate(CurvedAnimation(
      parent: animation,
      curve: AppThemeConstants.slideCurve,
    ));

    final fadeAnimation = CurvedAnimation(
      parent: animation,
      curve: AppThemeConstants.fadeCurve,
    );

    return SlideTransition(
      position: slideAnimation,
      child: FadeTransition(
        opacity: fadeAnimation,
        child: child,
      ),
    );
  }

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => AppThemeConstants.animationNormal;
}

/// Hover-fähiger Container mit Animation
class HoverAnimatedContainer extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color? hoverColor;
  final EdgeInsets? padding;
  final BorderRadius? borderRadius;

  const HoverAnimatedContainer({
    super.key,
    required this.child,
    this.onTap,
    this.hoverColor,
    this.padding,
    this.borderRadius,
  });

  @override
  State<HoverAnimatedContainer> createState() => _HoverAnimatedContainerState();
}

class _HoverAnimatedContainerState extends State<HoverAnimatedContainer> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hoverColor = widget.hoverColor ?? colorScheme.primary.withOpacity(0.05);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: AppThemeConstants.animationFast,
        curve: AppThemeConstants.animationCurve,
        decoration: BoxDecoration(
          color: _isHovered ? hoverColor : Colors.transparent,
          borderRadius: widget.borderRadius ?? AppThemeConstants.borderRadiusStandard,
        ),
        padding: widget.padding,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: widget.borderRadius ?? AppThemeConstants.borderRadiusStandard,
          hoverColor: Colors.transparent, // Wir behandeln Hover selbst
          splashColor: colorScheme.primary.withOpacity(0.1),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Animierte Expansion für Sections (z.B. Channels, Messages)
class AnimatedSection extends StatelessWidget {
  final bool expanded;
  final Widget child;
  final Duration? duration;

  const AnimatedSection({
    super.key,
    required this.expanded,
    required this.child,
    this.duration,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedCrossFade(
      firstChild: child,
      secondChild: const SizedBox.shrink(),
      crossFadeState: expanded 
          ? CrossFadeState.showFirst 
          : CrossFadeState.showSecond,
      duration: duration ?? AppThemeConstants.animationNormal,
      sizeCurve: AppThemeConstants.animationCurve,
      firstCurve: AppThemeConstants.fadeCurve,
      secondCurve: AppThemeConstants.fadeCurve,
    );
  }
}
