import 'package:flutter/material.dart';

/// Animated wrapper that adds speaking glow effect to video tiles
class SpeakingBorderWrapper extends StatefulWidget {
  final Widget child;
  final bool isSpeaking;
  final Color? glowColor;

  const SpeakingBorderWrapper({
    super.key,
    required this.child,
    required this.isSpeaking,
    this.glowColor,
  }) ;

  @override
  State<SpeakingBorderWrapper> createState() => _SpeakingBorderWrapperState();
}

class _SpeakingBorderWrapperState extends State<SpeakingBorderWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150), // Fast fade-in
    );

    _glowAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );

    if (widget.isSpeaking) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(SpeakingBorderWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isSpeaking != oldWidget.isSpeaking) {
      if (widget.isSpeaking) {
        // Fast fade-in
        _controller.duration = const Duration(milliseconds: 150);
        _controller.forward();
      } else {
        // Slow fade-out
        _controller.duration = const Duration(milliseconds: 1500);
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glowColor =
        widget.glowColor ?? Theme.of(context).colorScheme.primary;

    return AnimatedBuilder(
      animation: _glowAnimation,
      child: widget.child, // Pass child here so it doesn't rebuild
      builder: (context, child) {
        final glowOpacity = _glowAnimation.value * 0.8;

        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            boxShadow: glowOpacity > 0
                ? [
                    BoxShadow(
                      color: glowColor.withValues(alpha: glowOpacity),
                      blurRadius: 12,
                      spreadRadius: 3,
                    ),
                  ]
                : [],
          ),
          child: child, // Use the child parameter from builder
        );
      },
    );
  }
}
