import 'dart:async';
import 'package:flutter/foundation.dart';

/// Application-wide events
enum AppEvent {
  /// New message received (direct or channel)
  newMessage,
  
  /// New activity notification (emote, mention, missingcall, etc.)
  newNotification,
  
  /// Emoji reaction added or removed
  reactionUpdated,
  
  /// New channel created
  newChannel,
  
  /// Channel updated (name, members, etc.)
  channelUpdated,
  
  /// Channel deleted
  channelDeleted,
  
  /// Channel joined
  channelJoined,
  
  /// Channel left
  channelLeft,
  
  /// User kicked from channel
  userKicked,
  
  /// User status changed (online, offline, typing, etc.)
  userStatusChanged,
  
  /// New conversation started
  newConversation,
  
  /// Unread count changed
  unreadCountChanged,
  
  /// File upload progress
  fileUploadProgress,
  
  /// File upload complete
  fileUploadComplete,
  
  /// Video conference state changed
  videoConferenceStateChanged,
  
  /// Sync started (pending messages)
  syncStarted,
  
  /// Sync progress (pending messages)
  syncProgress,
  
  /// Sync complete (pending messages)
  syncComplete,
  
  /// Sync error (pending messages)
  syncError,
}

/// Event Bus for decentralized communication between services and views
/// 
/// Single Source of Truth for application-wide events.
/// Services emit events, Views subscribe to relevant events.
/// 
/// Example Usage:
/// ```dart
/// // In a Service (emit event)
/// EventBus.instance.emit(AppEvent.newMessage, messageData);
/// 
/// // In a View (subscribe)
/// _subscription = EventBus.instance.on<Map<String, dynamic>>(AppEvent.newMessage)
///   .listen((data) {
///     // Handle new message
///   });
/// 
/// // In dispose
/// _subscription?.cancel();
/// ```
class EventBus {
  static final EventBus _instance = EventBus._internal();
  
  /// Singleton instance
  static EventBus get instance => _instance;
  
  EventBus._internal();
  
  /// Stream controllers for each event type
  final Map<AppEvent, StreamController<dynamic>> _controllers = {};
  
  /// Get a stream for a specific event type
  /// 
  /// Type parameter T should match the data type emitted for this event.
  Stream<T> on<T>(AppEvent event) {
    if (!_controllers.containsKey(event)) {
      _controllers[event] = StreamController<dynamic>.broadcast();
      debugPrint('[EVENT_BUS] Created stream for event: ${event.name}');
    }
    // Cast the stream instead of asserting, allowing dynamic to typed conversion
    return _controllers[event]!.stream.cast<T>();
  }
  
  /// Emit an event with optional data
  /// 
  /// All subscribers to this event will receive the data.
  void emit(AppEvent event, [dynamic data]) {
    if (!_controllers.containsKey(event)) {
      _controllers[event] = StreamController<dynamic>.broadcast();
      debugPrint('[EVENT_BUS] Created stream for event: ${event.name}');
    }
    
    debugPrint('[EVENT_BUS] Emitting event: ${event.name}');
    _controllers[event]!.add(data);
  }
  
  /// Check if there are any active listeners for an event
  bool hasListeners(AppEvent event) {
    return _controllers.containsKey(event) && 
           _controllers[event]!.hasListener;
  }
  
  /// Get the number of listeners for an event
  int listenerCount(AppEvent event) {
    if (!_controllers.containsKey(event)) return 0;
    // Note: StreamController doesn't expose listener count directly
    // This is an approximation based on hasListener
    return _controllers[event]!.hasListener ? 1 : 0;
  }
  
  /// Dispose all stream controllers
  /// 
  /// Call this when the app is shutting down or during logout.
  void dispose() {
    debugPrint('[EVENT_BUS] Disposing all event streams...');
    for (var entry in _controllers.entries) {
      debugPrint('[EVENT_BUS] Closing stream: ${entry.key.name}');
      entry.value.close();
    }
    _controllers.clear();
    debugPrint('[EVENT_BUS] ✓ All event streams disposed');
  }
  
  /// Dispose a specific event stream
  void disposeEvent(AppEvent event) {
    if (_controllers.containsKey(event)) {
      debugPrint('[EVENT_BUS] Disposing event stream: ${event.name}');
      _controllers[event]!.close();
      _controllers.remove(event);
    }
  }
  
  /// Get debug information about active streams
  Map<String, dynamic> getDebugInfo() {
    return {
      'activeStreams': _controllers.length,
      'streams': _controllers.keys.map((e) => e.name).toList(),
      'listeners': _controllers.map((key, value) => 
        MapEntry(key.name, value.hasListener)),
    };
  }
}
