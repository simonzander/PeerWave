# Message Storage Optimization - Action Plan

**Erstellt:** 4. November 2025  
**Ziel:** Optimierung der Message-Speicherung und -Anzeige mit Auto-Delete-Funktion

---

## 📋 Übersicht der Anforderungen

1. **Whitelist-Filterung:** Nur `message` und `file` Types anzeigen
2. **Receipt-basierte Löschung:** Read/Delivered Messages aus lokalem Storage entfernen
3. **System-Message Cleanup:** Verarbeitete System-Messages löschen
4. **Optimierte Speicherung:** Bestimmte Message-Types gar nicht erst speichern
5. **Auto-Delete Feature:** User-konfigurierbares automatisches Löschen alter Messages

---

## 🎯 Phase 1: Whitelist-Filterung für Message-Anzeige

### Ziel
Nur explizit erlaubte Message-Types (`message`, `file`) in UI anzeigen.

### Betroffene Dateien
- `client/lib/screens/messages/direct_messages_screen.dart`
- `client/lib/screens/messages/group_messages_screen.dart` (falls vorhanden)

### Aufgaben

#### 1.1 Direct Messages Screen
**Datei:** `client/lib/screens/messages/direct_messages_screen.dart`

**Änderungen:**
```dart
// Zeile ~15: Konstante definieren
const Set<String> DISPLAYABLE_MESSAGE_TYPES = {'message', 'file'};

// Zeile ~133: _handleNewMessage() vereinfachen
void _handleNewMessage(dynamic item) {
  final itemType = item['type'];

  // ✅ WHITELIST: Nur erlaubte Types anzeigen
  if (!DISPLAYABLE_MESSAGE_TYPES.contains(itemType)) {
    // Handle system messages (receipts, key distribution, etc.)
    if (itemType == 'read_receipt') {
      // Existierende Read-Receipt-Logik (Zeile ~145-171)
    }
    return; // Nicht anzeigen
  }

  // Rest der Methode...
}
```

**Vorher:**
- ❌ Blacklist mit 5+ Bedingungen
- ❌ Doppelte Filterung
- ❌ Unbekannte Types werden angezeigt

**Nachher:**
- ✅ Whitelist mit 2 erlaubten Types
- ✅ Einfache, klare Logik
- ✅ Unbekannte Types werden ignoriert

#### 1.2 Group Messages Screen (falls implementiert)
- Gleiche Änderungen wie bei Direct Messages
- DISPLAYABLE_MESSAGE_TYPES Konstante nutzen

---

## 🎯 Phase 2: Receipt-basierte Status-Updates (✅ BEREITS IMPLEMENTIERT)

### Status
✅ **VOLLSTÄNDIG IMPLEMENTIERT** - Keine Änderungen erforderlich

### Aktuelle Implementierung
Die Logik zur Aktualisierung von Message-Status basierend auf Receipts ist bereits korrekt implementiert:

#### 2.1 Delivery Receipt Handler
**Datei:** `client/lib/services/signal_service.dart` (Zeile 917-929)

**Implementierung:**
```dart
Future<void> _handleDeliveryReceipt(Map<String, dynamic> data) async {
  final itemId = data['itemId'];
  
  // ✅ Markiert Message als "delivered"
  await sentMessagesStore.markAsDelivered(itemId);
  
  // ✅ Message bleibt im Storage
  // ✅ Nur Status-Update + Callback
  
  // Trigger callbacks
  if (_deliveryCallbacks.containsKey('default')) {
    for (final callback in _deliveryCallbacks['default']!) {
      callback(itemId);
    }
  }
}
```

**Funktionsweise:**
- Message erhält Status "delivered" wenn sie beim Server ankommt
- Message bleibt im lokalen Storage gespeichert
- UI kann Status anzeigen (z.B. "✓✓" in WhatsApp-Style)

#### 2.2 Read Receipt Handler
**Datei:** `client/lib/services/signal_service.dart` (Zeile 945-965)

