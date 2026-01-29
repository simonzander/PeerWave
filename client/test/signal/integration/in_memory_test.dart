import 'package:flutter_test/flutter_test.dart';
import '../helpers/simple_test_user.dart';

/// Real integration tests using in-memory stores
/// No database, no API, no Socket needed - pure Signal protocol testing!
void main() {
  group('Signal Protocol Integration - In Memory', () {
    test('Two users can establish session and exchange messages', () async {
      // Create Alice and Bob with in-memory stores
      final alice = await createTestUser('alice@test.com');
      final bob = await createTestUser('bob@test.com');

      print('✓ Created Alice and Bob');

      // Alice builds session with Bob
      await alice.buildSessionWith(bob);

      print('✓ Alice built session with Bob');

      // Verify session exists
      expect(await alice.hasSessionWith(bob), isTrue);

      print('✓ Session established');

      // Alice sends message to Bob
      final ciphertext = await alice.encryptTo(bob, 'Hello Bob!');

      print('✓ Alice encrypted message');

      // Bob decrypts message
      final plaintext = await bob.decryptFrom(alice, ciphertext);

      print('✓ Bob decrypted message');

      // Verify message
      expect(plaintext, equals('Hello Bob!'));

      print('✅ Test passed - message delivered!');
    });

    test('Bob can reply to Alice', () async {
      final alice = await createTestUser('alice@test.com');
      final bob = await createTestUser('bob@test.com');

      // Alice initiates
      await alice.buildSessionWith(bob);
      final msg1 = await alice.encryptTo(bob, 'Hello Bob!');
      await bob.decryptFrom(alice, msg1);

      print('✓ Initial message delivered');

      // Bob replies (session should be established from receiving PreKeyMessage)
      final reply = await bob.encryptTo(alice, 'Hi Alice!');

      print('✓ Bob encrypted reply');

      final plaintext = await alice.decryptFrom(bob, reply);

      print('✓ Alice decrypted reply');

      expect(plaintext, equals('Hi Alice!'));

      print('✅ Two-way communication works!');
    });

    test('Multiple messages in both directions', () async {
      final alice = await createTestUser('alice@test.com');
      final bob = await createTestUser('bob@test.com');

      // Establish session
      await alice.buildSessionWith(bob);

      // Alice -> Bob
      final msg1 = await alice.encryptTo(bob, 'Message 1');
      expect(await bob.decryptFrom(alice, msg1), equals('Message 1'));

      // Bob -> Alice
      final msg2 = await bob.encryptTo(alice, 'Message 2');
      expect(await alice.decryptFrom(bob, msg2), equals('Message 2'));

      // Alice -> Bob
      final msg3 = await alice.encryptTo(bob, 'Message 3');
      expect(await bob.decryptFrom(alice, msg3), equals('Message 3'));

      // Bob -> Alice
      final msg4 = await bob.encryptTo(alice, 'Message 4');
      expect(await alice.decryptFrom(bob, msg4), equals('Message 4'));

      print('✅ 4 messages exchanged successfully!');
    });

    test('Each user has independent stores', () async {
      final alice = await createTestUser('alice@test.com');
      final bob = await createTestUser('bob@test.com');
      final charlie = await createTestUser('charlie@test.com');

      // Verify different identity keys
      final aliceKey = await alice.getIdentityKey();
      final bobKey = await bob.getIdentityKey();
      final charlieKey = await charlie.getIdentityKey();

      expect(aliceKey.serialize(), isNot(equals(bobKey.serialize())));
      expect(bobKey.serialize(), isNot(equals(charlieKey.serialize())));
      expect(aliceKey.serialize(), isNot(equals(charlieKey.serialize())));

      // Verify independent sessions
      await alice.buildSessionWith(bob);
      expect(await alice.hasSessionWith(bob), isTrue);
      expect(await alice.hasSessionWith(charlie), isFalse);
      expect(await bob.hasSessionWith(charlie), isFalse);

      print('✅ Users are properly isolated!');
    });

    test('Session persists across multiple encryptions', () async {
      final alice = await createTestUser('alice@test.com');
      final bob = await createTestUser('bob@test.com');

      await alice.buildSessionWith(bob);

      // Send 10 messages
      for (int i = 0; i < 10; i++) {
        final message = 'Message $i';
        final ciphertext = await alice.encryptTo(bob, message);
        final plaintext = await bob.decryptFrom(alice, ciphertext);
        expect(plaintext, equals(message));
      }

      print('✅ 10 messages encrypted/decrypted with persistent session!');
    });
  });
}
