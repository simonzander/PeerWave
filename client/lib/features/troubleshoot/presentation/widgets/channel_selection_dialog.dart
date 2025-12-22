import 'package:flutter/material.dart';

/// Dialog for selecting a channel for troubleshooting operations.
class ChannelSelectionDialog extends StatelessWidget {
  final List<Map<String, String>> channels;

  const ChannelSelectionDialog({super.key, required this.channels});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AlertDialog(
      title: const Text('Select Channel'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: channels.length,
          itemBuilder: (context, index) {
            final channel = channels[index];
            return ListTile(
              leading: Icon(Icons.tag, color: colorScheme.primary),
              title: Text(channel['name'] ?? 'Unknown'),
              subtitle: Text(
                channel['id'] ?? '',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              onTap: () => Navigator.pop(context, channel),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
