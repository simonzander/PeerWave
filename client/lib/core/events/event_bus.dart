import 'dart:async';
import 'package:flutter/foundation.dart';

/// Application-wide event identifiers.
///
/// Each event represents a specific occurrence in the application lifecycle.
/// Events should be stateless identifiers - data is passed separately.
enum AppEvent {
  /// A new direct or channel message has been received.
  newMessage,

  /// A new activity notification (mention, reaction, missed call) occurred.
  newNotification,

  /// An emoji reaction was added or removed from a message.
  reactionUpdated,

  /// A new channel has been created.
  newChannel,

  /// Channel metadata (name, members, settings) has changed.
  channelUpdated,

  /// A channel has been permanently deleted.
  channelDeleted,

  /// The current user joined a channel.
  channelJoined,

  /// The current user left a channel.
  channelLeft,

  /// A user was removed from a channel by a moderator.
  userKicked,

  /// User presence or status changed (online, offline, typing).
  userStatusChanged,

  /// A new direct conversation was initiated.
  newConversation,

  /// A conversation was deleted.
  conversationDeleted,

  /// The unread message count changed for one or more conversations.
  unreadCountChanged,

  /// File upload progress update (percentage, bytes transferred).
  fileUploadProgress,

  /// A file upload has completed successfully.
  fileUploadComplete,

  /// Video conference state changed (joined, left, participant added/removed).
  videoConferenceStateChanged,

  /// Background sync of pending messages has started.
  syncStarted,

  /// Progress update during pending message sync.
  syncProgress,

  /// Pending message sync completed successfully.
  syncComplete,

  /// An error occurred during pending message sync.
  syncError,
}

/// Application-wide publish-subscribe event bus for decoupled communication.
///
/// Provides type-safe event broadcasting without requiring direct dependencies
/// between components. Events are identified by [AppEvent] enum values.
///
/// Usage:
/// ```dart
/// // Subscribe to events
/// final subscription = EventBus.instance
///   .on<Map<String, dynamic>>(AppEvent.newMessage)
///   .listen((data) => handleMessage(data));
///
/// // Emit events
/// EventBus.instance.emit(AppEvent.newMessage, {'id': '123'});
///
/// // Clean up
/// subscription.cancel();
/// ```
///
/// Subscriptions must be cancelled to prevent memory leaks. Use [testInstance]
/// for isolated testing.
class EventBus {
  /// The singleton instance for production use.
  static final EventBus _instance = EventBus._internal();

  /// Singleton accessor for application-wide event bus.
  static EventBus get instance => _instance;

  /// Creates a new instance for isolated testing.
  ///
  /// Returns a fresh event bus that can be disposed independently.
  @visibleForTesting
  factory EventBus.testInstance() => EventBus._internal();

  EventBus._internal();

  /// Stream controllers for each event type, created lazily on first access.
  final Map<AppEvent, StreamController<Object?>> _controllers = {};

  /// Whether this event bus has been disposed.
  bool _isDisposed = false;

  /// Returns a broadcast stream that emits data when [event] is fired.
  ///
  /// Type parameter [T] must match the data type used in [emit], or
  /// use [Object?] for dynamic data. Throws [StateError] if disposed.
  Stream<T> on<T extends Object?>(AppEvent event) {
    if (_isDisposed) {
      throw StateError('Cannot subscribe to disposed EventBus');
    }

    final controller = _controllers.putIfAbsent(event, () {
      if (kDebugMode) {
        debugPrint('[EventBus] Creating stream for ${event.name}');
      }
      return StreamController<Object?>.broadcast();
    });

    // Safe cast: subscribers must match emit type or use Object?
    return controller.stream.cast<T>();
  }

  /// Emits [event] with optional [data] to all subscribers.
  ///
  /// Data type should match what subscribers expect via [on]. Broadcast
  /// streams don't queue events if no listeners exist. Throws [StateError]
  /// if disposed.
  void emit(AppEvent event, [Object? data]) {
    if (_isDisposed) {
      throw StateError('Cannot emit on disposed EventBus');
    }

    final controller = _controllers.putIfAbsent(event, () {
      if (kDebugMode) {
        debugPrint('[EventBus] Creating stream for ${event.name}');
      }
      return StreamController<Object?>.broadcast();
    });

    if (kDebugMode) {
      debugPrint('[EventBus] Emitting ${event.name}');
    }

    // Broadcast streams don't throw if there are no listeners
    controller.add(data);
  }

  /// Returns true if [event] has active listeners.
  bool hasListeners(AppEvent event) {
    final controller = _controllers[event];
    return controller != null && controller.hasListener;
  }

  /// Closes all stream controllers and prevents further operations.
  ///
  /// After disposal, [emit] and [on] will throw [StateError]. The singleton
  /// typically lives for the app lifetime. Always dispose [testInstance].
  void dispose() {
    if (_isDisposed) return;

    if (kDebugMode) {
      debugPrint('[EventBus] Disposing ${_controllers.length} streams');
    }

    for (final controller in _controllers.values) {
      controller.close();
    }
    _controllers.clear();
    _isDisposed = true;
  }

  /// Closes and removes the stream controller for [event].
  void disposeEvent(AppEvent event) {
    final controller = _controllers.remove(event);
    if (controller != null) {
      if (kDebugMode) {
        debugPrint('[EventBus] Disposing stream for ${event.name}');
      }
      controller.close();
    }
  }

  /// Returns diagnostic information about active streams and listeners.
  @visibleForTesting
  Map<String, Object> getDebugInfo() {
    return {
      'activeStreams': _controllers.length,
      'isDisposed': _isDisposed,
      'streams': _controllers.keys.map((e) => e.name).toList(),
      'listeners': {
        for (final entry in _controllers.entries)
          entry.key.name: entry.value.hasListener,
      },
    };
  }
}
