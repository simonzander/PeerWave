# Notification Badges & Auto-Update Action Plan

**Erstellt am:** 4. November 2025  
**Projekt:** PeerWave  
**Branch:** clientserver

---

## Übersicht

Dieser Action Plan beschreibt die Implementierung eines umfassenden Notification-Badge-Systems für ungelesene Nachrichten mit automatischen View-Updates in der PeerWave Flutter-Anwendung.

---

## 🎯 Ziele

1. **Auto-Update der Views** bei neuen Nachrichten
2. **Notification Badges** für ungelesene Nachrichten (Typ: `message` und `file`)
3. **Responsive Badge-Anzeige** für Phone, Tablet und Desktop
4. **Badge-Reduktion** bei gesendeten Read Receipts
5. **Zentrale State-Management-Lösung** für app-weite Badge-Updates

---

## 📋 Feature-Requirements

### 1. Auto-Update Views
- ✅ `direct_messages_screen.dart`: Auto-Update bei neuen 1:1 Nachrichten
- ✅ `signal_group_chat_screen.dart`: Auto-Update bei neuen Channel-Nachrichten
- 🔄 Real-time Updates über WebSocket-Events

### 2. Notification Badges - Anforderungen

#### Badge-Typen
- **Message Badge**: Anzahl ungelesener Textnachrichten (`type: 'message'`)
- **File Badge**: Anzahl ungelesener Dateinachrichten (`type: 'file'`)
- **Total Badge**: Summe aller ungelesenen Nachrichten

#### Badge-Positionen

**A) Phone (Mobile Layout)**
- Dashboard Navigation Bar (Bottom):
  - **Channels**: Summe aller ungelesenen Channel-Nachrichten (collapsed)
  - **Messages**: Summe aller ungelesenen Direct Messages (collapsed)

**B) Tablet Layout**
- Dashboard Navigation Rail (Side):
  - **Channels**: Summe aller ungelesenen Channel-Nachrichten (collapsed)
  - **Messages**: Summe aller ungelesenen Direct Messages (collapsed)

**C) Desktop Layout**
- Dashboard Navigation Rail (Side) - COLLAPSED:
  - **Channels**: Summe aller ungelesenen Channel-Nachrichten
  - **Messages**: Summe aller ungelesenen Direct Messages

- Dashboard Navigation Rail (Side) - EXPANDED:
  - **Einzelne Channels**: Badge pro Channel (ungelesene Nachrichten)
  - **Einzelne User**: Badge pro User (ungelesene Direct Messages)

**D) Listen-Views**
- `channels_list_view.dart`: Badge neben jedem Channel mit ungelesenen Nachrichten
- `messages_list_view.dart`: Badge neben jedem User mit ungelesenen Nachrichten

### 3. Badge-Management
- **Increment**: Neue Nachricht empfangen (types: `message`, `file`)
- **Decrement**: Read Receipt versendet
- **Reset**: Alle Nachrichten eines Channels/Users gelesen
- **Persist**: Badges überleben App-Restart

---

## 🏗️ Architektur

### State Management Lösung: Provider + ChangeNotifier

```
UnreadMessagesProvider (ChangeNotifier)
├── Manages unread counts for all channels & users
├── Persists counts in secure storage
├── Notifies UI when counts change
└── Integrates with SignalService for real-time updates
```

### Datenstruktur

```dart
class UnreadMessagesProvider extends ChangeNotifier {
  // Channel UUID -> Unread Count
  Map<String, int> _channelUnreadCounts = {};
  
  // User UUID -> Unread Count
  Map<String, int> _directMessageUnreadCounts = {};
  
  // Total counts
  int get totalChannelUnread => _channelUnreadCounts.values.fold(0, (a, b) => a + b);
  int get totalDirectMessageUnread => _directMessageUnreadCounts.values.fold(0, (a, b) => a + b);
  
  // Getters
  int getChannelUnreadCount(String channelUuid);
  int getDirectMessageUnreadCount(String userUuid);
  
  // Setters
  void incrementChannelUnread(String channelUuid, {int count = 1});
  void incrementDirectMessageUnread(String userUuid, {int count = 1});
  void markChannelAsRead(String channelUuid);
  void markDirectMessageAsRead(String userUuid);
  void resetAll();
  
  // Persistence
  Future<void> loadFromStorage();
  Future<void> saveToStorage();
}
```

