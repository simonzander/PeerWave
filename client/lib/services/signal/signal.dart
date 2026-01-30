// Signal Protocol Service - Modular Architecture
//
// This barrel file exports all Signal Protocol services for clean imports
// Use: import 'package:peerwave/services/signal/signal.dart';

// State management
export 'state/key_state.dart';
export 'state/connection_state.dart';
export 'state/sync_state.dart' hide SyncType, SyncState;

// Core services
export 'core/key_manager.dart';
export 'core/healing_service.dart';
export 'core/session_manager.dart';
export 'core/encryption_service.dart';
export 'core/message_sender.dart';
export 'core/message_receiver.dart';
export 'core/group_message_sender.dart';
export 'core/group_message_receiver.dart';

// Listeners
export 'listeners/listener_registry.dart';
export 'listeners/message_listeners.dart';
export 'listeners/group_listeners.dart';
export 'listeners/session_listeners.dart';
export 'listeners/sync_listeners.dart';

// Callbacks
export 'callbacks/callback_manager.dart';
export 'callbacks/message_callbacks.dart';
export 'callbacks/delivery_callbacks.dart';
export 'callbacks/error_callbacks.dart';

// Models
export 'models/signal_message.dart';
export 'models/group_message.dart';
export 'models/key_bundle.dart';
export 'models/session_info.dart';
export 'models/sync_status.dart';

// Utils
export 'utils/error_handler.dart';
