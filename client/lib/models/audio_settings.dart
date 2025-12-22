/// Audio processing settings
class AudioSettings {
  // Native WebRTC audio processing
  final bool noiseSuppression;
  final bool echoCancellation;
  final bool autoGainControl;

  // Custom audio processing
  final NoiseGateSettings noiseGate;
  final CompressorSettings compressor;

  // Volume controls
  final double inputVolume; // -20dB to +20dB (0 = no change)
  final double outputVolume; // 0.0 to 2.0 (1.0 = 100%)

  const AudioSettings({
    this.noiseSuppression = true,
    this.echoCancellation = true,
    this.autoGainControl = true,
    this.noiseGate = const NoiseGateSettings(),
    this.compressor = const CompressorSettings(),
    this.inputVolume = 0.0,
    this.outputVolume = 1.0,
  });

  // Default settings
  factory AudioSettings.defaults() => const AudioSettings();

  // Convert to/from JSON for persistence
  Map<String, dynamic> toJson() => {
    'noiseSuppression': noiseSuppression,
    'echoCancellation': echoCancellation,
    'autoGainControl': autoGainControl,
    'noiseGate': noiseGate.toJson(),
    'compressor': compressor.toJson(),
    'inputVolume': inputVolume,
    'outputVolume': outputVolume,
  };

  factory AudioSettings.fromJson(Map<String, dynamic> json) => AudioSettings(
    noiseSuppression: json['noiseSuppression'] as bool? ?? true,
    echoCancellation: json['echoCancellation'] as bool? ?? true,
    autoGainControl: json['autoGainControl'] as bool? ?? true,
    noiseGate: json['noiseGate'] != null
        ? NoiseGateSettings.fromJson(json['noiseGate'] as Map<String, dynamic>)
        : const NoiseGateSettings(),
    compressor: json['compressor'] != null
        ? CompressorSettings.fromJson(
            json['compressor'] as Map<String, dynamic>,
          )
        : const CompressorSettings(),
    inputVolume: (json['inputVolume'] as num?)?.toDouble() ?? 0.0,
    outputVolume: (json['outputVolume'] as num?)?.toDouble() ?? 1.0,
  );

  AudioSettings copyWith({
    bool? noiseSuppression,
    bool? echoCancellation,
    bool? autoGainControl,
    NoiseGateSettings? noiseGate,
    CompressorSettings? compressor,
    double? inputVolume,
    double? outputVolume,
  }) => AudioSettings(
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    echoCancellation: echoCancellation ?? this.echoCancellation,
    autoGainControl: autoGainControl ?? this.autoGainControl,
    noiseGate: noiseGate ?? this.noiseGate,
    compressor: compressor ?? this.compressor,
    inputVolume: inputVolume ?? this.inputVolume,
    outputVolume: outputVolume ?? this.outputVolume,
  );
}

/// Noise gate settings (reduces background noise when not speaking)
class NoiseGateSettings {
  final bool enabled;
  final double threshold; // -60dB to -20dB (default: -40dB)
  final double attack; // milliseconds (default: 10ms)
  final double release; // milliseconds (default: 100ms)

  const NoiseGateSettings({
    this.enabled = false,
    this.threshold = -40.0,
    this.attack = 10.0,
    this.release = 100.0,
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'threshold': threshold,
    'attack': attack,
    'release': release,
  };

  factory NoiseGateSettings.fromJson(Map<String, dynamic> json) =>
      NoiseGateSettings(
        enabled: json['enabled'] as bool? ?? false,
        threshold: (json['threshold'] as num?)?.toDouble() ?? -40.0,
        attack: (json['attack'] as num?)?.toDouble() ?? 10.0,
        release: (json['release'] as num?)?.toDouble() ?? 100.0,
      );

  NoiseGateSettings copyWith({
    bool? enabled,
    double? threshold,
    double? attack,
    double? release,
  }) => NoiseGateSettings(
    enabled: enabled ?? this.enabled,
    threshold: threshold ?? this.threshold,
    attack: attack ?? this.attack,
    release: release ?? this.release,
  );
}

/// Compressor settings (evens out audio levels)
class CompressorSettings {
  final bool enabled;
  final double threshold; // -40dB to -10dB (default: -25dB)
  final double ratio; // 1:1 to 10:1 (default: 3:1)
  final double attack; // milliseconds (default: 5ms)
  final double release; // milliseconds (default: 50ms)
  final double makeupGain; // 0dB to 20dB (default: 6dB)

  const CompressorSettings({
    this.enabled = false,
    this.threshold = -25.0,
    this.ratio = 3.0,
    this.attack = 5.0,
    this.release = 50.0,
    this.makeupGain = 6.0,
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'threshold': threshold,
    'ratio': ratio,
    'attack': attack,
    'release': release,
    'makeupGain': makeupGain,
  };

  factory CompressorSettings.fromJson(Map<String, dynamic> json) =>
      CompressorSettings(
        enabled: json['enabled'] as bool? ?? false,
        threshold: (json['threshold'] as num?)?.toDouble() ?? -25.0,
        ratio: (json['ratio'] as num?)?.toDouble() ?? 3.0,
        attack: (json['attack'] as num?)?.toDouble() ?? 5.0,
        release: (json['release'] as num?)?.toDouble() ?? 50.0,
        makeupGain: (json['makeupGain'] as num?)?.toDouble() ?? 6.0,
      );

  CompressorSettings copyWith({
    bool? enabled,
    double? threshold,
    double? ratio,
    double? attack,
    double? release,
    double? makeupGain,
  }) => CompressorSettings(
    enabled: enabled ?? this.enabled,
    threshold: threshold ?? this.threshold,
    ratio: ratio ?? this.ratio,
    attack: attack ?? this.attack,
    release: release ?? this.release,
    makeupGain: makeupGain ?? this.makeupGain,
  );
}

/// Per-participant audio state (stored separately)
class ParticipantAudioState {
  final String participantId;
  final double volume; // 0.0 to 2.0 (1.0 = 100%)
  final bool locallyMuted; // Muted locally (doesn't affect others)

  const ParticipantAudioState({
    required this.participantId,
    this.volume = 1.0,
    this.locallyMuted = false,
  });

  Map<String, dynamic> toJson() => {
    'participantId': participantId,
    'volume': volume,
    'locallyMuted': locallyMuted,
  };

  factory ParticipantAudioState.fromJson(Map<String, dynamic> json) =>
      ParticipantAudioState(
        participantId: json['participantId'] as String,
        volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
        locallyMuted: json['locallyMuted'] as bool? ?? false,
      );

  ParticipantAudioState copyWith({double? volume, bool? locallyMuted}) =>
      ParticipantAudioState(
        participantId: participantId,
        volume: volume ?? this.volume,
        locallyMuted: locallyMuted ?? this.locallyMuted,
      );
}
