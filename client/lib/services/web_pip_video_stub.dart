import 'package:livekit_client/livekit_client.dart' as lk;

class WebPipTile {
  final lk.VideoTrack track;
  final String label;
  final bool isSpeaking;

  const WebPipTile({
    required this.track,
    required this.label,
    required this.isSpeaking,
  });
}

class WebPipVideoManager {
  WebPipVideoManager._();

  static final WebPipVideoManager instance = WebPipVideoManager._();

  void detach() {}

  void updateLayout({
    required String title,
    required String status,
    required lk.VideoTrack? screenShare,
    required List<WebPipTile> tiles,
  }) {}
}