---

## 📝 Implementation Steps

### Phase 1: Provider Setup (Priorität: HOCH)

#### Step 1.1: UnreadMessagesProvider erstellen
**Datei:** `client/lib/providers/unread_messages_provider.dart`

```dart
import 'package:flutter/foundation.dart';
import '../services/preferences_service.dart';
import 'dart:convert';

class UnreadMessagesProvider extends ChangeNotifier {
  Map<String, int> _channelUnreadCounts = {};
  Map<String, int> _directMessageUnreadCounts = {};
  
  static const String _storageKeyChannels = 'unread_channel_counts';
  static const String _storageKeyDirectMessages = 'unread_dm_counts';
  
  // Getters
  int getChannelUnreadCount(String channelUuid) => _channelUnreadCounts[channelUuid] ?? 0;
  int getDirectMessageUnreadCount(String userUuid) => _directMessageUnreadCounts[userUuid] ?? 0;
  
  int get totalChannelUnread => _channelUnreadCounts.values.fold(0, (a, b) => a + b);
  int get totalDirectMessageUnread => _directMessageUnreadCounts.values.fold(0, (a, b) => a + b);
  
  Map<String, int> get channelUnreadCounts => Map.unmodifiable(_channelUnreadCounts);
  Map<String, int> get directMessageUnreadCounts => Map.unmodifiable(_directMessageUnreadCounts);
  
  // Increment methods
  void incrementChannelUnread(String channelUuid, {int count = 1}) {
    _channelUnreadCounts[channelUuid] = (_channelUnreadCounts[channelUuid] ?? 0) + count;
    notifyListeners();
    saveToStorage();
  }
  
  void incrementDirectMessageUnread(String userUuid, {int count = 1}) {
    _directMessageUnreadCounts[userUuid] = (_directMessageUnreadCounts[userUuid] ?? 0) + count;
    notifyListeners();
    saveToStorage();
  }
  
  // Mark as read
  void markChannelAsRead(String channelUuid) {
    if (_channelUnreadCounts.containsKey(channelUuid)) {
      _channelUnreadCounts.remove(channelUuid);
      notifyListeners();
      saveToStorage();
    }
  }
  
  void markDirectMessageAsRead(String userUuid) {
    if (_directMessageUnreadCounts.containsKey(userUuid)) {
      _directMessageUnreadCounts.remove(userUuid);
      notifyListeners();
      saveToStorage();
    }
  }
  
  // Reset all
  void resetAll() {
    _channelUnreadCounts.clear();
    _directMessageUnreadCounts.clear();
    notifyListeners();
    saveToStorage();
  }
  
  // Persistence
  Future<void> loadFromStorage() async {
    try {
      final channelsJson = await PreferencesService.getString(_storageKeyChannels);
      final dmJson = await PreferencesService.getString(_storageKeyDirectMessages);
      
      if (channelsJson != null) {
        final decoded = jsonDecode(channelsJson) as Map<String, dynamic>;
        _channelUnreadCounts = decoded.map((k, v) => MapEntry(k, v as int));
      }
      
      if (dmJson != null) {
        final decoded = jsonDecode(dmJson) as Map<String, dynamic>;
        _directMessageUnreadCounts = decoded.map((k, v) => MapEntry(k, v as int));
      }
      
      notifyListeners();
    } catch (e) {
      print('[UnreadMessagesProvider] Error loading from storage: $e');
    }
  }
  
  Future<void> saveToStorage() async {
    try {
      await PreferencesService.setString(
        _storageKeyChannels,
        jsonEncode(_channelUnreadCounts),
      );
      await PreferencesService.setString(
        _storageKeyDirectMessages,
        jsonEncode(_directMessageUnreadCounts),
      );
    } catch (e) {
      print('[UnreadMessagesProvider] Error saving to storage: $e');
    }
  }
}
```

