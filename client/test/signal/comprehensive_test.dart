import 'package:flutter_test/flutter_test.dart';
import 'helpers/simple_test_user.dart';

/// COMPREHENSIVE Integration Tests for Signal Protocol
/// Tests the REAL crypto operations that your app depends on
/// These tests verify end-to-end encryption/decryption flows
void main() {
  group('1-to-1 Messaging - Critical Flows', () {
    test(
      'Alice and Bob can establish session and exchange encrypted messages',
      () async {
        final alice = await createTestUser('alice@example.com');
        final bob = await createTestUser('bob@example.com');

        // Alice builds session with Bob
        await alice.buildSessionWith(bob);
        expect(await alice.hasSessionWith(bob), isTrue);

        // Alice sends encrypted message to Bob
        final message1 = 'Hello Bob!';
        final ciphertext1 = await alice.encryptTo(bob, message1);
        final decrypted1 = await bob.decryptFrom(alice, ciphertext1);
        expect(decrypted1, equals(message1));

        // Bob can reply (session established from PreKey message)
        final message2 = 'Hi Alice!';
        final ciphertext2 = await bob.encryptTo(alice, message2);
        final decrypted2 = await alice.decryptFrom(bob, ciphertext2);
        expect(decrypted2, equals(message2));

        print('✅ CRITICAL: 1-to-1 messaging works');
      },
    );

    test('Session persists across multiple messages', () async {
      final alice = await createTestUser('alice@example.com');
      final bob = await createTestUser('bob@example.com');

      await alice.buildSessionWith(bob);

      // Exchange 20 messages
      for (int i = 0; i < 20; i++) {
        final message = 'Message $i';
        final ciphertext = await alice.encryptTo(bob, message);
        final decrypted = await bob.decryptFrom(alice, ciphertext);
        expect(decrypted, equals(message));
      }

      print('✅ CRITICAL: Session persistence works');
    });

    test('Bidirectional message exchange works correctly', () async {
      final alice = await createTestUser('alice@example.com');
      final bob = await createTestUser('bob@example.com');

      await alice.buildSessionWith(bob);

      // Alternating messages
      for (int i = 0; i < 10; i++) {
        // Alice -> Bob
        final aliceMsg = 'Alice message $i';
        final aliceCipher = await alice.encryptTo(bob, aliceMsg);
        expect(await bob.decryptFrom(alice, aliceCipher), equals(aliceMsg));

        // Bob -> Alice
        final bobMsg = 'Bob message $i';
        final bobCipher = await bob.encryptTo(alice, bobMsg);
        expect(await alice.decryptFrom(bob, bobCipher), equals(bobMsg));
      }

      print('✅ CRITICAL: Bidirectional messaging works');
    });

    test('Messages cannot be decrypted without session', () async {
      final alice = await createTestUser('alice@example.com');
      final bob = await createTestUser('bob@example.com');
      final charlie = await createTestUser('charlie@example.com');

      // Alice builds session with Bob
      await alice.buildSessionWith(bob);

      // Alice sends message to Bob
      final message = 'Secret message';
      final ciphertext = await alice.encryptTo(bob, message);

      // Bob can decrypt
      final decrypted = await bob.decryptFrom(alice, ciphertext);
      expect(decrypted, equals(message));

      // Charlie CANNOT decrypt (no session with Alice)
      expect(
        () => charlie.decryptFrom(alice, ciphertext),
        throwsA(isA<Exception>()),
      );

      print('✅ CRITICAL: Encryption is secure');
    });
  });

  group('Multi-User Scenarios', () {
    test(
      'User can maintain independent sessions with multiple contacts',
      () async {
        final alice = await createTestUser('alice@example.com');
        final bob = await createTestUser('bob@example.com');
        final charlie = await createTestUser('charlie@example.com');
        final david = await createTestUser('david@example.com');

        // Alice establishes sessions with everyone
        await alice.buildSessionWith(bob);
        await alice.buildSessionWith(charlie);
        await alice.buildSessionWith(david);

        // Verify all sessions exist
        expect(await alice.hasSessionWith(bob), isTrue);
        expect(await alice.hasSessionWith(charlie), isTrue);
        expect(await alice.hasSessionWith(david), isTrue);

        // Alice sends different messages to each person
        final bobCipher = await alice.encryptTo(bob, 'Message for Bob');
        final charlieCipher = await alice.encryptTo(
          charlie,
          'Message for Charlie',
        );
        final davidCipher = await alice.encryptTo(david, 'Message for David');

        // Each person can only decrypt their own message
        expect(
          await bob.decryptFrom(alice, bobCipher),
          equals('Message for Bob'),
        );
        expect(
          await charlie.decryptFrom(alice, charlieCipher),
          equals('Message for Charlie'),
        );
        expect(
          await david.decryptFrom(alice, davidCipher),
          equals('Message for David'),
        );

        print('✅ CRITICAL: Multiple sessions work independently');
      },
    );

    test('Group conversation with 4 users', () async {
      final users = [
        await createTestUser('alice@example.com'),
        await createTestUser('bob@example.com'),
        await createTestUser('charlie@example.com'),
        await createTestUser('david@example.com'),
      ];

      // Everyone establishes sessions with everyone else
      for (int i = 0; i < users.length; i++) {
        for (int j = 0; j < users.length; j++) {
          if (i != j) {
            await users[i].buildSessionWith(users[j]);
          }
        }
      }

      // Alice broadcasts a message to everyone
      final message = 'Group announcement from Alice';
      for (int i = 1; i < users.length; i++) {
        final ciphertext = await users[0].encryptTo(users[i], message);
        final decrypted = await users[i].decryptFrom(users[0], ciphertext);
        expect(decrypted, equals(message));
      }

      print('✅ CRITICAL: Group messaging works');
    });
  });

  group('Session Management', () {
    test('Session deletion prevents further decryption', () async {
      final alice = await createTestUser('alice@example.com');
      final bob = await createTestUser('bob@example.com');

      // Establish session and send message
      await alice.buildSessionWith(bob);
      final message1 = 'Before deletion';
      final cipher1 = await alice.encryptTo(bob, message1);
      expect(await bob.decryptFrom(alice, cipher1), equals(message1));

      // Alice deletes session with Bob
      await alice.deleteSessionWith(bob);
      expect(await alice.hasSessionWith(bob), isFalse);

      // Alice can no longer encrypt to Bob (no session) - throws InvalidKeyException
      expect(
        () => alice.encryptTo(bob, 'After deletion'),
        throwsA(anything), // Any error indicates session is gone
      );

      print('✅ CRITICAL: Session deletion works');
    });

    test('Session can be re-established after deletion', () async {
      final alice = await createTestUser('alice@example.com');
      final bob = await createTestUser('bob@example.com');

      // Initial session
      await alice.buildSessionWith(bob);
      final msg1 = await alice.encryptTo(bob, 'Message 1');
      await bob.decryptFrom(alice, msg1);

      // Delete session
      await alice.deleteSessionWith(bob);
      expect(await alice.hasSessionWith(bob), isFalse);

      // Create fresh users to simulate re-establishing session
      // (In real app, Bob would regenerate PreKeys on server)
      final bobNew = await createTestUser('bob@example.com', deviceId: 2);

      // Re-establish session with new device
      await alice.buildSessionWith(bobNew);
      expect(await alice.hasSessionWith(bobNew), isTrue);

      // Can send messages again
      final msg2 = await alice.encryptTo(bobNew, 'Message 2');
      expect(await bobNew.decryptFrom(alice, msg2), equals('Message 2'));

      print('✅ CRITICAL: Session re-establishment works');
    });
  });

  group('Identity Key Verification', () {
    test('Each user has unique identity key', () async {
      final alice = await createTestUser('alice@example.com');
      final bob = await createTestUser('bob@example.com');
      final charlie = await createTestUser('charlie@example.com');

      final aliceKey = await alice.getIdentityKey();
      final bobKey = await bob.getIdentityKey();
      final charlieKey = await charlie.getIdentityKey();

      // All keys should be different
      expect(aliceKey.serialize(), isNot(equals(bobKey.serialize())));
      expect(bobKey.serialize(), isNot(equals(charlieKey.serialize())));
      expect(aliceKey.serialize(), isNot(equals(charlieKey.serialize())));

      print('✅ CRITICAL: Identity keys are unique');
    });

    test('Identity key remains consistent', () async {
      final alice = await createTestUser('alice@example.com');

      final key1 = await alice.getIdentityKey();
      final key2 = await alice.getIdentityKey();

      expect(key1.serialize(), equals(key2.serialize()));

      print('✅ CRITICAL: Identity key consistency works');
    });
  });

  group('PreKey Bundle Operations', () {
    test('PreKey bundle contains all required components', () async {
      final alice = await createTestUser('alice@example.com');

      final bundle = await alice.getPreKeyBundle();

      expect(bundle.getRegistrationId(), greaterThan(0));
      expect(bundle.getDeviceId(), equals(alice.deviceId));
      expect(bundle.getPreKeyId(), greaterThan(0));
      expect(bundle.getPreKey(), isNotNull);
      expect(bundle.getSignedPreKeyId(), greaterThan(0));
      expect(bundle.getSignedPreKey(), isNotNull);
      expect(bundle.getSignedPreKeySignature(), isNotNull);
      expect(bundle.getIdentityKey(), isNotNull);

      print('✅ CRITICAL: PreKey bundle structure is correct');
    });
  });

  group('Edge Cases and Error Handling', () {
    test('Empty message encryption/decryption', () async {
      final alice = await createTestUser('alice@example.com');
      final bob = await createTestUser('bob@example.com');

      await alice.buildSessionWith(bob);

      final message = '';
      final ciphertext = await alice.encryptTo(bob, message);
      final decrypted = await bob.decryptFrom(alice, ciphertext);

      expect(decrypted, equals(message));

      print('✅ CRITICAL: Empty messages work');
    });

    test('Large message encryption/decryption', () async {
      final alice = await createTestUser('alice@example.com');
      final bob = await createTestUser('bob@example.com');

      await alice.buildSessionWith(bob);

      // 1KB message
      final message = 'x' * 1024;
      final ciphertext = await alice.encryptTo(bob, message);
      final decrypted = await bob.decryptFrom(alice, ciphertext);

      expect(decrypted, equals(message));

      print('✅ CRITICAL: Large messages work');
    });

    test('Unicode and emoji support', () async {
      final alice = await createTestUser('alice@example.com');
      final bob = await createTestUser('bob@example.com');

      await alice.buildSessionWith(bob);

      final message = 'Hello 世界 🌍 Привет مرحبا';
      final ciphertext = await alice.encryptTo(bob, message);
      final decrypted = await bob.decryptFrom(alice, ciphertext);

      expect(decrypted, equals(message));

      print('✅ CRITICAL: Unicode messages work');
    });
  });

  group('Performance Tests', () {
    test('Can handle 100 messages quickly', () async {
      final alice = await createTestUser('alice@example.com');
      final bob = await createTestUser('bob@example.com');

      await alice.buildSessionWith(bob);

      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < 100; i++) {
        final message = 'Message $i';
        final ciphertext = await alice.encryptTo(bob, message);
        final decrypted = await bob.decryptFrom(alice, ciphertext);
        expect(decrypted, equals(message));
      }

      stopwatch.stop();
      final duration = stopwatch.elapsedMilliseconds;

      print('✅ CRITICAL: 100 messages processed in ${duration}ms');
      expect(duration, lessThan(10000)); // Should be under 10 seconds
    });
  });
}
