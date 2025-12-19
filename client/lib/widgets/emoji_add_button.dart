import 'package:flutter/material.dart';

/// Button to add emoji reactions (the + button shown under messages)
class EmojiAddButton extends StatelessWidget {
  final VoidCallback onTap;
  final double size;

  const EmojiAddButton({
    super.key,
    required this.onTap,
    this.size = 28,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size / 2),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(size / 2),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Center(
          child: Icon(
            Icons.add_reaction_outlined,
            size: size * 0.6,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