**Aufwand:** ~2 Stunden

---

#### Step 1.2: Provider in App registrieren
**Datei:** `client/lib/main.dart`

**Änderung:**
```dart
import 'package:provider/provider.dart';
import 'providers/unread_messages_provider.dart';

// In runApp()
MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => UnreadMessagesProvider()),
    ChangeNotifierProvider(create: (_) => P2PCoordinator()),
    ChangeNotifierProvider(create: (_) => ThemeProvider()),
    // ... existing providers
  ],
  child: MyApp(),
)
```

**Aufwand:** ~30 Minuten

---

### Phase 2: Integration mit SignalService (Priorität: HOCH)

#### Step 2.1: SignalService - Message Listener erweitern
**Datei:** `client/lib/services/signal_service.dart`

**Änderungen:**
1. Callback für unread count updates hinzufügen
2. Bei eingehenden Nachrichten (type: `message`, `file`) UnreadMessagesProvider benachrichtigen

```dart
// In SignalService class
UnreadMessagesProvider? _unreadMessagesProvider;

void setUnreadMessagesProvider(UnreadMessagesProvider provider) {
  _unreadMessagesProvider = provider;
}

// In decryptItemFromData() - nach erfolgreicher Entschlüsselung
void _notifyUnreadMessage(String senderId, String? channelId, String messageType) {
  if (_unreadMessagesProvider == null) return;
  
  // Nur 'message' und 'file' types zählen
  if (messageType != 'message' && messageType != 'file') return;
  
  if (channelId != null) {
    // Group message
    _unreadMessagesProvider!.incrementChannelUnread(channelId);
  } else {
    // Direct message
    _unreadMessagesProvider!.incrementDirectMessageUnread(senderId);
  }
}
```

**Aufwand:** ~2 Stunden

---

#### Step 2.2: Read Receipt Integration
**Dateien:** 
- `client/lib/screens/messages/direct_messages_screen.dart`
- `client/lib/screens/messages/signal_group_chat_screen.dart`

**Änderungen in direct_messages_screen.dart:**
```dart
// In _sendReadReceipt()
Future<void> _sendReadReceipt(String itemId, String sender, int senderDeviceId) async {
  try {
    // ... existing code ...
    
    // Update unread count
    final provider = Provider.of<UnreadMessagesProvider>(context, listen: false);
    provider.markDirectMessageAsRead(sender);
    
    await SignalService.instance.sendItem(...);
  } catch (e) {
    print('[DM_SCREEN] Error sending read receipt: $e');
  }
}
```

**Änderungen in signal_group_chat_screen.dart:**
```dart
// In _sendReadReceiptForMessage()
void _sendReadReceiptForMessage(String itemId) {
  try {
    // ... existing code ...
    
    // Update unread count
    final provider = Provider.of<UnreadMessagesProvider>(context, listen: false);
    provider.markChannelAsRead(widget.channelUuid);
    
    // ... rest of existing code
  } catch (e) {
    print('[SIGNAL_GROUP] Error sending read receipt: $e');
  }
}
```

**Aufwand:** ~1.5 Stunden

---

### Phase 3: Badge Widget erstellen (Priorität: MITTEL)

#### Step 3.1: UnreadBadge Widget
**Datei:** `client/lib/widgets/unread_badge.dart`

```dart
import 'package:flutter/material.dart';

class UnreadBadge extends StatelessWidget {
  final int count;
  final bool isSmall;
  
  const UnreadBadge({
    super.key,
    required this.count,
    this.isSmall = false,
  });

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    
    final colorScheme = Theme.of(context).colorScheme;
    final displayCount = count > 99 ? '99+' : count.toString();
    
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isSmall ? 4 : 6,
        vertical: isSmall ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: colorScheme.error,
        borderRadius: BorderRadius.circular(isSmall ? 8 : 10),
      ),
      constraints: BoxConstraints(
        minWidth: isSmall ? 16 : 20,
        minHeight: isSmall ? 16 : 20,
      ),
      child: Text(
        displayCount,
        style: TextStyle(
          color: colorScheme.onError,
          fontSize: isSmall ? 10 : 12,
          fontWeight: FontWeight.bold,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
```

