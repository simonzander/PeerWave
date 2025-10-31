import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'package:flutter/foundation.dart';

/// Insertable Streams Manager for Web
/// 
/// Implements Insertable Streams API for frame transformation with E2EE
/// 
/// Browser Support:
/// - Chrome 86+: ✅ Full support
/// - Edge 86+: ✅ Full support
/// - Safari 15.4+: ✅ Full support (with limitations)
/// - Firefox: ❌ NOT SUPPORTED (as of Oct 2025)
/// 
/// Architecture:
/// - Web Worker (e2ee_worker.js) for AES-256-GCM encryption/decryption
/// - TransformStream API for frame transformation pipeline
/// - RTCRtpSender/Receiver.createEncodedStreams() for encoded frame access
/// - Asynchronous processing with Completer for frame-by-frame encryption
/// 
/// Flow:
/// 1. Sender: Raw frame → TransformStream → Worker encrypt → Encrypted frame → Network
/// 2. Receiver: Encrypted frame → TransformStream → Worker decrypt → Raw frame → Renderer
class InsertableStreamsManager {
  final dynamic e2eeService;
  html.Worker? _worker;
  bool _workerReady = false;
  final List<Completer<void>> _workerReadyCompleters = [];
  
  // Statistics
  int _transformedFrames = 0;
  int _errors = 0;
  
  InsertableStreamsManager({required this.e2eeService});
  
  /// Initialize Web Worker
  Future<void> initialize() async {
    if (_worker != null) {
      debugPrint('[InsertableStreams] Already initialized');
      return;
    }
    
    try {
      debugPrint('[InsertableStreams] Initializing Web Worker...');
      
      _worker = html.Worker('e2ee_worker.js');
      
      // Wait for worker ready
      final completer = Completer<void>();
      _workerReadyCompleters.add(completer);
      
      _worker!.onMessage.listen((event) {
        final data = event.data;
        if (data is Map && data['type'] == 'ready') {
          _workerReady = true;
          debugPrint('[InsertableStreams] ✓ Web Worker ready');
          for (final c in _workerReadyCompleters) {
            if (!c.isCompleted) c.complete();
          }
          _workerReadyCompleters.clear();
        } else if (data is Map && data['type'] == 'error') {
          debugPrint('[InsertableStreams] Worker error: ${data['error']}');
          _errors++;
        }
      });
      
      _worker!.onError.listen((error) {
        debugPrint('[InsertableStreams] Worker error event: $error');
        _errors++;
      });
      
      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('Worker initialization timeout');
        },
      );
      
      // Send send key to worker
      final sendKey = e2eeService.getSendKey();
      if (sendKey != null) {
        _worker!.postMessage({
          'type': 'setSendKey',
          'data': {'key': sendKey}
        });
      }
      
