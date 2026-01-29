import 'package:mockito/annotations.dart';
import 'package:peerwave_client/services/signal/core/key_manager.dart';
import 'package:peerwave_client/services/signal/core/session_manager.dart';
import 'package:peerwave_client/services/signal/core/encryption_service.dart';
import 'package:peerwave_client/services/signal/core/healing_service.dart';
import 'package:peerwave_client/services/signal/core/message_sender.dart';
import 'package:peerwave_client/services/signal/core/message_receiver.dart';
import 'package:peerwave_client/services/signal/core/group_message_sender.dart';
import 'package:peerwave_client/services/signal/core/group_message_receiver.dart';

// Generate mocks with: flutter pub run build_runner build
@GenerateMocks([
  SignalKeyManager,
  SessionManager,
  EncryptionService,
  SignalHealingService,
  MessageSender,
  MessageReceiver,
  GroupMessageSender,
  GroupMessageReceiver,
])
void main() {}
