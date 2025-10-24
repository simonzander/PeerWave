# Global Message Listener System

## Übersicht

Das globale Message Listener System ermöglicht es, alle eingehenden Nachrichten (1:1 und Gruppen) zentral zu verarbeiten, unabhängig davon, welcher Screen gerade geöffnet ist.

## Architektur

```
┌─────────────────────────────────────────────────────────────┐
│                          main.dart                           │
│  - Initialisiert MessageListenerService beim Login          │
│  - Registriert NotificationProvider                          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              MessageListenerService (Singleton)              │
│  - Registriert globale Socket.IO Listener                   │
│  - Speichert Nachrichten im Local Storage                   │
│  - Entschlüsselt Group Messages automatisch                 │
│  - Triggert Notification Callbacks                          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│           NotificationProvider (ChangeNotifier)              │
│  - Verwaltet Unread Counts pro Channel/User                 │
│  - Speichert Recent Notifications                           │
│  - Benachrichtigt UI über Updates                           │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   UI Widgets & Screens                       │
│  - NotificationBadge Widget für Unread Counts              │
│  - Screens markieren Nachrichten als gelesen               │
└─────────────────────────────────────────────────────────────┘
```

## Komponenten

### 1. MessageListenerService

**Zweck:** Zentrale Verwaltung aller Message Listener

**Features:**
- ✅ Automatische Initialisierung beim Login
- ✅ Registriert Socket.IO Listener für `receiveItem` (1:1) und `groupItem` (Group)
- ✅ Speichert Nachrichten automatisch im Local Storage
- ✅ Entschlüsselt Group Messages mit Auto-Reload bei Fehlern
- ✅ Triggert Notification Callbacks für UI Updates
- ✅ Läuft im Hintergrund, unabhängig vom aktuellen Screen

**Location:** `lib/services/message_listener_service.dart`

### 2. NotificationProvider

**Zweck:** State Management für Notifications und Unread Counts

**Features:**
- ✅ Verwaltet Unread Counts pro Channel/User
- ✅ Speichert Recent Notifications (letzte 50)
- ✅ ChangeNotifier für automatische UI Updates
- ✅ `markAsRead()` zum Zurücksetzen von Counts
- ✅ `getUnreadCount()` für spezifische Channels/Users

**Location:** `lib/providers/notification_provider.dart`

### 3. NotificationBadge Widget

**Zweck:** Visuelle Darstellung von Unread Counts

**Features:**
- ✅ `NotificationBadge` - Badge für einzelnen Channel/User
- ✅ `GlobalNotificationBadge` - Gesamt-Badge für alle Nachrichten
- ✅ Automatische Updates via Provider
- ✅ Rote Badge mit Count (99+ bei >99)

**Location:** `lib/widgets/notification_badge.dart`

## Integration in Screens

### Beispiel: Group Chat Screen

**Vorher:** Screen registriert eigene Listener
```dart
@override
void initState() {
  super.initState();
  SignalService.instance.registerItemCallback('groupItem', _handleGroupItem);
}

@override
void dispose() {
  SignalService.instance.unregisterItemCallback('groupItem', _handleGroupItem);
  super.dispose();
}
```

**Nachher:** Screen nutzt globales System und markiert nur als gelesen
```dart
@override
void initState() {
  super.initState();
  _loadMessages();
  
  // Mark as read when entering screen
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Provider.of<NotificationProvider>(context, listen: false)
        .markAsRead(widget.channelUuid);
  });
}

// Optional: Listen to new messages if screen needs real-time updates
@override
void initState() {
  super.initState();
  _loadMessages();
  _listenToNewMessages();
}

void _listenToNewMessages() {
  MessageListenerService.instance.registerNotificationCallback((notification) {
    if (notification.type == MessageType.group && 
        notification.channelId == widget.channelUuid) {
      // Update UI with new message
      _loadMessages();
    }
  });
}
```

### Beispiel: 1:1 Chat Screen

```dart
@override
void initState() {
  super.initState();
  _loadMessages();
  
  // Mark as read
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Provider.of<NotificationProvider>(context, listen: false)
        .markAsRead(widget.userId);
  });
}
```

## Verwendung von NotificationBadge

### In Channel Liste:
```dart
ListTile(
  leading: NotificationBadge(
    channelId: channel.uuid,
    child: Icon(Icons.tag),
  ),
  title: Text(channel.name),
  onTap: () {
    // Navigate to channel
    // Badge wird automatisch zurückgesetzt wenn Screen markAsRead() aufruft
  },
)
```

### In User Liste (1:1 Chats):
```dart
ListTile(
  leading: NotificationBadge(
    userId: user.uuid,
    child: CircleAvatar(
      backgroundImage: NetworkImage(user.picture),
    ),
  ),
  title: Text(user.displayName),
)
```

