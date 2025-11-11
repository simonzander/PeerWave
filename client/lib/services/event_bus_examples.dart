/// Event Bus Usage Examples
/// 
/// This file demonstrates how to use the Event Bus in different scenarios.

import 'dart:async';
import 'package:flutter/material.dart';
import '../services/event_bus.dart';

// ============================================================================
// Example 1: Service emitting events
// ============================================================================

class ExampleMessageService {
  /// Send a message and emit event
  Future<void> sendMessage(String recipientId, String content) async {
    // ... send message logic ...
    
    // Emit event for all listeners
    EventBus.instance.emit(AppEvent.newMessage, {
      'recipientId': recipientId,
      'content': content,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
}

// ============================================================================
// Example 2: Widget listening to events
// ============================================================================

class ExampleMessageListWidget extends StatefulWidget {
  const ExampleMessageListWidget({super.key});

  @override
  State<ExampleMessageListWidget> createState() => _ExampleMessageListWidgetState();
}

class _ExampleMessageListWidgetState extends State<ExampleMessageListWidget> {
  List<Map<String, dynamic>> _messages = [];
  StreamSubscription? _messageSubscription;
  
  @override
  void initState() {
    super.initState();
    
    // Subscribe to new message events
    _messageSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newMessage)
        .listen((messageData) {
      // Update UI when new message arrives
      if (mounted) {
        setState(() {
          _messages.add(messageData);
        });
      }
    });
  }
  
  @override
  void dispose() {
    // Always cancel subscriptions in dispose
    _messageSubscription?.cancel();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        return ListTile(
          title: Text(message['content'] as String),
          subtitle: Text(message['timestamp'] as String),
        );
      },
    );
  }
}

// ============================================================================
// Example 3: Multiple listeners for same event
// ============================================================================

class ExampleNotificationService {
  StreamSubscription? _subscription;
  
  void start() {
    // Multiple services can listen to the same event
    _subscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newMessage)
        .listen((messageData) {
      // Show notification
      _showNotification(messageData);
    });
  }
  
  void _showNotification(Map<String, dynamic> data) {
    // Show notification logic
    debugPrint('Notification: New message from ${data['recipientId']}');
  }
  
  void stop() {
    _subscription?.cancel();
  }
}

// ============================================================================
// Example 4: Conditional event handling
// ============================================================================

class ExampleConversationWidget extends StatefulWidget {
  final String conversationId;
  
  const ExampleConversationWidget({
    super.key,
    required this.conversationId,
  });

  @override
  State<ExampleConversationWidget> createState() => _ExampleConversationWidgetState();
}

class _ExampleConversationWidgetState extends State<ExampleConversationWidget> {
  List<Map<String, dynamic>> _messages = [];
  StreamSubscription? _subscription;
  
  @override
  void initState() {
    super.initState();
    
    // Listen to messages but only update if they're for this conversation
    _subscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newMessage)
        .listen((messageData) {
      // Filter: Only add message if it's for this conversation
      if (messageData['recipientId'] == widget.conversationId) {
        if (mounted) {
          setState(() {
            _messages.add(messageData);
          });
        }
      }
    });
  }
  
  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        return Text(_messages[index]['content'] as String);
      },
    );
  }
}

// ============================================================================
// Example 5: Debugging - Check active listeners
// ============================================================================

class EventBusDebugWidget extends StatelessWidget {
  const EventBusDebugWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final debugInfo = EventBus.instance.getDebugInfo();
    
    return Column(
      children: [
        Text('Active Streams: ${debugInfo['activeStreams']}'),
        Text('Streams: ${debugInfo['streams']}'),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: () {
            // Emit test event
            EventBus.instance.emit(AppEvent.newMessage, {
              'test': 'data',
              'timestamp': DateTime.now().toIso8601String(),
            });
          },
          child: const Text('Emit Test Event'),
        ),
      ],
    );
  }
}

// ============================================================================
// Example 6: Cleanup on logout
// ============================================================================

class ExampleLogoutService {
  static Future<void> logout() async {
    // ... logout logic ...
    
    // Cleanup all event bus subscriptions
    EventBus.instance.dispose();
    
    debugPrint('Event Bus disposed on logout');
  }
}

// ============================================================================
// Best Practices Summary
// ============================================================================

/// Event Bus Best Practices:
/// 
/// 1. **Always cancel subscriptions in dispose()**
///    - Prevents memory leaks
///    - Use StreamSubscription variables to track subscriptions
/// 
/// 2. **Check mounted before setState()**
///    - Prevents calling setState on disposed widgets
///    - Pattern: `if (mounted) { setState(() {...}); }`
/// 
/// 3. **Type your event data**
///    - Use generics: `on<Map<String, dynamic>>(AppEvent.newMessage)`
///    - Makes code more predictable and type-safe
/// 
/// 4. **Filter events when needed**
///    - Not all events are relevant to all listeners
///    - Use conditional logic in listen callback
/// 
/// 5. **Emit events from services, not widgets**
///    - Services are single source of truth
///    - Widgets should only listen, not emit
/// 
/// 6. **Dispose Event Bus on logout**
///    - Call `EventBus.instance.dispose()` when logging out
///    - Prevents events from previous session
/// 
/// 7. **Use descriptive event names**
///    - AppEvent enum makes events discoverable
///    - Better than magic strings
/// 
/// 8. **Debug with getDebugInfo()**
///    - Check active streams and listeners
///    - Useful for troubleshooting