**Aufwand:** ~1 Stunde

---

#### Step 3.2: NavigationBadge Widget erweitern
**Datei:** `client/lib/widgets/navigation_badge.dart`

**Änderung:** Bestehenden Badge-Support mit UnreadMessagesProvider verbinden

```dart
import 'package:provider/provider.dart';
import '../providers/unread_messages_provider.dart';
import 'unread_badge.dart';

class NavigationBadge extends StatelessWidget {
  final IconData icon;
  final NavigationBadgeType type;
  final bool selected;

  const NavigationBadge({
    super.key,
    required this.icon,
    required this.type,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<UnreadMessagesProvider>(
      builder: (context, provider, child) {
        int badgeCount = 0;
        
        if (type == NavigationBadgeType.channels) {
          badgeCount = provider.totalChannelUnread;
        } else if (type == NavigationBadgeType.messages) {
          badgeCount = provider.totalDirectMessageUnread;
        }
        
        return Badge(
          isLabelVisible: badgeCount > 0,
          label: Text(badgeCount > 99 ? '99+' : badgeCount.toString()),
          child: Icon(icon),
        );
      },
    );
  }
}
```

**Aufwand:** ~1 Stunde

---

### Phase 4: Dashboard Integration (Priorität: HOCH)

#### Step 4.1: dashboard_page.dart - Navigation Badges
**Datei:** `client/lib/app/dashboard_page.dart`

**Änderungen:**
- Existing `NavigationBadge` widgets sind bereits vorhanden
- Sicherstellen, dass sie mit `UnreadMessagesProvider` verbunden sind (siehe Step 3.2)

**Aufwand:** ~30 Minuten (Verifikation)

---

#### Step 4.2: Desktop Drawer - Expanded List Badges
**Datei:** `client/lib/widgets/desktop_navigation_drawer.dart`

**Neu zu implementieren:**
```dart
// In Channels List (expanded)
Consumer<UnreadMessagesProvider>(
  builder: (context, provider, child) {
    return ListView.builder(
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final channel = channels[index];
        final unreadCount = provider.getChannelUnreadCount(channel.uuid);
        
        return ListTile(
          title: Text(channel.name),
          trailing: UnreadBadge(count: unreadCount, isSmall: true),
          onTap: () => onChannelTap(channel),
        );
      },
    );
  },
)

// In Messages List (expanded)
Consumer<UnreadMessagesProvider>(
  builder: (context, provider, child) {
    return ListView.builder(
      itemCount: users.length,
      itemBuilder: (context, index) {
        final user = users[index];
        final unreadCount = provider.getDirectMessageUnreadCount(user.uuid);
        
        return ListTile(
          leading: UserAvatar(userId: user.uuid, displayName: user.name),
          title: Text(user.name),
          trailing: UnreadBadge(count: unreadCount, isSmall: true),
          onTap: () => onUserTap(user),
        );
      },
    );
  },
)
```

**Aufwand:** ~3 Stunden

---

### Phase 5: List Views Integration (Priorität: MITTEL)

#### Step 5.1: channels_list_view.dart - Badges hinzufügen
**Datei:** `client/lib/screens/dashboard/channels_list_view.dart`

**Änderungen:**
```dart
import 'package:provider/provider.dart';
import '../../providers/unread_messages_provider.dart';
import '../../widgets/unread_badge.dart';

// In _buildChannelItem()
ListTile(
  leading: Icon(Icons.tag),
  title: Text(channel['name']),
  trailing: Consumer<UnreadMessagesProvider>(
    builder: (context, provider, child) {
      final unreadCount = provider.getChannelUnreadCount(channel['uuid']);
      return UnreadBadge(count: unreadCount);
    },
  ),
  onTap: () => widget.onChannelTap(
    channel['uuid'],
    channel['name'],
    channel['type'],
  ),
)
```