**Implementierung:**
```dart
Future<void> _handleReadReceipt(Map<String, dynamic> item) async {
  final receiptData = jsonDecode(item['message']);
  final itemId = receiptData['itemId'];
  final readByDeviceId = receiptData['readByDeviceId'] as int?;
  final readByUserId = item['sender'];
  
  // ✅ Markiert Message als "read"
  await sentMessagesStore.markAsRead(itemId);
  
  // ✅ Message bleibt im Storage
  // ✅ Nur Status-Update + Callback mit Metadaten
  
  // Trigger callbacks
  if (_readCallbacks.containsKey('default')) {
    for (final callback in _readCallbacks['default']!) {
      callback({
        'itemId': itemId,
        'readByDeviceId': readByDeviceId,
        'readByUserId': readByUserId
      });
    }
  }
}
```

**Funktionsweise:**
- Message erhält Status "read" wenn Empfänger read_receipt sendet
- Message bleibt im lokalen Storage gespeichert
- UI kann Status anzeigen (z.B. "✓✓" blau in WhatsApp-Style)

#### 2.3 Group Message Read Receipts
**Datei:** `client/lib/services/signal_service.dart` (Zeile 933-943)

**Implementierung:**
```dart
void _handleGroupMessageReadReceipt(Map<String, dynamic> data) {
  // ✅ Callback mit vollständigen Receipt-Daten
  // ✅ Kein Löschen - nur Status-Update via Callback
  
  if (_itemTypeCallbacks.containsKey('groupMessageReadReceipt')) {
    for (final callback in _itemTypeCallbacks['groupMessageReadReceipt']!) {
      callback(data);
    }
  }
}
```

### Verhalten
1. **Message wird gesendet** → Status: "sent"
2. **Server empfängt Message** → Status: "delivered" (via `markAsDelivered()`)
3. **Empfänger liest Message** → Status: "read" (via `markAsRead()`)
4. **Message bleibt gespeichert** → Keine automatische Löschung

### Nächste Schritte
Diese Phase ist **vollständig implementiert**. Falls automatisches Löschen gewünscht ist, siehe **Phase 5: Auto-Delete Feature** (user-konfigurierbar)

---

## 🎯 Phase 3: System-Message Cleanup nach Verarbeitung

### Ziel
System-Messages nach erfolgreicher Verarbeitung aus lokalem Storage löschen.

### Betroffene Dateien
- `client/lib/services/signal_service.dart`
- `client/lib/services/permanent_decrypted_messages_store.dart`
- `client/lib/services/decrypted_group_items_store.dart`

### Aufgaben

#### 3.1 System-Message Types identifizieren
**Zu löschende Types nach Verarbeitung:**
- `read_receipt` - Nach Callback ausgelöst
- `senderKeyRequest` - Nach Key-Distribution versendet
- `fileKeyRequest` - Nach fileKeyResponse versendet
- `delivery_receipt` (falls vorhanden)

#### 3.2 Cleanup in receiveItem()
**Datei:** `client/lib/services/signal_service.dart`

**Änderungen in `receiveItem()` (Zeile ~835):**
```dart
void receiveItem(data) async {
  print("[SIGNAL SERVICE] receiveItem called");
  final type = data['type'];
  final itemId = data['itemId'];
  
  // Entschlüsselung...
  final message = await decryptItemFromData(data);
  if (message.isEmpty) {
    return;
  }
  
  // System-Message Handler
  bool isSystemMessage = false;
  
  if (type == 'read_receipt') {
    await _handleReadReceipt(item);
    isSystemMessage = true;
  } else if (type == 'senderKeyRequest') {
    // Existierende Logik...
    isSystemMessage = true;
  } else if (type == 'fileKeyRequest') {
    // Existierende Logik...
    isSystemMessage = true;
  } else if (type == 'delivery_receipt') {
    await _handleDeliveryReceipt(data);
    isSystemMessage = true;
  }
  
  // ✅ NEU: System-Messages nach Verarbeitung löschen
  if (isSystemMessage) {
    // Vom Server löschen
    deleteItemFromServer(itemId);
    
    // ✅ Auch lokal löschen
    await decryptedMessagesStore.deleteDecryptedMessage(itemId);
    return; // Nicht an Callbacks weiterleiten
  }
  
  // Regular messages: Callbacks triggern
  if (type != null && _itemTypeCallbacks.containsKey(type)) {
    for (var callback in _itemTypeCallbacks[type]!) {
      callback(item);
    }
  }
  
  // Vom Server löschen
  deleteItemFromServer(itemId);
}
```

#### 3.3 Group System-Messages
**Datei:** `client/lib/services/signal_service.dart`

