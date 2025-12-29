import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../services/system_tray_service_web.dart'
    if (dart.library.io) '../../services/system_tray_service.dart';

class SystemTraySettingsPage extends StatefulWidget {
  const SystemTraySettingsPage({super.key});

  @override
  State<SystemTraySettingsPage> createState() => _SystemTraySettingsPageState();
}

class _SystemTraySettingsPageState extends State<SystemTraySettingsPage> {
  final _systemTray = SystemTrayService();
  bool _autoStartEnabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    if (kIsWeb) {
      setState(() => _loading = false);
      return;
    }

    try {
      final enabled = await _systemTray.isAutostartEnabled();
      setState(() {
        _autoStartEnabled = enabled;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[SystemTraySettings] Failed to load settings: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _toggleAutostart(bool value) async {
    setState(() => _loading = true);
    try {
      await _systemTray.setAutostart(value);
      await _loadSettings();
    } catch (e) {
      debugPrint('[SystemTraySettings] Failed to toggle autostart: $e');
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: AppBar(title: const Text('System Tray Settings')),
        body: const Center(
          child: Text('System tray is only available on desktop platforms'),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(title: const Text('System Tray Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Column(
                    children: [
                      ListTile(
                        leading: Icon(
                          Icons.launch,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        title: Text(
                          'Start at Login',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          'Automatically start PeerWave when you log in to your computer',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                        trailing: Switch(
                          value: _autoStartEnabled,
                          onChanged: _toggleAutostart,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'System Tray Behavior',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'When you close the PeerWave window, the application will minimize to the system tray instead of quitting.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '• Click the tray icon to show the window\n'
                          '• Right-click the tray icon for options\n'
                          '• Select "Quit PeerWave" to completely exit',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
