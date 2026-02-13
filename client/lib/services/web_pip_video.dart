import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:livekit_client/livekit_client.dart' as lk;

import 'web_pip_bridge.dart';

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

  void detach() {
    WebPipBridge.instance.updateLayout(null);
  }

  void updateLayout({
    required String title,
    required String status,
    required lk.VideoTrack? screenShare,
    required List<WebPipTile> tiles,
  }) {
    final payload = JSObject();
    payload.setProperty('title'.toJS, title.toJS);
    payload.setProperty('status'.toJS, status.toJS);
    payload.setProperty('screenTrack'.toJS, _toTrack(screenShare));

    final tilesArray = globalContext.callMethod('Array'.toJS) as JSObject;
    for (var i = 0; i < tiles.length; i++) {
      final tile = tiles[i];
      final tileObj = JSObject();
      tileObj.setProperty('track'.toJS, _toTrack(tile.track));
      tileObj.setProperty('label'.toJS, tile.label.toJS);
      tileObj.setProperty('isSpeaking'.toJS, tile.isSpeaking.toJS);
      tilesArray.setProperty(i.toJS, tileObj);
    }
    tilesArray.setProperty('length'.toJS, tiles.length.toJS);
    payload.setProperty('tiles'.toJS, tilesArray);

    WebPipBridge.instance.updateLayout(payload);
  }

  JSAny? _toTrack(lk.VideoTrack? track) {
    if (track == null) {
      return null;
    }
    final mediaTrack = track.mediaStreamTrack;
    if (mediaTrack == null) {
      return null;
    }
    return mediaTrack as JSAny;
  }
}
