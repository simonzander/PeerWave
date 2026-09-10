import 'package:flutter_test/flutter_test.dart';

import 'package:peerwave_client/core/events/event_bus.dart';

void main() {
  test('sender-key request and response events carry their payloads', () async {
    final eventBus = EventBus.testInstance();
    addTearDown(eventBus.dispose);

    final requestFuture = eventBus
        .on<Map<String, dynamic>>(AppEvent.senderKeyRequest)
        .first;
    final responseFuture = eventBus
        .on<Map<String, dynamic>>(AppEvent.senderKeyResponse)
        .first;

    final request = <String, dynamic>{
      'groupId': 'group-1',
      'requesterId': 'user-1',
      'requesterDeviceId': 2,
    };
    final response = <String, dynamic>{
      'groupId': 'group-1',
      'responderId': 'user-2',
      'responderDeviceId': 3,
    };

    eventBus.emit(AppEvent.senderKeyRequest, request);
    eventBus.emit(AppEvent.senderKeyResponse, response);

    expect(await requestFuture, same(request));
    expect(await responseFuture, same(response));
  });
}
