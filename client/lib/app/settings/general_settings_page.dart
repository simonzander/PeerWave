import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/message_cleanup_service.dart';

class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({super.key});

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  static const String autoDeleteDaysKey = 'auto_delete_days';
  static const int defaultAutoDeleteDays = 365;

  int _autoDeleteDays = defaultAutoDeleteDays;
  bool _loading = true;
  bool _isCleaningUp = false;
  final TextEditingController _daysController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _daysController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoDeleteDays =
          prefs.getInt(autoDeleteDaysKey) ?? defaultAutoDeleteDays;
      _daysController.text = _autoDeleteDays.toString();
      _loading = false;
    });
  }

  Future<void> _saveAutoDeleteDays(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(autoDeleteDaysKey, days);
    setState(() {
      _autoDeleteDays = days;
      _daysController.text = days.toString();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Auto-delete set to ${days > 0 ? "$days days" : "disabled"}',
          ),
        ),
      );
    }
  }

  Future<void> _runCleanupNow() async {
    if (_autoDeleteDays <= 0) return;

    setState(() {
      _isCleaningUp = true;
    });

    try {
      await MessageCleanupService.instance.cleanupOldMessages(_autoDeleteDays);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ Cleanup completed successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error during cleanup: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCleaningUp = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(title: const Text('General Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Auto-Delete Section
          Card(
            color: colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.auto_delete,
                        color: colorScheme.primary,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Message Auto-Delete',
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Automatically delete messages older than specified days. Set to 0 to disable.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Input Field
                  TextField(
                    controller: _daysController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Delete after (days)',
                      hintText: 'e.g. 365',
                      helperText: '0 = disabled, default: 365 days (1 year)',
                      suffixText: 'days',
                      prefixIcon: const Icon(Icons.calendar_today),
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onChanged: (value) {
                      // Validate input on change
                      final days = int.tryParse(value);
                      if (days != null && days >= 0 && days <= 3650) {
                        _saveAutoDeleteDays(days);
                      }
                    },
                    onSubmitted: (value) {
                      final days = int.tryParse(value) ?? defaultAutoDeleteDays;
                      _saveAutoDeleteDays(days.clamp(0, 3650)); // Max 10 years
                    },
                  ),

                  const SizedBox(height: 16),

                  // Quick Presets
                  Text(
                    'Quick presets:',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        label: Text(
                          'Disabled',
                          style: TextStyle(
                            color: _autoDeleteDays == 0
                                ? colorScheme.onPrimaryContainer
                                : colorScheme.onSurface,
                          ),
                        ),
                        avatar: Icon(
                          Icons.block,
                          size: 18,
                          color: _autoDeleteDays == 0
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurface,
                        ),
                        onPressed: () => _saveAutoDeleteDays(0),
                        backgroundColor: _autoDeleteDays == 0
                            ? colorScheme.primaryContainer
                            : colorScheme.surfaceContainerHighest,
                      ),
                      ActionChip(
                        label: Text(
                          '30 days',
                          style: TextStyle(
                            color: _autoDeleteDays == 30
                                ? colorScheme.onPrimaryContainer
                                : colorScheme.onSurface,
                          ),
                        ),
                        avatar: Icon(
                          Icons.calendar_view_month,
                          size: 18,
                          color: _autoDeleteDays == 30
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurface,
                        ),
                        onPressed: () => _saveAutoDeleteDays(30),
                        backgroundColor: _autoDeleteDays == 30
                            ? colorScheme.primaryContainer
                            : colorScheme.surfaceContainerHighest,
                      ),
                      ActionChip(
                        label: Text(
                          '90 days',
                          style: TextStyle(
                            color: _autoDeleteDays == 90
                                ? colorScheme.onPrimaryContainer
                                : colorScheme.onSurface,
                          ),
                        ),
                        avatar: Icon(
                          Icons.calendar_today,
                          size: 18,
                          color: _autoDeleteDays == 90
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurface,
                        ),
                        onPressed: () => _saveAutoDeleteDays(90),
                        backgroundColor: _autoDeleteDays == 90
                            ? colorScheme.primaryContainer
                            : colorScheme.surfaceContainerHighest,
                      ),
                      ActionChip(
                        label: Text(
                          '1 year',
                          style: TextStyle(
                            color: _autoDeleteDays == 365
                                ? colorScheme.onPrimaryContainer
                                : colorScheme.onSurface,
                          ),
                        ),
                        avatar: Icon(
                          Icons.event,
                          size: 18,
                          color: _autoDeleteDays == 365
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurface,
                        ),
                        onPressed: () => _saveAutoDeleteDays(365),
                        backgroundColor: _autoDeleteDays == 365
                            ? colorScheme.primaryContainer
                            : colorScheme.surfaceContainerHighest,
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Current Status
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _autoDeleteDays == 0
                          ? colorScheme.errorContainer
                          : colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _autoDeleteDays == 0
                              ? Icons.warning
                              : Icons.check_circle,
                          color: _autoDeleteDays == 0
                              ? colorScheme.onErrorContainer
                              : colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _autoDeleteDays == 0
                                ? 'Auto-delete is disabled. Messages are stored indefinitely.'
                                : 'Messages older than $_autoDeleteDays days will be automatically deleted.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: _autoDeleteDays == 0
                                  ? colorScheme.onErrorContainer
                                  : colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Manual Cleanup Button
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (_autoDeleteDays > 0 && !_isCleaningUp)
                          ? _runCleanupNow
                          : null,
                      icon: _isCleaningUp
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cleaning_services),
                      label: Text(
                        _isCleaningUp ? 'Cleaning up...' : 'Run Cleanup Now',
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Warning text
                  if (_autoDeleteDays > 0 && _autoDeleteDays < 7)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber,
                            size: 16,
                            color: colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Warning: Setting auto-delete to less than 7 days will delete messages very frequently.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Info Card
          Card(
            color: colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, color: colorScheme.primary),
                      const SizedBox(width: 12),
                      Text('How it works', style: theme.textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildInfoItem(
                    '• Cleanup runs automatically when you start the app',
                    theme,
                  ),
                  _buildInfoItem(
                    '• Only messages older than the specified days are deleted',
                    theme,
                  ),
                  _buildInfoItem(
                    '• This affects both 1:1 chats and group messages',
                    theme,
                  ),
                  _buildInfoItem(
                    '• System messages (receipts, key exchanges) are already cleaned up automatically',
                    theme,
                  ),
                  _buildInfoItem(
                    '• Setting to 0 disables automatic deletion completely',
                    theme,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoItem(String text, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
