import 'package:flutter/material.dart';
import 'dart:math' as math;

/// Visual audio level indicator widget
class AudioLevelIndicator extends StatefulWidget {
  final Stream<double>? audioLevelStream; // RMS values 0.0 - 1.0
  final double size;
  final Color? activeColor;
  final Color? inactiveColor;

  const AudioLevelIndicator({
    super.key,
    this.audioLevelStream,
    this.size = 32,
    this.activeColor,
    this.inactiveColor,
  });

  @override
  State<AudioLevelIndicator> createState() => _AudioLevelIndicatorState();
}

class _AudioLevelIndicatorState extends State<AudioLevelIndicator>
    with SingleTickerProviderStateMixin {
  double _currentLevel = 0.0;
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );

    widget.audioLevelStream?.listen((level) {
      setState(() {
        _currentLevel = level.clamp(0.0, 1.0);
      });
      
      if (_currentLevel > 0.01) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = widget.activeColor ?? theme.colorScheme.primary;
    final inactiveColor = widget.inactiveColor ?? theme.colorScheme.surfaceVariant;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _AudioLevelPainter(
            level: _currentLevel,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            animation: _controller.value,
          ),
        );
      },
    );
  }
}

class _AudioLevelPainter extends CustomPainter {
  final double level;
  final Color activeColor;
  final Color inactiveColor;
  final double animation;

  _AudioLevelPainter({
    required this.level,
    required this.activeColor,
    required this.inactiveColor,
    required this.animation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    const barCount = 12;
    const barWidth = 3.0;
    const barSpacing = 2.0;

    // Calculate active bars based on level
    final activeBars = (barCount * level).round();

    for (int i = 0; i < barCount; i++) {
      final angle = (i / barCount) * 2 * math.pi - math.pi / 2;
      final isActive = i < activeBars;
      final color = isActive ? activeColor : inactiveColor;

      // Calculate bar height based on level and animation
      final barHeight = isActive
          ? (radius * 0.3) + (radius * 0.2 * animation)
          : radius * 0.2;

      final startPoint = Offset(
        center.dx + (radius - barHeight) * math.cos(angle),
        center.dy + (radius - barHeight) * math.sin(angle),
      );

      final endPoint = Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      );

      final paint = Paint()
        ..color = color.withOpacity(isActive ? 1.0 : 0.3)
        ..strokeWidth = barWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(startPoint, endPoint, paint);
    }
  }

  @override
  bool shouldRepaint(_AudioLevelPainter oldDelegate) {
    return oldDelegate.level != level || oldDelegate.animation != animation;
  }
}

/// Simpler bar-style audio level indicator
class AudioLevelBars extends StatelessWidget {
  final double level; // 0.0 to 1.0
  final int barCount;
  final Color? activeColor;
  final Color? inactiveColor;
  final double height;

  const AudioLevelBars({
    super.key,
    required this.level,
    this.barCount = 8,
    this.activeColor,
    this.inactiveColor,
    this.height = 20,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = this.activeColor ?? theme.colorScheme.primary;
    final inactiveColor = this.inactiveColor ?? theme.colorScheme.surfaceVariant;

    final activeBars = (barCount * level).round();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(barCount, (index) {
        final isActive = index < activeBars;
        final barHeight = height * ((index + 1) / barCount);

        return Container(
          width: 3,
          height: barHeight,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: isActive ? activeColor : inactiveColor.withOpacity(0.3),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}