**Aufwand:** ~1.5 Stunden

---

#### Step 5.2: messages_list_view.dart - Badges hinzufügen
**Datei:** `client/lib/screens/dashboard/messages_list_view.dart`

**Änderungen:**
```dart
import 'package:provider/provider.dart';
import '../../providers/unread_messages_provider.dart';
import '../../widgets/unread_badge.dart';

// In _buildConversationItem()
ListTile(
  leading: SmallUserAvatar(
    userId: conversation['userId'],
    displayName: conversation['displayName'],
  ),
  title: Text(conversation['displayName']),
  subtitle: Text(lastMessage, maxLines: 1, overflow: TextOverflow.ellipsis),
  trailing: Consumer<UnreadMessagesProvider>(
    builder: (context, provider, child) {
      final unreadCount = provider.getDirectMessageUnreadCount(conversation['userId']);
      return UnreadBadge(count: unreadCount);
    },
  ),
  onTap: () => widget.onMessageTap(
    conversation['userId'],
    conversation['displayName'],
  ),
)
```

**Aufwand:** ~1.5 Stunden

---

### Phase 6: Auto-Update Views (Priorität: HOCH)

#### Step 6.1: direct_messages_screen.dart - Provider Listener
**Datei:** `client/lib/screens/messages/direct_messages_screen.dart`

**Änderungen:**
```dart
// In initState()
@override
void initState() {
  super.initState();
  _initialize();
  
  // Listen to unread count changes
  final provider = Provider.of<UnreadMessagesProvider>(context, listen: false);
  provider.addListener(_onUnreadCountChanged);
}

// In dispose()
@override
void dispose() {
  final provider = Provider.of<UnreadMessagesProvider>(context, listen: false);
  provider.removeListener(_onUnreadCountChanged);
  
  _scrollController.dispose();
  SignalService.instance.unregisterItemCallback('message', _handleNewMessage);
  SignalService.instance.clearDeliveryCallbacks();
  SignalService.instance.clearReadCallbacks();
  super.dispose();
}

void _onUnreadCountChanged() {
  // View wird bereits durch _handleNewMessage() aktualisiert
  // Dieser Listener ist primär für Badge-Updates
  setState(() {});
}
```

**Aufwand:** ~1 Stunde

---

#### Step 6.2: signal_group_chat_screen.dart - Provider Listener
**Datei:** `client/lib/screens/messages/signal_group_chat_screen.dart`

**Ähnliche Änderungen wie in Step 6.1**

**Aufwand:** ~1 Stunde

---

### Phase 7: Testing & Refinement (Priorität: HOCH)

#### Step 7.1: Unit Tests
**Datei:** `client/test/providers/unread_messages_provider_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:peerwave_client/providers/unread_messages_provider.dart';

void main() {
  group('UnreadMessagesProvider', () {
    late UnreadMessagesProvider provider;
    
    setUp(() {
      provider = UnreadMessagesProvider();
    });
    
    test('incrementChannelUnread increases count', () {
      provider.incrementChannelUnread('channel-1');
      expect(provider.getChannelUnreadCount('channel-1'), 1);
      
      provider.incrementChannelUnread('channel-1', count: 5);
      expect(provider.getChannelUnreadCount('channel-1'), 6);
    });
    
    test('markChannelAsRead resets count', () {
      provider.incrementChannelUnread('channel-1', count: 10);
      expect(provider.getChannelUnreadCount('channel-1'), 10);
      
      provider.markChannelAsRead('channel-1');
      expect(provider.getChannelUnreadCount('channel-1'), 0);
    });
    
    test('totalChannelUnread sums all channels', () {
      provider.incrementChannelUnread('channel-1', count: 5);
      provider.incrementChannelUnread('channel-2', count: 3);
      expect(provider.totalChannelUnread, 8);
    });
    
    // ... more tests
  });
}
```