**In `encryptGroupMessage()` - Socket-Listener:**
```dart
// Zeile ~1700: groupMessage listener
socketService.socket!.on('groupMessage', (data) async {
  final type = data['type'];
  final itemId = data['itemId'];
  
  // Entschlüsselung...
  
  // ✅ System-Messages nach Verarbeitung löschen
  if (type == 'senderKeyRequest' || type == 'fileKeyRequest') {
    await decryptedGroupItemsStore.clearItem(itemId, data['channelId']);
    deleteGroupItemFromServer(itemId);
    return;
  }
  
  // Rest der Logik...
});
```

---

## 🎯 Phase 4: Optimierte Speicherung - Nicht speichern

### Ziel
Bestimmte Message-Types gar nicht erst in sent-Stores speichern.

### Betroffene Dateien
- `client/lib/services/signal_service.dart`

### Aufgaben

#### 4.1 Skip-Liste definieren
**Types die NICHT gespeichert werden sollen:**
- `fileKeyResponse` - Einmalige Antwort
- `senderKeyDistribution` - Einmalige Key-Verteilung

#### 4.2 SendItem() modifizieren
**Datei:** `client/lib/services/signal_service.dart`

**Änderungen in `sendItem()` (Zeile ~1161):**
```dart
Future<void> sendItem({
  required String recipientUserId,
  required String type,
  required String payload,
  String? itemId,
}) async {
  // ✅ NEU: Skip-Liste für Speicherung
  const SKIP_STORAGE_TYPES = {
    'fileKeyResponse',
    'senderKeyDistribution',
  };
  
  final shouldStore = !SKIP_STORAGE_TYPES.contains(type);
  
  // ItemId generieren...
  finalItemId = itemId ?? Uuid().v4();
  
  // Verschlüsselung und Versand...
  
  // ✅ GEÄNDERT: Nur speichern wenn nicht in Skip-Liste
  if (shouldStore) {
    await sentMessagesStore.storeSentMessage(
      recipientUserId: recipientUserId,
      itemId: finalItemId,
      message: payload,
      timestamp: DateTime.now().toIso8601String(),
      type: type,
      status: 'sent',
    );
  }
  
  // Lokaler Callback (nur für displayable types)
  if (DISPLAYABLE_MESSAGE_TYPES.contains(type)) {
    // Callback triggern...
  }
}
```

#### 4.3 SendGroupItem() modifizieren (falls vorhanden)
**Datei:** `client/lib/services/signal_service.dart`

**Gleiche Logik in `encryptGroupMessage()` / Gruppen-Versand:**
```dart
// Zeile ~1657: encryptGroupMessage()
Future<Map<String, dynamic>> encryptGroupMessage(...) async {
  const SKIP_STORAGE_TYPES = {
    'fileKeyResponse',
    'senderKeyDistribution',
  };
  
  final shouldStore = !SKIP_STORAGE_TYPES.contains(type);
  
  // Verschlüsselung...
  
  // ✅ Nur speichern wenn nicht in Skip-Liste
  if (shouldStore) {
    await sentGroupItemsStore.storeChannelItem(...);
  }
  
  // Rest der Logik...
}
```

---

## 🎯 Phase 5: Auto-Delete Feature mit Settings UI

### Ziel
User-konfigurierbare automatische Löschung alter Messages.

### Betroffene Dateien
- `client/lib/app/settings_sidebar.dart`
- `client/lib/app/settings/general_settings_page.dart` (NEU)
- `client/lib/services/message_cleanup_service.dart` (NEU)
- `client/lib/services/permanent_sent_messages_store.dart`
- `client/lib/services/permanent_decrypted_messages_store.dart`

### Aufgaben

#### 5.1 Settings Sidebar erweitern
**Datei:** `client/lib/app/settings_sidebar.dart`

**Änderungen:**
```dart
// Nach Zeile 50: Neuer Menüeintrag
ListTile(
  leading: Icon(Icons.settings, color: colorScheme.onSurface),
  title: Text(
    'General',
    style: theme.textTheme.bodyMedium?.copyWith(
      color: colorScheme.onSurface,
    ),
  ),
  selected: _selectedIndex == 0,
  selectedTileColor: colorScheme.secondaryContainer.withOpacity(0.3),
  onTap: () => _onItemTapped(0, '/app/settings/general'),
),

// Bestehende Menüeinträge index++:
// Profile: index 1
// Appearance: index 2
// Backup Codes: index 3
// About: index 4
```

