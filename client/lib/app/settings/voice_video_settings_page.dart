import 'package:flutter/material.dart';

import '../../models/video_quality_preset.dart';
import '../../models/audio_settings.dart';
import '../../services/video_conference_service.dart';

/// Voice & Video settings page for configuring quality and audio processing
class VoiceVideoSettingsPage extends StatefulWidget {
  const VoiceVideoSettingsPage({super.key});

  @override
  State<VoiceVideoSettingsPage> createState() => _VoiceVideoSettingsPageState();
}

class _VoiceVideoSettingsPageState extends State<VoiceVideoSettingsPage> {
  late VideoQualitySettings _videoSettings;
  late AudioSettings _audioSettings;

  @override
  void initState() {
    super.initState();
    final service = VideoConferenceService.instance;
    _videoSettings = service.videoQualitySettings;
    _audioSettings = service.audioSettings;
  }

  Future<void> _applySettings() async {
    final service = VideoConferenceService.instance;
    await service.updateVideoQualitySettings(_videoSettings);
    await service.updateAudioSettings(_audioSettings);
  }

  void _resetToDefaults() {
    setState(() {
      _videoSettings = VideoQualitySettings.defaults();
      _audioSettings = AudioSettings.defaults();
    });
    _applySettings();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(title: const Text('Voice & Video')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Video Settings Section
          _buildSectionHeader(
            icon: Icons.videocam,
            title: 'Video Settings',
            theme: theme,
          ),
          const SizedBox(height: 12),
          _buildVideoSettingsCard(theme),
          const SizedBox(height: 20),

          // Audio Settings Section
          _buildSectionHeader(
            icon: Icons.mic,
            title: 'Audio Settings',
            theme: theme,
          ),
          const SizedBox(height: 12),
          _buildAudioSettingsCard(theme),
          const SizedBox(height: 20),

          // Audio Processing Section
          _buildSectionHeader(
            icon: Icons.tune,
            title: 'Audio Processing',
            theme: theme,
          ),
          const SizedBox(height: 12),
          _buildAudioProcessingCard(theme),
          const SizedBox(height: 16),

          // Reset button
          Center(
            child: OutlinedButton.icon(
              onPressed: _resetToDefaults,
              icon: const Icon(Icons.restore),
              label: const Text('Reset to Defaults'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required ThemeData theme,
  }) {
    return Row(
      children: [
        Icon(icon, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildVideoSettingsCard(ThemeData theme) {
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Camera Quality
            _buildDropdown(
              label: 'Camera Quality',
              value: _videoSettings.cameraPresetId,
              items: VideoQualityPreset.cameraPresets
                  .map(
                    (preset) => DropdownMenuItem(
                      value: preset.id,
                      child: Text(
                        preset.name,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                setState(() {
                  _videoSettings = _videoSettings.copyWith(
                    cameraPresetId: value,
                  );
                  _applySettings();
                });
              },
            ),
            const SizedBox(height: 16),

            // Screenshare Quality
            _buildDropdown(
              label: 'Screenshare Quality',
              value: _videoSettings.screensharePresetId,
              items: VideoQualityPreset.screensharePresets
                  .map(
                    (preset) => DropdownMenuItem(
                      value: preset.id,
                      child: Text(
                        preset.name,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                setState(() {
                  _videoSettings = _videoSettings.copyWith(
                    screensharePresetId: value,
                  );
                  _applySettings();
                });
              },
            ),
            const SizedBox(height: 16),

            // Simulcast
            SwitchListTile(
              title: Text(
                'Enable Simulcast',
                style: TextStyle(color: theme.colorScheme.onSurface),
              ),
              subtitle: Text(
                'Send multiple quality layers for better bandwidth efficiency',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              value: _videoSettings.simulcastEnabled,
              onChanged: (value) {
                setState(() {
                  _videoSettings = _videoSettings.copyWith(
                    simulcastEnabled: value,
                  );
                  _applySettings();
                });
              },
            ),

            // Adaptive Quality
            SwitchListTile(
              title: Text(
                'Adaptive Quality',
                style: TextStyle(color: theme.colorScheme.onSurface),
              ),
              subtitle: Text(
                'Automatically adjust quality based on grid size',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              value: _videoSettings.adaptiveQualityEnabled,
              onChanged: (value) {
                setState(() {
                  _videoSettings = _videoSettings.copyWith(
                    adaptiveQualityEnabled: value,
                  );
                  _applySettings();
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioSettingsCard(ThemeData theme) {
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Native WebRTC Processing
            SwitchListTile(
              title: Text(
                'Noise Suppression',
                style: TextStyle(color: theme.colorScheme.onSurface),
              ),
              subtitle: Text(
                'Reduce background noise (WebRTC)',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              value: _audioSettings.noiseSuppression,
              onChanged: (value) {
                setState(() {
                  _audioSettings = _audioSettings.copyWith(
                    noiseSuppression: value,
                  );
                  _applySettings();
                });
              },
            ),
            SwitchListTile(
              title: Text(
                'Echo Cancellation',
                style: TextStyle(color: theme.colorScheme.onSurface),
              ),
              subtitle: Text(
                'Remove echo and feedback',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              value: _audioSettings.echoCancellation,
              onChanged: (value) {
                setState(() {
                  _audioSettings = _audioSettings.copyWith(
                    echoCancellation: value,
                  );
                  _applySettings();
                });
              },
            ),
            SwitchListTile(
              title: Text(
                'Auto Gain Control',
                style: TextStyle(color: theme.colorScheme.onSurface),
              ),
              subtitle: Text(
                'Automatically normalize volume',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              value: _audioSettings.autoGainControl,
              onChanged: (value) {
                setState(() {
                  _audioSettings = _audioSettings.copyWith(
                    autoGainControl: value,
                  );
                  _applySettings();
                });
              },
            ),
            const Divider(),

            // Input Volume
            _buildSlider(
              label: 'Input Volume',
              value: _audioSettings.inputVolume,
              min: -20.0,
              max: 20.0,
              divisions: 40,
              unit: 'dB',
              onChanged: (value) {
                setState(() {
                  _audioSettings = _audioSettings.copyWith(inputVolume: value);
                  _applySettings();
                });
              },
            ),
            const SizedBox(height: 16),

            // Output Volume
            _buildSlider(
              label: 'Output Volume',
              value: _audioSettings.outputVolume,
              min: 0.0,
              max: 2.0,
              divisions: 20,
              unit: '%',
              valueMultiplier: 100,
              onChanged: (value) {
                setState(() {
                  _audioSettings = _audioSettings.copyWith(outputVolume: value);
                  _applySettings();
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioProcessingCard(ThemeData theme) {
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Noise Gate
            SwitchListTile(
              title: Text(
                'Noise Gate',
                style: TextStyle(color: theme.colorScheme.onSurface),
              ),
              subtitle: Text(
                'Cut audio below threshold when not speaking',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              value: _audioSettings.noiseGate.enabled,
              onChanged: (value) {
                setState(() {
                  _audioSettings = _audioSettings.copyWith(
                    noiseGate: _audioSettings.noiseGate.copyWith(
                      enabled: value,
                    ),
                  );
                  _applySettings();
                });
              },
            ),
            if (_audioSettings.noiseGate.enabled) ...[
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
                child: _buildSlider(
                  label: 'Threshold',
                  value: _audioSettings.noiseGate.threshold,
                  min: -60.0,
                  max: -20.0,
                  divisions: 40,
                  unit: 'dB',
                  onChanged: (value) {
                    setState(() {
                      _audioSettings = _audioSettings.copyWith(
                        noiseGate: _audioSettings.noiseGate.copyWith(
                          threshold: value,
                        ),
                      );
                      _applySettings();
                    });
                  },
                ),
              ),
            ],
            const Divider(),

            // Compressor
            SwitchListTile(
              title: Text(
                'Compressor',
                style: TextStyle(color: theme.colorScheme.onSurface),
              ),
              subtitle: Text(
                'Even out audio levels for consistent volume',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              value: _audioSettings.compressor.enabled,
              onChanged: (value) {
                setState(() {
                  _audioSettings = _audioSettings.copyWith(
                    compressor: _audioSettings.compressor.copyWith(
                      enabled: value,
                    ),
                  );
                  _applySettings();
                });
              },
            ),
            if (_audioSettings.compressor.enabled) ...[
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
                child: Column(
                  children: [
                    _buildSlider(
                      label: 'Threshold',
                      value: _audioSettings.compressor.threshold,
                      min: -40.0,
                      max: -10.0,
                      divisions: 30,
                      unit: 'dB',
                      onChanged: (value) {
                        setState(() {
                          _audioSettings = _audioSettings.copyWith(
                            compressor: _audioSettings.compressor.copyWith(
                              threshold: value,
                            ),
                          );
                          _applySettings();
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    _buildSlider(
                      label: 'Ratio',
                      value: _audioSettings.compressor.ratio,
                      min: 1.0,
                      max: 10.0,
                      divisions: 18,
                      unit: ':1',
                      onChanged: (value) {
                        setState(() {
                          _audioSettings = _audioSettings.copyWith(
                            compressor: _audioSettings.compressor.copyWith(
                              ratio: value,
                            ),
                          );
                          _applySettings();
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    _buildSlider(
                      label: 'Makeup Gain',
                      value: _audioSettings.compressor.makeupGain,
                      min: 0.0,
                      max: 20.0,
                      divisions: 20,
                      unit: 'dB',
                      onChanged: (value) {
                        setState(() {
                          _audioSettings = _audioSettings.copyWith(
                            compressor: _audioSettings.compressor.copyWith(
                              makeupGain: value,
                            ),
                          );
                          _applySettings();
                        });
                      },
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDropdown({
    required String label,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: value,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          dropdownColor: Theme.of(context).colorScheme.surface,
          items: items,
          onChanged: onChanged,
          decoration: InputDecoration(
            filled: true,
            fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
          ),
          isExpanded: true,
        ),
      ],
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String unit,
    double valueMultiplier = 1.0,
    required ValueChanged<double> onChanged,
  }) {
    final displayValue = (value * valueMultiplier).toStringAsFixed(
      valueMultiplier == 1.0 ? 1 : 0,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            Text(
              '$displayValue$unit',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