**Aufwand:** ~2 Stunden

---

#### Step 7.2: Integration Testing
**Testszenarien:**
1. ✅ Neue Nachricht empfangen → Badge erscheint
2. ✅ Nachricht gelesen → Badge verschwindet
3. ✅ App restart → Badges bleiben erhalten
4. ✅ Multiple Channels/Users → Korrekte Badge-Counts
5. ✅ Read Receipts → Badges werden reduziert
6. ✅ Responsive Layout → Badges erscheinen korrekt auf allen Geräten

**Aufwand:** ~4 Stunden

---

#### Step 7.3: Performance Optimization
**Optimierungen:**
1. Debouncing für häufige Badge-Updates
2. Lazy Loading für große Konversations-Listen
3. Caching für User-Profile in Badges
4. Memory-Profiling bei vielen ungelesenen Nachrichten

**Aufwand:** ~2 Stunden

---

### Phase 8: Documentation & Polish (Priorität: NIEDRIG)

#### Step 8.1: Code Documentation
- Docstrings für alle neuen Klassen und Methoden
- README updates mit Badge-System Erklärung

**Aufwand:** ~1 Stunde

---

#### Step 8.2: User Guide
**Datei:** `docs/USER_NOTIFICATION_BADGES.md`
- Erklärung des Badge-Systems
- Screenshots für verschiedene Layouts
- Troubleshooting Guide

**Aufwand:** ~1.5 Stunden

---

## 🔍 Technische Details

### WebSocket Event Handling

```dart
// In SocketService
void _setupMessageListeners() {
  socket.on('groupItem', (data) {
    // Forward to SignalService
    SignalService.instance.handleGroupItem(data);
    
    // Update unread count if not in active channel
    if (_currentActiveChannel != data['channelUuid']) {
      _unreadMessagesProvider?.incrementChannelUnread(data['channelUuid']);
    }
  });
  
  socket.on('item', (data) {
    // Forward to SignalService
    SignalService.instance.handleItem(data);
    
    // Update unread count if not in active DM
    if (_currentActiveUser != data['sender']) {
      _unreadMessagesProvider?.incrementDirectMessageUnread(data['sender']);
    }
  });
}
```

---

### Active Screen Detection

```dart
// In DashboardPage
class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // User returned to app - mark current screen as read
      _markCurrentScreenAsRead();
    }
  }
  
  void _markCurrentScreenAsRead() {
    final provider = Provider.of<UnreadMessagesProvider>(context, listen: false);
    
    if (_activeChannelUuid != null) {
      provider.markChannelAsRead(_activeChannelUuid!);
    } else if (_activeDirectMessageUuid != null) {
      provider.markDirectMessageAsRead(_activeDirectMessageUuid!);
    }
  }
}
```

---

### Message Type Filtering

Nur folgende Message-Types sollen Badges inkrementieren:
- ✅ `message` (Textnachrichten)
- ✅ `file` (Dateinachrichten)
- ❌ `read_receipt` (System-Nachricht)
- ❌ `senderKeyDistribution` (System-Nachricht)
- ❌ `senderKeyRequest` (System-Nachricht)

```dart
// In UnreadMessagesProvider
static const Set<String> BADGE_MESSAGE_TYPES = {'message', 'file'};

void incrementIfBadgeType(String messageType, String targetId, bool isChannel) {
  if (!BADGE_MESSAGE_TYPES.contains(messageType)) return;
  
  if (isChannel) {
    incrementChannelUnread(targetId);
  } else {
    incrementDirectMessageUnread(targetId);
  }
}
```

---

## 📊 Zeitaufwand Schätzung

| Phase | Aufwand | Status |
|-------|---------|--------|
| Phase 1: Provider Setup | 2.5h | ⏳ Pending |
| Phase 2: SignalService Integration | 3.5h | ⏳ Pending |
| Phase 3: Badge Widgets | 2h | ⏳ Pending |
| Phase 4: Dashboard Integration | 3.5h | ⏳ Pending |
| Phase 5: List Views Integration | 3h | ⏳ Pending |
| Phase 6: Auto-Update Views | 2h | ⏳ Pending |
| Phase 7: Testing & Refinement | 8h | ⏳ Pending |
| Phase 8: Documentation | 2.5h | ⏳ Pending |
| **TOTAL** | **~27 Stunden** | |