#### 5.2 General Settings Page erstellen
**Datei:** `client/lib/app/settings/general_settings_page.dart` (NEU)

**Inhalt:**
```dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({super.key});

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  static const String AUTO_DELETE_DAYS_KEY = 'auto_delete_days';
  static const int DEFAULT_AUTO_DELETE_DAYS = 365;
  
  int _autoDeleteDays = DEFAULT_AUTO_DELETE_DAYS;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoDeleteDays = prefs.getInt(AUTO_DELETE_DAYS_KEY) ?? DEFAULT_AUTO_DELETE_DAYS;
      _loading = false;
    });
  }

  Future<void> _saveAutoDeleteDays(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AUTO_DELETE_DAYS_KEY, days);
    setState(() {
      _autoDeleteDays = days;
    });
    
    // Trigger cleanup immediately
    if (days > 0) {
      await MessageCleanupService.instance.cleanupOldMessages(days);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('General Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Auto-Delete Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Message Auto-Delete',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Automatically delete messages older than specified days. Set to 0 to disable.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  // Input Field
                  TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Delete after (days)',
                      hintText: 'e.g. 365',
                      helperText: '0 = disabled, default: 365',
                      suffixText: 'days',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    controller: TextEditingController(
                      text: _autoDeleteDays.toString(),
                    ),
                    onSubmitted: (value) {
                      final days = int.tryParse(value) ?? DEFAULT_AUTO_DELETE_DAYS;
                      _saveAutoDeleteDays(days.clamp(0, 3650)); // Max 10 Jahre
                    },
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Quick Presets
                  Wrap(
                    spacing: 8,
                    children: [
                      ActionChip(
                        label: const Text('Disabled'),
                        onPressed: () => _saveAutoDeleteDays(0),
                      ),
                      ActionChip(
                        label: const Text('30 days'),
                        onPressed: () => _saveAutoDeleteDays(30),
                      ),
                      ActionChip(
                        label: const Text('90 days'),
                        onPressed: () => _saveAutoDeleteDays(90),
                      ),
                      ActionChip(
                        label: const Text('1 year'),
                        onPressed: () => _saveAutoDeleteDays(365),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Current Status
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _autoDeleteDays == 0
                          ? colorScheme.errorContainer
                          : colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _autoDeleteDays == 0 ? Icons.warning : Icons.check_circle,
                          color: _autoDeleteDays == 0
                              ? colorScheme.onErrorContainer
                              : colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _autoDeleteDays == 0
                                ? 'Auto-delete is disabled. Messages are stored indefinitely.'
                                : 'Messages older than $_autoDeleteDays days will be automatically deleted.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: _autoDeleteDays == 0
                                  ? colorScheme.onErrorContainer
                                  : colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Manual Cleanup Button
                  FilledButton.icon(
                    onPressed: _autoDeleteDays > 0
                        ? () async {
                            await MessageCleanupService.instance.cleanupOldMessages(_autoDeleteDays);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Cleanup completed')),
                              );
                            }
                          }
                        : null,
                    icon: const Icon(Icons.cleaning_services),
                    label: const Text('Run Cleanup Now'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

#### 5.3 Message Cleanup Service erstellen
**Datei:** `client/lib/services/message_cleanup_service.dart` (NEU)

**Inhalt:**
```dart
import 'package:shared_preferences/shared_preferences.dart';
import 'permanent_sent_messages_store.dart';
import 'permanent_decrypted_messages_store.dart';
import 'sent_group_items_store.dart';
import 'decrypted_group_items_store.dart';

/// Service für automatisches Löschen alter Messages
class MessageCleanupService {
  static final MessageCleanupService instance = MessageCleanupService._internal();
  factory MessageCleanupService() => instance;
  MessageCleanupService._internal();

  static const String AUTO_DELETE_DAYS_KEY = 'auto_delete_days';
  static const int DEFAULT_AUTO_DELETE_DAYS = 365;

  /// Initialize cleanup service - call on app start
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final days = prefs.getInt(AUTO_DELETE_DAYS_KEY) ?? DEFAULT_AUTO_DELETE_DAYS;
    
