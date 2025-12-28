import 'package:flutter/material.dart';

/// Severity level for troubleshoot actions.
enum ActionSeverity { low, medium, high, critical }

/// Action button for troubleshooting operations.
class TroubleshootActionButton extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final ActionSeverity severity;
  final VoidCallback onPressed;

  const TroubleshootActionButton({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.severity,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final severityColor = _getSeverityColor(colorScheme);

    return SizedBox(
      width: 280,
      child: Card(
        elevation: 0,
        color: colorScheme.surfaceContainerHighest,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: severityColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, color: severityColor, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                _buildSeverityChip(context, severityColor),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _getSeverityColor(ColorScheme colorScheme) {
    switch (severity) {
      case ActionSeverity.low:
        return colorScheme.primary;
      case ActionSeverity.medium:
        return const Color(0xFFFF9800); // Orange
      case ActionSeverity.high:
        return Colors.deepOrange;
      case ActionSeverity.critical:
        return colorScheme.error;
    }
  }

  String _getSeverityLabel() {
    switch (severity) {
      case ActionSeverity.low:
        return 'Low Risk';
      case ActionSeverity.medium:
        return 'Medium Risk';
      case ActionSeverity.high:
        return 'High Risk';
      case ActionSeverity.critical:
        return 'Critical';
    }
  }

  Widget _buildSeverityChip(BuildContext context, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _getSeverityLabel(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