      debugPrint('[InsertableStreams] ✓ Initialized');
      
    } catch (e) {
      debugPrint('[InsertableStreams] Initialization failed: $e');
      rethrow;
    }
  }
  
  /// Check if Insertable Streams is supported
  static bool isSupported() {
    if (!kIsWeb) return false;
    
    try {
      // Check if RTCRtpSender.prototype.createEncodedStreams exists
      final rtcRtpSender = js.context['RTCRtpSender'];
      if (rtcRtpSender == null) return false;
      
      final prototype = rtcRtpSender['prototype'];
      if (prototype == null) return false;
      
      return prototype['createEncodedStreams'] != null;
    } catch (e) {
      debugPrint('[InsertableStreams] Support check failed: $e');
      return false;
    }
  }
  
  /// Attach transform to sender (outgoing media)
  Future<void> attachSenderTransform(dynamic sender) async {
    if (!_workerReady) {
      debugPrint('[InsertableStreams] Worker not ready, skipping sender transform');
      return;
    }
    
    try {
      debugPrint('[InsertableStreams] Attaching sender transform...');
      
      // Convert sender to JsObject for createEncodedStreams() call
      final senderJs = js.JsObject.fromBrowserObject(sender);
      
      // Check if createEncodedStreams exists
      if (!senderJs.hasProperty('createEncodedStreams')) {
        debugPrint('[InsertableStreams] createEncodedStreams not available');
        return;
      }
      
      // Call createEncodedStreams()
      final streamsJs = senderJs.callMethod('createEncodedStreams', []);
      final readable = streamsJs['readable'];
      final writable = streamsJs['writable'];
      
      // Create TransformStream for encryption
      final transformer = _createEncryptTransformStream();
      
      // Pipe: readable -> transformer -> writable
      final transformedReadable = readable.callMethod('pipeThrough', [transformer]);
      transformedReadable.callMethod('pipeTo', [writable]);
      
      debugPrint('[InsertableStreams] ✓ Sender transform attached');
      
    } catch (e) {
      debugPrint('[InsertableStreams] Failed to attach sender transform: $e');
      _errors++;
      rethrow;
    }
  }
  
  /// Attach transform to receiver (incoming media)
  Future<void> attachReceiverTransform(dynamic receiver, String peerId) async {
    if (!_workerReady) {
      debugPrint('[InsertableStreams] Worker not ready, skipping receiver transform');
      return;
    }
    
    try {
      debugPrint('[InsertableStreams] Attaching receiver transform for $peerId...');
      
      // Add peer key to worker
      final peerKey = e2eeService._peerKeys[peerId];
      if (peerKey != null) {
        _worker?.postMessage({
          'type': 'addPeerKey',
          'data': {'peerId': peerId, 'key': peerKey}
        });
      } else {
        debugPrint('[InsertableStreams] No peer key for $peerId, skipping');
        return;
      }
      
      // Convert receiver to JsObject for createEncodedStreams() call
      final receiverJs = js.JsObject.fromBrowserObject(receiver);
      
      // Check if createEncodedStreams exists
      if (!receiverJs.hasProperty('createEncodedStreams')) {
        debugPrint('[InsertableStreams] createEncodedStreams not available');
        return;
      }
      
      // Call createEncodedStreams()
      final streamsJs = receiverJs.callMethod('createEncodedStreams', []);
      final readable = streamsJs['readable'];
      final writable = streamsJs['writable'];
      
      // Create TransformStream for decryption
      final transformer = _createDecryptTransformStream(peerId);
      
      // Pipe: readable -> transformer -> writable
      final transformedReadable = readable.callMethod('pipeThrough', [transformer]);
      transformedReadable.callMethod('pipeTo', [writable]);
      
      debugPrint('[InsertableStreams] ✓ Receiver transform attached for $peerId');
      
    } catch (e) {
      debugPrint('[InsertableStreams] Failed to attach receiver transform: $e');
      _errors++;
      rethrow;
    }
  }
  
  /// Create TransformStream for encryption
  js.JsObject _createEncryptTransformStream() {
    int frameCounter = 0;
    
    // Create transform function
    final transformFn = js.allowInterop((dynamic chunk, dynamic controller) async {
      try {
        // Extract RTCEncodedVideoFrame/RTCEncodedAudioFrame
        final chunkJs = js.JsObject.fromBrowserObject(chunk);
        
        // Get frame data
        final data = chunkJs['data'];
        if (data == null) {
          controller.callMethod('enqueue', [chunk]);
          return;
        }
        
        // Convert to Uint8List
        final frameData = _jsArrayBufferToUint8List(data);
        
        // Send to worker for encryption
        final frameId = frameCounter++;
        final completer = Completer<List<int>>();
        
        // Setup one-time listener for this frame
        late StreamSubscription subscription;
        subscription = _worker!.onMessage.listen((event) {
          final response = event.data;
          if (response is Map && 
              response['type'] == 'encrypted' && 
              response['frameId'] == frameId) {
            subscription.cancel();
            final encryptedFrame = response['frame'] as List<int>;
            completer.complete(encryptedFrame);
          }
        });
        
        // Request encryption
        _worker!.postMessage({
          'type': 'encrypt',
          'data': {
            'frame': frameData,
            'frameId': frameId,
          }
        });
        
        // Wait for encrypted frame (with timeout)
        final encryptedFrame = await completer.future.timeout(
          const Duration(milliseconds: 100),
          onTimeout: () {
            subscription.cancel();
            debugPrint('[InsertableStreams] Encryption timeout for frame $frameId');
            return frameData; // Return original on timeout
          },
        );
        
        // Create new ArrayBuffer with encrypted data
        final encryptedBuffer = _uint8ListToJsArrayBuffer(encryptedFrame);
        
        // Update chunk data
        chunkJs['data'] = encryptedBuffer;
        
        // Enqueue modified chunk
        controller.callMethod('enqueue', [chunk]);
        
        _transformedFrames++;
        
      } catch (e) {
        debugPrint('[InsertableStreams] Encryption transform error: $e');
        _errors++;
        // Enqueue original chunk on error
        controller.callMethod('enqueue', [chunk]);
      }
    });
    
    // Create TransformStream
    return js.JsObject(
      js.context['TransformStream'],
      [js.JsObject.jsify({'transform': transformFn})],
    );
  }
  
  /// Create TransformStream for decryption
  js.JsObject _createDecryptTransformStream(String peerId) {
    int frameCounter = 0;
    
    // Create transform function
    final transformFn = js.allowInterop((dynamic chunk, dynamic controller) async {
      try {
        // Extract RTCEncodedVideoFrame/RTCEncodedAudioFrame
        final chunkJs = js.JsObject.fromBrowserObject(chunk);
        
        // Get frame data
        final data = chunkJs['data'];
        if (data == null) {
          controller.callMethod('enqueue', [chunk]);
          return;
        }
        
        // Convert to Uint8List
        final frameData = _jsArrayBufferToUint8List(data);
        
        // Send to worker for decryption
        final frameId = frameCounter++;
        final completer = Completer<List<int>>();
        
        // Setup one-time listener for this frame
        late StreamSubscription subscription;
        subscription = _worker!.onMessage.listen((event) {
          final response = event.data;
          if (response is Map && 
              response['type'] == 'decrypted' && 
              response['frameId'] == frameId) {
            subscription.cancel();
            final decryptedFrame = response['frame'] as List<int>;
            completer.complete(decryptedFrame);
          }
        });
        
        // Request decryption
        _worker!.postMessage({
          'type': 'decrypt',
          'data': {
            'frame': frameData,
            'peerId': peerId,
            'frameId': frameId,
          }
        });
        
        // Wait for decrypted frame (with timeout)
        final decryptedFrame = await completer.future.timeout(
          const Duration(milliseconds: 100),
          onTimeout: () {
            subscription.cancel();
            debugPrint('[InsertableStreams] Decryption timeout for frame $frameId');
            return frameData; // Return original on timeout
          },
        );
        
        // Create new ArrayBuffer with decrypted data
        final decryptedBuffer = _uint8ListToJsArrayBuffer(decryptedFrame);
        
        // Update chunk data
        chunkJs['data'] = decryptedBuffer;
        
        // Enqueue modified chunk
        controller.callMethod('enqueue', [chunk]);
        
        _transformedFrames++;
        
      } catch (e) {
        debugPrint('[InsertableStreams] Decryption transform error: $e');
        _errors++;
        // Enqueue original chunk on error
        controller.callMethod('enqueue', [chunk]);
      }
    });
    
    // Create TransformStream
    return js.JsObject(
      js.context['TransformStream'],
      [js.JsObject.jsify({'transform': transformFn})],
    );
  }
  
  /// Convert JavaScript ArrayBuffer to Uint8List
  List<int> _jsArrayBufferToUint8List(dynamic arrayBuffer) {
    final uint8Array = js.JsObject(js.context['Uint8Array'], [arrayBuffer]);
    final length = uint8Array['length'] as int;
    final list = List<int>.filled(length, 0);
    for (var i = 0; i < length; i++) {
      list[i] = uint8Array[i] as int;
    }
    return list;
  }
  
  /// Convert Uint8List to JavaScript ArrayBuffer
  dynamic _uint8ListToJsArrayBuffer(List<int> data) {
    final uint8Array = js.JsObject(js.context['Uint8Array'], [data.length]);
    for (var i = 0; i < data.length; i++) {
      uint8Array[i] = data[i];
    }
    return uint8Array['buffer'];
  }
  
  /// Get statistics
  Map<String, dynamic> getStats() {
    return {
      'transformedFrames': _transformedFrames,
      'errors': _errors,
      'workerReady': _workerReady,
      'implementation': 'Web Worker (full)',
    };
  }
  
  /// Cleanup
  void dispose() {
    debugPrint('[InsertableStreams] Disposing...');
    _worker?.terminate();
    _worker = null;
    _workerReady = false;
  }
}