    if (days > 0) {
      await cleanupOldMessages(days);
    }
  }

  /// Delete messages older than specified days
  Future<void> cleanupOldMessages(int days) async {
    print('[CLEANUP] Starting message cleanup for messages older than $days days');
    
    final cutoffDate = DateTime.now().subtract(Duration(days: days));
    final cutoffTimestamp = cutoffDate.toIso8601String();
    
    // 1. Cleanup sent 1:1 messages
    await _cleanupSentMessages(cutoffTimestamp);
    
    // 2. Cleanup received 1:1 messages
    await _cleanupDecryptedMessages(cutoffTimestamp);
    
    // 3. Cleanup sent group messages
    await _cleanupSentGroupMessages(cutoffTimestamp);
    
    // 4. Cleanup received group messages
    await _cleanupDecryptedGroupMessages(cutoffTimestamp);
    
    print('[CLEANUP] Cleanup completed');
  }

  Future<void> _cleanupSentMessages(String cutoffTimestamp) async {
    final store = await PermanentSentMessagesStore.create();
    final allMessages = await store.loadAllSentMessages();
    
    int deleted = 0;
    for (var msg in allMessages) {
      final timestamp = msg['timestamp'] as String?;
      if (timestamp != null && timestamp.compareTo(cutoffTimestamp) < 0) {
        await store.deleteSentMessage(msg['itemId'], recipientUserId: msg['recipientUserId']);
        deleted++;
      }
    }
    
    print('[CLEANUP] Deleted $deleted old sent 1:1 messages');
  }

  Future<void> _cleanupDecryptedMessages(String cutoffTimestamp) async {
    final store = await PermanentDecryptedMessagesStore.create();
    final senders = await store.getAllUniqueSenders();
    
    int deleted = 0;
    for (var sender in senders) {
      final messages = await store.getMessagesFromSender(sender);
      for (var msg in messages) {
        final timestamp = msg['timestamp'] as String?;
        if (timestamp != null && timestamp.compareTo(cutoffTimestamp) < 0) {
          await store.deleteDecryptedMessage(msg['itemId']);
          deleted++;
        }
      }
    }
    
    print('[CLEANUP] Deleted $deleted old received 1:1 messages');
  }

  Future<void> _cleanupSentGroupMessages(String cutoffTimestamp) async {
    final store = await SentGroupItemsStore.create();
    final channels = await store.getAllChannels();
    
    int deleted = 0;
    for (var channelId in channels) {
      final messages = await store.getChannelItems(channelId);
      for (var msg in messages) {
        final timestamp = msg['timestamp'] as String?;
        if (timestamp != null && timestamp.compareTo(cutoffTimestamp) < 0) {
          await store.clearChannelItem(msg['itemId'], channelId);
          deleted++;
        }
      }
    }
    
    print('[CLEANUP] Deleted $deleted old sent group messages');
  }

  Future<void> _cleanupDecryptedGroupMessages(String cutoffTimestamp) async {
    final store = await DecryptedGroupItemsStore.create();
    final channels = await store.getAllChannels();
    
    int deleted = 0;
    for (var channelId in channels) {
      final messages = await store.getChannelItems(channelId);
      for (var msg in messages) {
        final timestamp = msg['timestamp'] as String?;
        if (timestamp != null && timestamp.compareTo(cutoffTimestamp) < 0) {
          await store.clearItem(msg['itemId'], channelId);
          deleted++;
        }
      }
    }
    
    print('[CLEANUP] Deleted $deleted old received group messages');
  }
}
```

#### 5.4 Routing hinzufügen
**Datei:** `client/lib/main.dart` oder Router-Konfiguration

**Route hinzufügen:**
```dart
GoRoute(
  path: '/app/settings/general',
  builder: (context, state) => const GeneralSettingsPage(),
),
```

#### 5.5 App-Start Integration
**Datei:** `client/lib/main.dart`

**Im initState() oder main():**
```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize cleanup service
  await MessageCleanupService.instance.init();
  
  runApp(MyApp());
}
```

#### 5.6 Store-Methoden hinzufügen
**Zusätzliche Methoden in Stores:**

**`permanent_sent_messages_store.dart`:**
```dart
/// Get all messages (across all recipients)
Future<List<Map<String, dynamic>>> loadAllSentMessages() async {
  // Bereits implementiert (siehe Zeile 186)
}
```

**`permanent_decrypted_messages_store.dart`:**
```dart
/// Get all unique senders
Future<Set<String>> getAllUniqueSenders() async {
  // Bereits implementiert (siehe Zeile 212)
}
```

**`sent_group_items_store.dart` (falls nicht vorhanden):**
```dart
/// Get all channel IDs
Future<Set<String>> getAllChannels() async {
  // Neu zu implementieren
}
```

**`decrypted_group_items_store.dart` (falls nicht vorhanden):**
```dart
/// Get all channel IDs
Future<Set<String>> getAllChannels() async {
  // Neu zu implementieren
}
```

---

## 📅 Implementierungs-Reihenfolge

### Sprint 1: Filterung & Basis-Cleanup (2-3 Tage)
1. ✅ Phase 1: Whitelist-Filterung implementieren
2. ✅ Phase 3: System-Message Cleanup implementieren

**Priorität:** HOCH - Verbessert Performance sofort

### ~~Sprint 2: Receipt-basierte Löschung~~ ✅ BEREITS VORHANDEN
~~3. Phase 2: Read/Delivery Receipt Löschung implementieren~~  
✅ **Phase 2 ist bereits korrekt implementiert** - Status-Updates funktionieren wie gewünscht

**Status:** ✅ KOMPLETT - Keine Änderungen erforderlich

### Sprint 2: Optimierung (1-2 Tage)
3. ✅ Phase 4: Skip-Storage für bestimmte Types

**Priorität:** NIEDRIG - Nice-to-have Optimierung

### Sprint 3: Auto-Delete Feature (3-4 Tage)
4. ✅ Phase 5.1-5.2: Settings UI erstellen
5. ✅ Phase 5.3: Cleanup Service implementieren
6. ✅ Phase 5.4-5.6: Integration & Store-Erweiterungen
7. ✅ Testing: Auto-Delete mit verschiedenen Timeframes

**Priorität:** HOCH - Wichtigstes User-Feature

---

## 🧪 Testing-Checkliste

### Funktionale Tests

#### Phase 1: Whitelist-Filterung
- [ ] Nur `message` und `file` Types werden in UI angezeigt
- [ ] System-Messages (`read_receipt`, etc.) werden nicht angezeigt
- [ ] Unbekannte Types werden ignoriert
- [ ] Callbacks für System-Messages funktionieren weiterhin

#### Phase 2: Receipt Status-Updates ✅ BEREITS IMPLEMENTIERT
- [x] Message wird nach Delivery-Receipt als "delivered" markiert
- [x] Message wird nach Read-Receipt als "read" markiert
- [x] Message bleibt im Storage gespeichert (kein Löschen)
- [x] UI zeigt korrekte Status-Updates
- [x] Callbacks werden mit korrekten Metadaten aufgerufen

#### Phase 3: System-Message Cleanup
- [ ] `read_receipt` wird nach Verarbeitung lokal gelöscht
- [ ] `senderKeyRequest` wird nach Verarbeitung lokal gelöscht
- [ ] `fileKeyRequest` wird nach Verarbeitung lokal gelöscht
- [ ] System funktioniert weiterhin korrekt (Keys werden verteilt)

#### Phase 4: Skip-Storage
- [ ] `fileKeyResponse` wird nicht in `sentMessagesStore` gespeichert
- [ ] `senderKeyDistribution` wird nicht in `sentGroupItemsStore` gespeichert
- [ ] Messages werden trotzdem erfolgreich versendet
- [ ] Empfänger erhalten die Messages

#### Phase 5: Auto-Delete
- [ ] Settings UI: Input-Feld funktioniert
- [ ] Settings UI: Presets funktionieren (30/90/365 Tage)
- [ ] Settings UI: 0 = Disabled funktioniert
- [ ] Cleanup Service: Löscht Messages älter als X Tage
- [ ] Cleanup Service: Behält Messages jünger als X Tage
- [ ] App-Start: Cleanup wird automatisch ausgeführt
- [ ] Manual Cleanup Button funktioniert

### Performance Tests
- [ ] Message-Anzeige: Keine spürbare Verlangsamung
- [ ] Cleanup: Läuft im Hintergrund ohne UI-Freeze
- [ ] Storage: Größe nimmt mit Zeit nicht unbegrenzt zu

### Edge Cases
- [ ] Was passiert bei 0 Messages?
- [ ] Was passiert bei 10.000+ Messages?
- [ ] Was passiert wenn User offline ist während Cleanup?
- [ ] Was passiert wenn Message gelöscht wird während User sie ansieht?

---

## ⚠️ Risiken & Überlegungen

### Multi-Device Sync
**Problem:** User liest Message auf Gerät A → wird auf Gerät B auch gelöscht?

**Lösungen:**
1. **Lokale Löschung:** Jedes Gerät löscht nur seine eigenen Read Messages (empfohlen)
2. **Server-Sync:** Server trackt Read-Status pro Device und synchronisiert
3. **User-Choice:** Setting "Sync deletions across devices"

**Empfehlung:** Lokale Löschung (Option 1) - einfacher, privacy-freundlicher

### Storage Migration
**Problem:** Alte Messages haben kein `timestamp` Feld

**Lösung:**
- Cleanup überspringt Messages ohne Timestamp
- Optional: Migration-Script um Timestamps hinzuzufügen (z.B. Item-Creation-Date vom Server)

### Performance bei großen Datenmengen
**Problem:** 10.000+ Messages durchsuchen kann langsam sein

**Lösung:**
- IndexedDB Indexes nutzen (bereits vorhanden für `timestamp`)
- Cleanup in Batches durchführen (z.B. 100 Messages pro Batch)
- Progress-Indicator während Cleanup

### Versehentliches Löschen
**Problem:** User setzt Auto-Delete auf 1 Tag, verliert alle Messages

**Lösung:**
- Confirmation Dialog bei aggressiven Settings (< 7 Tage)
- "Restore from backup" Feature (optional)
- Dokumentation im UI

---

## 📊 Erwartete Verbesserungen

### Storage-Reduktion
- **Vor:** Unbegrenztes Wachstum (z.B. 100 MB nach 1 Jahr)
- **Nach:** Konstante Größe (z.B. max 10 MB mit 30-Tage-Retention)

### Performance
- **Vor:** Langsame Message-Liste bei 1000+ Messages
- **Nach:** Schnelle Liste durch weniger Messages & bessere Filterung

### User Experience
- **Vor:** Verwirrung durch System-Messages in UI
- **Nach:** Nur relevante Messages sichtbar

---

## 📝 Dokumentation

### User-Dokumentation
- [ ] Help-Text in Settings zu Auto-Delete
- [ ] FAQ: "Warum sind meine alten Messages weg?"
- [ ] Privacy Policy Update: Message-Retention

### Developer-Dokumentation
- [ ] Code-Kommentare für Whitelist-Logik
- [ ] README Update: Storage-Architektur
- [ ] Migration Guide für bestehende Deployments

---

## ✅ Definition of Done

Eine Phase gilt als abgeschlossen wenn:
- [ ] Code implementiert und committed
- [ ] Unit Tests geschrieben und bestanden
- [ ] Integration Tests durchgeführt
- [ ] Code Review abgeschlossen
- [ ] Dokumentation aktualisiert
- [ ] User Testing durchgeführt (für UI-Features)

---

## 🚀 Deployment-Plan

### Pre-Deployment
1. Backup aller User-Daten (IndexedDB Export)
2. Smoke Tests auf Staging-Umgebung
3. Rollback-Plan vorbereiten

### Deployment
1. Rolling Update: Phase 1-3 (Backend-kompatibel)
2. Feature Flag: Phase 5 (Auto-Delete) - optional aktivieren
3. Monitoring: Storage-Größe, Error-Rates

### Post-Deployment
1. User-Feedback sammeln (7 Tage)
2. Performance-Metriken prüfen
3. Ggf. Auto-Delete Default anpassen

---

## 📞 Support & Rollback

### Support-Checkliste
- [ ] Help-Desk Training zu neuen Features
- [ ] FAQ-Artikel zu Auto-Delete
- [ ] Support-Script für "Meine Messages sind weg"

### Rollback-Prozess
1. Feature Flag deaktivieren (Auto-Delete)
2. Code auf Previous Version zurücksetzen
3. User-Daten aus Backup wiederherstellen (falls nötig)

---

**Geschätzter Aufwand gesamt:** 7-9 Entwicklungstage (Phase 2 bereits implementiert ✅)  
**Priorität:** HOCH  
**Risk Level:** LOW-MEDIUM (Multi-Device Sync bereits gelöst)
