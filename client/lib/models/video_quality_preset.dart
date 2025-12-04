import 'package:livekit_client/livekit_client.dart';

/// Video quality preset for camera and screenshare
class VideoQualityPreset {
  final String id;
  final String name;
  final String description;
  final VideoParameters parameters;
  final bool isDefault;

  const VideoQualityPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.parameters,
    this.isDefault = false,
  });

  // Predefined quality presets for camera
  static final camera360p = VideoQualityPreset(
    id: 'camera_360p',
    name: '360p',
    description: 'Low quality - saves bandwidth',
    parameters: VideoParameters(
      dimensions: const VideoDimensions(640, 360),
      encoding: VideoEncoding(
        maxBitrate: 500000, // 500 kbps
        maxFramerate: 30,
      ),
    ),
  );

  static final camera720p = VideoQualityPreset(
    id: 'camera_720p',
    name: '720p HD',
    description: 'Balanced quality and bandwidth',
    parameters: VideoParameters(
      dimensions: const VideoDimensions(1280, 720),
      encoding: VideoEncoding(
        maxBitrate: 1500000, // 1.5 Mbps
        maxFramerate: 30,
      ),
    ),
    isDefault: true,
  );

  static final camera1080p = VideoQualityPreset(
    id: 'camera_1080p',
    name: '1080p Full HD',
    description: 'High quality - requires good connection',
    parameters: VideoParameters(
      dimensions: const VideoDimensions(1920, 1080),
      encoding: VideoEncoding(
        maxBitrate: 3000000, // 3 Mbps
        maxFramerate: 30,
      ),
    ),
  );

  static final camera4k = VideoQualityPreset(
    id: 'camera_4k',
    name: '4K Ultra HD',
    description: 'Maximum quality - requires excellent connection',
    parameters: VideoParameters(
      dimensions: const VideoDimensions(3840, 2160),
      encoding: VideoEncoding(
        maxBitrate: 8000000, // 8 Mbps
        maxFramerate: 30,
      ),
    ),
  );

  // Predefined quality presets for screenshare
  static final screenshare360p = VideoQualityPreset(
    id: 'screenshare_360p',
    name: '360p',
    description: 'Low quality - minimal bandwidth',
    parameters: VideoParameters(
      dimensions: const VideoDimensions(640, 360),
      encoding: VideoEncoding(
        maxBitrate: 500000, // 500 kbps
        maxFramerate: 15,
      ),
    ),
  );

  static final screenshare720p = VideoQualityPreset(
    id: 'screenshare_720p',
    name: '720p HD',
    description: 'Good for presentations',
    parameters: VideoParameters(
      dimensions: const VideoDimensions(1280, 720),
      encoding: VideoEncoding(
        maxBitrate: 2000000, // 2 Mbps
        maxFramerate: 15,
      ),
    ),
  );

  static final screenshare1080p = VideoQualityPreset(
    id: 'screenshare_1080p',
    name: '1080p Full HD',
    description: 'Sharp text and details',
    parameters: VideoParameters(
      dimensions: const VideoDimensions(1920, 1080),
      encoding: VideoEncoding(
        maxBitrate: 4000000, // 4 Mbps
        maxFramerate: 15,
      ),
    ),
    isDefault: true,
  );

  static final screenshare4k = VideoQualityPreset(
    id: 'screenshare_4k',
    name: '4K Ultra HD',
    description: 'Maximum detail - large displays',
    parameters: VideoParameters(
      dimensions: const VideoDimensions(3840, 2160),
      encoding: VideoEncoding(
        maxBitrate: 10000000, // 10 Mbps
        maxFramerate: 15,
      ),
    ),
  );

  // All camera presets
  static List<VideoQualityPreset> get cameraPresets => [
        camera360p,
        camera720p,
        camera1080p,
        camera4k,
      ];

  // All screenshare presets
  static List<VideoQualityPreset> get screensharePresets => [
        screenshare360p,
        screenshare720p,
        screenshare1080p,
        screenshare4k,
      ];

  // Get default camera preset
  static VideoQualityPreset get defaultCameraPreset =>
      cameraPresets.firstWhere((p) => p.isDefault, orElse: () => camera720p);

  // Get default screenshare preset
  static VideoQualityPreset get defaultScreensharePreset =>
      screensharePresets.firstWhere(
        (p) => p.isDefault,
        orElse: () => screenshare1080p,
      );

  // Find preset by ID
  static VideoQualityPreset? findById(String id) {
    try {
      return [...cameraPresets, ...screensharePresets]
          .firstWhere((p) => p.id == id);
    } catch (e) {
      return null;
    }
  }

  // Generate simulcast layers from a quality preset
  List<VideoParameters> generateSimulcastLayers() {
    // Generate 3 layers: high, medium, low
    final baseWidth = parameters.dimensions.width;
    final baseHeight = parameters.dimensions.height;
    final baseBitrate = parameters.encoding?.maxBitrate ?? 1500000;
    final baseFramerate = parameters.encoding?.maxFramerate ?? 30;

    return [
      // High layer (original quality)
      parameters,

      // Medium layer (50% resolution, 40% bitrate)
      VideoParameters(
        dimensions: VideoDimensions(
          (baseWidth * 0.67).round(),
          (baseHeight * 0.67).round(),
        ),
        encoding: VideoEncoding(
          maxBitrate: (baseBitrate * 0.4).round(),
          maxFramerate: baseFramerate,
        ),
      ),

      // Low layer (33% resolution, 20% bitrate)
      VideoParameters(
        dimensions: VideoDimensions(
          (baseWidth * 0.33).round(),
          (baseHeight * 0.33).round(),
        ),
        encoding: VideoEncoding(
          maxBitrate: (baseBitrate * 0.2).round(),
          maxFramerate: baseFramerate,
        ),
      ),
    ];
  }

  @override
  String toString() => 'VideoQualityPreset($name - ${parameters.dimensions.width}x${parameters.dimensions.height})';
}