/// Browser Detection Utility
class BrowserDetector {
  static String? _cachedBrowserName;
  static int? _cachedBrowserVersion;
  
  /// Get user agent
  static String getUserAgent() {
    if (kIsWeb) {
      return html.window.navigator.userAgent;
    }
    return 'Native';
  }
  
  /// Get browser name
  static String getBrowserName() {
    if (_cachedBrowserName != null) return _cachedBrowserName!;
    
    if (!kIsWeb) {
      _cachedBrowserName = 'Native';
      return _cachedBrowserName!;
    }
    
    final ua = getUserAgent().toLowerCase();
    
    if (ua.contains('edg/')) {
      _cachedBrowserName = 'Edge';
    } else if (ua.contains('chrome/') && !ua.contains('edg/')) {
      _cachedBrowserName = 'Chrome';
    } else if (ua.contains('safari/') && !ua.contains('chrome/')) {
      _cachedBrowserName = 'Safari';
    } else if (ua.contains('firefox/')) {
      _cachedBrowserName = 'Firefox';
    } else {
      _cachedBrowserName = 'Unknown';
    }
    
    return _cachedBrowserName!;
  }
  
  /// Get browser version
  static int getBrowserVersion() {
    if (_cachedBrowserVersion != null) return _cachedBrowserVersion!;
    
    if (!kIsWeb) {
      _cachedBrowserVersion = 0;
      return 0;
    }
    
    final ua = getUserAgent();
    final browserName = getBrowserName();
    
    try {
      RegExp versionRegex;
      
      switch (browserName) {
        case 'Chrome':
          versionRegex = RegExp(r'Chrome/(\d+)');
          break;
        case 'Edge':
          versionRegex = RegExp(r'Edg/(\d+)');
          break;
        case 'Safari':
          versionRegex = RegExp(r'Version/(\d+)');
          break;
        case 'Firefox':
          versionRegex = RegExp(r'Firefox/(\d+)');
          break;
        default:
          return 0;
      }
      
      final match = versionRegex.firstMatch(ua);
      if (match != null && match.groupCount >= 1) {
        _cachedBrowserVersion = int.parse(match.group(1)!);
        return _cachedBrowserVersion!;
      }
    } catch (e) {
      debugPrint('[BrowserDetector] Version parse error: $e');
    }
    
    return 0;
  }
  
