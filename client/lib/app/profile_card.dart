import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class ProfileCard extends StatelessWidget {
  const ProfileCard({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 8,
      color: colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundImage: AssetImage(
                'assets/profile.jpg',
              ), // Replace with your asset or network image
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your Name',
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Row(
                  children: [
                    Icon(Icons.circle, color: colorScheme.primary, size: 12),
                    const SizedBox(width: 4),
                    Text(
                      'Online',
                      style: TextStyle(
                        color: colorScheme.primary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(width: 16),
            Icon(Icons.mic, color: colorScheme.onSurface),
            const SizedBox(width: 8),
            Icon(Icons.headphones, color: colorScheme.onSurface),
            const SizedBox(width: 8),
            InkWell(
              onTap: () => GoRouter.of(context).go('/app/settings'),
              child: Icon(Icons.settings, color: colorScheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}