/// Video quality settings configuration
class VideoQualitySettings {
  final String cameraPresetId;
  final String screensharePresetId;
  final bool simulcastEnabled;
  final bool adaptiveQualityEnabled;

  const VideoQualitySettings({
    required this.cameraPresetId,
    required this.screensharePresetId,
    this.simulcastEnabled = true,
    this.adaptiveQualityEnabled = true,
  });

  // Default settings
  factory VideoQualitySettings.defaults() => VideoQualitySettings(
        cameraPresetId: VideoQualityPreset.defaultCameraPreset.id,
        screensharePresetId: VideoQualityPreset.defaultScreensharePreset.id,
        simulcastEnabled: true,
        adaptiveQualityEnabled: true,
      );

  // Convert to/from JSON for persistence
  Map<String, dynamic> toJson() => {
        'cameraPresetId': cameraPresetId,
        'screensharePresetId': screensharePresetId,
        'simulcastEnabled': simulcastEnabled,
        'adaptiveQualityEnabled': adaptiveQualityEnabled,
      };

  factory VideoQualitySettings.fromJson(Map<String, dynamic> json) =>
      VideoQualitySettings(
        cameraPresetId: json['cameraPresetId'] as String? ??
            VideoQualityPreset.defaultCameraPreset.id,
        screensharePresetId: json['screensharePresetId'] as String? ??
            VideoQualityPreset.defaultScreensharePreset.id,
        simulcastEnabled: json['simulcastEnabled'] as bool? ?? true,
        adaptiveQualityEnabled: json['adaptiveQualityEnabled'] as bool? ?? true,
      );

  VideoQualitySettings copyWith({
    String? cameraPresetId,
    String? screensharePresetId,
    bool? simulcastEnabled,
    bool? adaptiveQualityEnabled,
  }) =>
      VideoQualitySettings(
        cameraPresetId: cameraPresetId ?? this.cameraPresetId,
        screensharePresetId: screensharePresetId ?? this.screensharePresetId,
        simulcastEnabled: simulcastEnabled ?? this.simulcastEnabled,
        adaptiveQualityEnabled:
            adaptiveQualityEnabled ?? this.adaptiveQualityEnabled,
      );

  // Get the actual preset objects
  VideoQualityPreset get cameraPreset =>
      VideoQualityPreset.findById(cameraPresetId) ??
      VideoQualityPreset.defaultCameraPreset;

  VideoQualityPreset get screensharePreset =>
      VideoQualityPreset.findById(screensharePresetId) ??
      VideoQualityPreset.defaultScreensharePreset;
}