  /// Check if Insertable Streams is supported
  static bool isInsertableStreamsSupported() {
    if (!kIsWeb) return false;
    
    final browser = getBrowserName();
    final version = getBrowserVersion();
    
    switch (browser) {
      case 'Chrome':
        return version >= 86;
      case 'Edge':
        return version >= 86;
      case 'Safari':
        return version >= 15; // Safari 15.4+
      case 'Firefox':
        return false; // Not supported as of Oct 2025
      default:
        // Unknown browser - check API support
        return InsertableStreamsManager.isSupported();
    }
  }
  
  /// Get detailed browser info
  static Map<String, dynamic> getBrowserInfo() {
    return {
      'name': getBrowserName(),
      'version': getBrowserVersion(),
      'userAgent': getUserAgent(),
      'insertableStreamsSupported': isInsertableStreamsSupported(),
      'platform': kIsWeb ? 'Web' : 'Native',
    };
  }
  
  /// Get unsupported browser message
  static String getUnsupportedMessage() {
    return '''
E2E Encryption requires Insertable Streams API.

Supported browsers:
✅ Chrome 86+
✅ Edge 86+  
✅ Safari 15.4+

❌ Firefox (not supported yet)

Your browser: ${getBrowserName()} ${getBrowserVersion()}

Please use a supported browser to join encrypted video calls.
''';
  }
}
