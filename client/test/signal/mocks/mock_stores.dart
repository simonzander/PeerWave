import 'package:mockito/annotations.dart';
import 'package:peerwave_client/services/permanent_identity_key_store.dart';
import 'package:peerwave_client/services/permanent_pre_key_store.dart';
import 'package:peerwave_client/services/permanent_signed_pre_key_store.dart';
import 'package:peerwave_client/services/permanent_session_store.dart';
import 'package:peerwave_client/services/sender_key_store.dart';

// Generate mocks with: flutter pub run build_runner build
@GenerateMocks([
  PermanentIdentityKeyStore,
  PermanentPreKeyStore,
  PermanentSignedPreKeyStore,
  PermanentSessionStore,
  PermanentSenderKeyStore,
])
void main() {}