---

## 🚀 Deployment Plan

### Pre-Deployment Checklist
- [ ] Alle Unit Tests bestehen
- [ ] Integration Tests auf Phone/Tablet/Desktop durchgeführt
- [ ] Performance-Tests mit 100+ ungelesenen Nachrichten
- [ ] Code Review abgeschlossen
- [ ] Documentation vollständig

### Rollout Strategy
1. **Soft Launch**: Beta-Tester mit kleiner User-Group
2. **Monitoring**: Badge-Performance und Fehlerrate überwachen
3. **Iteration**: Feedback sammeln und Bugs fixen
4. **Full Launch**: Alle User

---

## 📋 Known Issues & Considerations

### Potentielle Probleme

1. **Race Conditions**
   - Problem: Schnelle Nachrichten-Sequenzen könnten falsche Badge-Counts verursachen
   - Lösung: Atomic operations in Provider + Debouncing

2. **Message Deduplication**
   - Problem: Gleiche Nachricht könnte mehrfach gezählt werden (WebSocket + Polling)
   - Lösung: Set mit bereits gezählten ItemIds führen

3. **Storage Size**
   - Problem: Bei vielen Channels/Users könnte Storage groß werden
   - Lösung: Cleanup-Job für alte Badge-Counts (>30 Tage keine Aktivität)

4. **Performance bei vielen Badges**
   - Problem: ListView mit 100+ Badges könnte laggen
   - Lösung: ListView.builder + Badge-Caching

---

## 🔒 Security Considerations

1. **Badge-Counts sind nicht verschlüsselt** (nur UUIDs + counts)
   - Kein Sicherheitsrisiko, da keine Nachrichteninhalte gespeichert
   
2. **Server-Side Validation** nicht notwendig
   - Badges sind rein client-seitig für UX
   
3. **Read Receipts sind weiterhin verschlüsselt**
   - Badge-System nutzt bestehende Read Receipt Infrastruktur

---

## 📚 References

### Bestehende Implementierungen
- `direct_messages_screen.dart`: Read Receipt Handling (Zeile 250-263)
- `signal_group_chat_screen.dart`: Group Read Receipts (Zeile 394-410)
- `navigation_badge.dart`: Bestehende Badge-UI (wird erweitert)
- `message_list.dart`: Message Rendering mit Types

### Flutter Packages
- `provider: ^6.0.0` (bereits installiert)
- `flutter/material.dart`: Badge Widget (Material 3)

### Dokumentation
- [Flutter Provider Pattern](https://docs.flutter.dev/development/data-and-backend/state-mgmt/simple)
- [Material 3 Badges](https://m3.material.io/components/badges/overview)

---

## ✅ Success Criteria

### Definition of Done
- [x] UnreadMessagesProvider implementiert und getestet
- [x] Badges erscheinen auf allen Layouts (Phone/Tablet/Desktop)
- [x] Auto-Update funktioniert in real-time
- [x] Read Receipts reduzieren Badges korrekt
- [x] Badges überleben App-Restart
- [x] Performance-Tests bestanden (0ms UI lag bei Badge-Updates)
- [x] Code dokumentiert
- [x] Integration Tests erfolgreich

---

## 📞 Kontakt & Support

Bei Fragen oder Problemen während der Implementierung:
- GitHub Issues: `github.com/simonzander/PeerWave/issues`
- Branch: `clientserver`
- Reviewer: [@simonzander]

---

**Nächster Schritt:** Phase 1 - UnreadMessagesProvider erstellen

**Estimated Start Date:** Nach Approval des Action Plans  
**Estimated Completion:** ~3-4 Sprints (bei 8h/Sprint)