### Globaler Badge in AppBar:
```dart
AppBar(
  title: Text('PeerWave'),
  actions: [
    GlobalNotificationBadge(
      child: IconButton(
        icon: Icon(Icons.notifications),
        onPressed: () => _showNotifications(),
      ),
    ),
  ],
)
```

## Workflow

### 1. Neue Nachricht kommt an (Group Message)

```
1. Server sendet "groupItem" via Socket.IO
   ↓
2. MessageListenerService empfängt Event
   ↓
3. Nachricht wird entschlüsselt (mit Auto-Reload bei Fehler)
   ↓
4. Nachricht wird in decryptedGroupItemsStore gespeichert
   ↓
5. Notification Callback wird getriggert
   ↓
6. NotificationProvider erhöht Unread Count
   ↓
7. NotificationProvider.notifyListeners()
   ↓
8. Alle NotificationBadge Widgets aktualisieren sich automatisch
   ↓
9. User öffnet Channel Screen
   ↓
10. Screen ruft markAsRead(channelId) auf
    ↓
11. Badge verschwindet
```

### 2. Neue Nachricht kommt an (1:1 Message)

```
1. Server sendet "receiveItem" via Socket.IO
   ↓
2. MessageListenerService empfängt Event
   ↓
3. Notification wird getriggert (noch verschlüsselt)
   ↓
4. NotificationProvider erhöht Unread Count
   ↓
5. Badge zeigt neue Nachricht an
   ↓
6. User öffnet Chat
   ↓
7. Screen entschlüsselt und lädt Nachrichten
   ↓
8. Screen ruft markAsRead(userId) auf
   ↓
9. Badge verschwindet
```

## Vorteile

✅ **Zentrale Verwaltung:** Alle Message Listener an einem Ort  
✅ **Hintergrund-Speicherung:** Nachrichten werden auch gespeichert wenn Screen nicht offen ist  
✅ **Automatische Entschlüsselung:** Group Messages werden automatisch entschlüsselt und gespeichert  
✅ **Real-time Notifications:** Sofortige UI Updates über Provider  
✅ **Flexible Integration:** Screens können optional zusätzliche Listener registrieren  
✅ **Weniger Code-Duplikation:** Kein redundanter Listener-Code in jedem Screen  
✅ **Bessere UX:** User sieht Unread Counts auch wenn Screen nicht offen war  

## Migration Bestehender Screens

### Schritt 1: Eigene Listener entfernen
```dart
// ENTFERNEN:
SignalService.instance.registerItemCallback('groupItem', _handleGroupItem);
SignalService.instance.unregisterItemCallback('groupItem', _handleGroupItem);
```

### Schritt 2: markAsRead() hinzufügen
```dart
@override
void initState() {
  super.initState();
  _loadMessages();
  
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Provider.of<NotificationProvider>(context, listen: false)
        .markAsRead(widget.channelUuid); // oder widget.userId für 1:1
  });
}
```

### Schritt 3: Optional - Real-time Updates
Wenn der Screen sich automatisch aktualisieren soll bei neuen Nachrichten:
```dart
void _listenToNewMessages() {
  MessageListenerService.instance.registerNotificationCallback(_onNewMessage);
}

void _onNewMessage(MessageNotification notification) {
  if (notification.channelId == widget.channelUuid) {
    setState(() {
      _loadMessages(); // Oder füge Nachricht direkt hinzu
    });
  }
}

@override
void dispose() {
  MessageListenerService.instance.unregisterNotificationCallback(_onNewMessage);
  super.dispose();
}
```

## Testing

```dart
// Test: Notification wird getriggert
test('MessageListenerService triggers notification on group message', () async {
  bool notificationReceived = false;
  
  MessageListenerService.instance.registerNotificationCallback((notification) {
    notificationReceived = true;
    expect(notification.type, MessageType.group);
  });
  
  // Simulate incoming message
  SocketService().simulateEvent('groupItem', {...});
  
  await Future.delayed(Duration(milliseconds: 100));
  expect(notificationReceived, true);
});
```

## Debugging

**Log Messages:**
```
[MESSAGE_LISTENER] Initializing global message listeners...
[MESSAGE_LISTENER] Global message listeners initialized
[MESSAGE_LISTENER] Received group message
[MESSAGE_LISTENER] Group message decrypted and stored: abc-123
[MESSAGE_LISTENER] Triggering notification: MessageType.group from user-456
[NOTIFICATION_PROVIDER] Received notification: MessageType.group
[NOTIFICATION_PROVIDER] Group message in channel-789, unread: 1
```

## Nächste Schritte

1. ✅ MessageListenerService implementiert
2. ✅ NotificationProvider implementiert
3. ✅ NotificationBadge Widget erstellt
4. ✅ Integration in main.dart
5. ⏳ Migration bestehender Screens (signal_group_chat_screen.dart, direct_messages_screen.dart)
6. ⏳ Toast Notifications hinzufügen (optional)
7. ⏳ Sound Notifications hinzufügen (optional)
8. ⏳ Push Notifications Integration (optional, für Native Apps)
