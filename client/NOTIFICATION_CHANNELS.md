# Android Notification Channels Setup

## Notification Channels für PeerWave

Android 8.0+ (API level 26+) erfordert Notification Channels. Diese müssen in der Android-App definiert werden.

## 📱 Implementation

Erstellen Sie die Channels beim App-Start oder in der FCM Service-Initialisierung:

### Kotlin-Implementierung

**Datei:** `android/app/src/main/kotlin/org/peerwave/client/MainActivity.kt`

```kotlin
package org.peerwave.client

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Erstelle Notification Channels für Android 8.0+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            createNotificationChannels()
        }
    }

    private fun createNotificationChannels() {
        val notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        // Channel für Chat-Nachrichten
        val messagesChannel = NotificationChannel(
            "messages",
            "Messages",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Notifications for new chat messages"
            enableVibration(true)
            enableLights(true)
        }

        // Channel für Anrufe
        val callsChannel = NotificationChannel(
            "calls",
            "Calls",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Notifications for incoming calls"
            enableVibration(true)
            setBypassDnd(true) // Bypasses Do Not Disturb
        }

        // Channel für System-Benachrichtigungen
        val systemChannel = NotificationChannel(
            "system",
            "System",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "System notifications"
        }

        // Channels registrieren
        notificationManager.createNotificationChannel(messagesChannel)
        notificationManager.createNotificationChannel(callsChannel)
        notificationManager.createNotificationChannel(systemChannel)
    }
}
```

### Flutter-Implementierung (Alternative)

Alternativ können Sie die Channels auch von Flutter aus erstellen:

**In `fcm_service.dart` ergänzen:**

```dart
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class FCMService {
  // ...existing code...
  
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  Future<void> _createNotificationChannels() async {
    if (!Platform.isAndroid) return;

    const AndroidNotificationChannel messagesChannel = AndroidNotificationChannel(
      'messages',
      'Messages',
      description: 'Notifications for new chat messages',
      importance: Importance.high,
      enableVibration: true,
      enableLights: true,
    );

    const AndroidNotificationChannel callsChannel = AndroidNotificationChannel(
      'calls',
      'Calls',
      description: 'Notifications for incoming calls',
      importance: Importance.high,
      enableVibration: true,
      playSound: true,
    );

    const AndroidNotificationChannel systemChannel = AndroidNotificationChannel(
      'system',
      'System',
      description: 'System notifications',
      importance: Importance.defaultImportance,
    );

    await _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(messagesChannel);

    await _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(callsChannel);

    await _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(systemChannel);

    debugPrint('[FCM] ✅ Notification channels created');
  }

  Future<void> initialize() async {
    // ...existing code...
    
    // Create notification channels
    await _createNotificationChannels();
    
    // ...rest of initialization...
  }
}
```

## 📋 Verfügbare Channels

| Channel ID | Name | Importance | Beschreibung |
|------------|------|------------|--------------|
| `messages` | Messages | HIGH | Chat-Nachrichten mit Vibration und LED |
| `calls` | Calls | HIGH | Eingehende Anrufe, bypassed DND |
| `system` | System | DEFAULT | System-Benachrichtigungen |

## 🔧 Channel-IDs in Push-Notifications verwenden

Beim Senden von Push-Notifications vom Server:

```javascript
const message = {
  token: fcmToken,
  notification: {
    title: 'New Message',
    body: 'You have a new message'
  },
  android: {
    priority: 'high',
    notification: {
      sound: 'default',
      channelId: 'messages'  // ← Verwende die richtige Channel-ID
    }
  }
};

await admin.messaging().send(message);
```

## ⚠️ Wichtige Hinweise

1. **Channels können nach der Erstellung nicht mehr geändert werden** (Benutzer kann nur noch deaktivieren)
2. **Importance bestimmt das Verhalten:**
   - `HIGH`: Heads-up notification, vibration
   - `DEFAULT`: Normal notification
   - `LOW`: No sound or vibration
3. **Channel-IDs müssen eindeutig sein** und auf Server/Client übereinstimmen

## 🧪 Testing

```bash
# Test-Notification über Firebase Console senden
# Oder via curl:
curl -X POST https://fcm.googleapis.com/fcm/send \
  -H "Authorization: Bearer YOUR_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "to": "DEVICE_FCM_TOKEN",
    "notification": {
      "title": "Test",
      "body": "Test notification"
    },
    "android": {
      "notification": {
        "channelId": "messages"
      }
    }
  }'
```
