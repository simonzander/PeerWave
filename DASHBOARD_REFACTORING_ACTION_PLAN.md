# Dashboard Refactoring Action Plan

## Problemanalyse

### Aktuelle Situation
- `dashboard_page.dart` ist eine zentrale, monolithische Datei mit ~1100 Zeilen
- Keine separaten Routen für Menüpunkte (Activities, Channels, Messages, People, Files)
- Views sind direkt in `_buildContent()` eingebettet
- Datenmanagement (channels, messages, people) ist in Dashboard zentralisiert
- Keine klare Trennung zwischen Navigation und View-Logik

### Zielarchitektur
```
DashboardPage (Navigation Shell)
  ├─ Route: /app/activities    → ActivitiesView (Context Panel + Main)
  ├─ Route: /app/channels       → ChannelsView (Context Panel + Main)
  ├─ Route: /app/messages       → MessagesView (Context Panel + Main)
  ├─ Route: /app/people         → PeopleView (Context Panel + Main)
  └─ Route: /app/files          → FilesView (Context Panel + Main)
```

---

## Phase 1: Analyse & Vorbereitung

### Step 1.1: View-Struktur definieren
**Ziel**: Einheitliche Basis-Klasse für alle Views

**Erstelle**: `lib/app/views/base_view.dart`
```dart
abstract class BaseView extends StatefulWidget {
  final String host;
  
  const BaseView({Key? key, required this.host}) : super(key: key);
}

abstract class BaseViewState<T extends BaseView> extends State<T> {
  // Gemeinsame Funktionalität
  bool _isLoading = false;
  String? _error;
  
  // Context Panel Konfiguration
  bool get shouldShowContextPanel => true;
  ContextPanelType get contextPanelType;
  Widget buildContextPanel();
  Widget buildMainContent();
  
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (shouldShowContextPanel) buildContextPanel(),
        Expanded(child: buildMainContent()),
      ],
    );
  }
}
```

**Dateien**:
- ✅ `lib/app/views/base_view.dart` - Basis-Klasse
- ✅ `lib/app/views/view_config.dart` - Gemeinsame Konfiguration

---

## Phase 2: View Extraction

### Step 2.1: Activities View auslagern
**Ziel**: Activities als eigenständige View mit eigenem State Management

**Erstelle**: `lib/app/views/activities_view_page.dart`
```dart
class ActivitiesViewPage extends BaseView {
  @override
  State<ActivitiesViewPage> createState() => _ActivitiesViewPageState();
}

class _ActivitiesViewPageState extends BaseViewState<ActivitiesViewPage> {
  @override
  ContextPanelType get contextPanelType => ContextPanelType.none;
  
  @override
  bool get shouldShowContextPanel => false; // Keine Context Panel für Activities
  
  @override
  Widget buildMainContent() {
    return ActivitiesView(
      host: widget.host,
      onDirectMessageTap: _handleDirectMessageTap,
      onChannelTap: _handleChannelTap,
    );
  }
  
  void _handleDirectMessageTap(String uuid, String displayName) {
    // Navigation zu Messages mit Konversation
    context.go('/app/messages/$uuid', extra: {'displayName': displayName});
  }
  
  void _handleChannelTap(String uuid, String name, String type) {
    // Navigation zu Channels mit Channel
    context.go('/app/channels/$uuid', extra: {'name': name, 'type': type});
  }
}
```

**Änderungen**:
- ✅ Erstelle `lib/app/views/activities_view_page.dart`
- ✅ Entferne Activities-Logik aus `dashboard_page.dart`
- ✅ Navigation über `context.go()` statt setState()

---

### Step 2.2: Messages View auslagern
**Ziel**: Messages als eigenständige View mit Context Panel + Main Content

**Erstelle**: `lib/app/views/messages_view_page.dart`
```dart
class MessagesViewPage extends BaseView {
  final String? conversationId; // Optional: Direkt zu Konversation springen
  
  const MessagesViewPage({
    Key? key,
    required String host,
    this.conversationId,
  }) : super(key: key, host: host);
  
  @override
  State<MessagesViewPage> createState() => _MessagesViewPageState();
}

class _MessagesViewPageState extends BaseViewState<MessagesViewPage> {
  String? _activeConversationId;
  String? _activeConversationDisplayName;
  
  // Context Panel State
  List<Map<String, dynamic>> _recentPeople = [];
  bool _isLoadingRecentPeople = false;
  int _recentPeopleLimit = 10;
  bool _hasMoreRecentPeople = true;
  
  @override
  void initState() {
    super.initState();
    _activeConversationId = widget.conversationId;
    _loadRecentPeople();
    _registerCallbacks();
  }
  
  void _registerCallbacks() {
    // Socket.IO callbacks für neue Nachrichten
    // SignalService callbacks für neue Konversationen
  }
  
  @override
  ContextPanelType get contextPanelType => ContextPanelType.messages;
  
  @override
  Widget buildContextPanel() {
    return PeopleContextPanel(
      host: widget.host,
      recentPeople: _recentPeople,
      onPersonTap: (uuid, displayName) {
        // Navigation innerhalb der View
        setState(() {
          _activeConversationId = uuid;
          _activeConversationDisplayName = displayName;
        });
        // URL Update
        context.go('/app/messages/$uuid');
      },
      isLoading: _isLoadingRecentPeople,
      onLoadMore: _loadMoreRecentPeople,
      hasMore: _hasMoreRecentPeople,
    );
  }
  
  @override
  Widget buildMainContent() {
    if (_activeConversationId == null) {
      return MessagesListView(
        host: widget.host,
        onMessageTap: (uuid, displayName) {
          setState(() {
            _activeConversationId = uuid;
            _activeConversationDisplayName = displayName;
          });
          context.go('/app/messages/$uuid');
        },
        onNavigateToPeople: () => context.go('/app/people'),
      );
    }
    
    return DirectMessagesScreen(
      host: widget.host,
      recipientUuid: _activeConversationId!,
      recipientDisplayName: _activeConversationDisplayName ?? _activeConversationId!,
    );
  }
  
  Future<void> _loadRecentPeople() async {
    // Logic von dashboard_page hierher verschieben
  }
  
  void _loadMoreRecentPeople() {
    // Logic von dashboard_page hierher verschieben
  }
}
```

**Änderungen**:
- ✅ Erstelle `lib/app/views/messages_view_page.dart`
- ✅ Verschiebe `_recentPeople` State Management
- ✅ Verschiebe `_loadRecentPeople()` und `_loadMoreRecentPeople()`
- ✅ Entferne Messages-Logik aus `dashboard_page.dart`

---

### Step 2.3: Channels View auslagern
**Ziel**: Channels als eigenständige View mit Context Panel + Main Content

**Erstelle**: `lib/app/views/channels_view_page.dart`
```dart
class ChannelsViewPage extends BaseView {
  final String? channelId; // Optional: Direkt zu Channel springen
  
  const ChannelsViewPage({
    Key? key,
    required String host,
    this.channelId,
  }) : super(key: key, host: host);
  
  @override
  State<ChannelsViewPage> createState() => _ChannelsViewPageState();
}

class _ChannelsViewPageState extends BaseViewState<ChannelsViewPage> {
  String? _activeChannelId;
  String? _activeChannelName;
  String? _activeChannelType;
  
  // Context Panel State
  List<ChannelInfo> _channels = [];
  bool _isLoadingChannels = false;
  
  // Video Conference State (for WebRTC channels)
  Map<String, dynamic>? _videoConferenceConfig;
  
  @override
  void initState() {
    super.initState();
    _activeChannelId = widget.channelId;
    _loadChannels();
    _registerCallbacks();
  }
  
  void _registerCallbacks() {
    // Socket.IO callbacks für Channel-Updates
  }
  
  @override
  ContextPanelType get contextPanelType => ContextPanelType.channels;
  
  @override
  Widget buildContextPanel() {
    return ChannelsContextPanel(
      host: widget.host,
      channels: _channels,
      onChannelTap: (uuid, name, type) {
        setState(() {
          _activeChannelId = uuid;
          _activeChannelName = name;
          _activeChannelType = type;
          _videoConferenceConfig = null;
        });
        context.go('/app/channels/$uuid');
      },
      onCreateChannel: _loadChannels,
      isLoading: _isLoadingChannels,
    );
  }
  
  @override
  Widget buildMainContent() {
    if (_activeChannelId == null) {
      return ChannelsListView(
        host: widget.host,
        onChannelTap: (uuid, name, type) {
          setState(() {
            _activeChannelId = uuid;
            _activeChannelName = name;
            _activeChannelType = type;
          });
          context.go('/app/channels/$uuid');
        },
        onCreateChannel: _loadChannels,
      );
    }
    
    // Signal Channel
    if (_activeChannelType == 'signal') {
      return SignalGroupChatScreen(
        host: widget.host,
        channelUuid: _activeChannelId!,
        channelName: _activeChannelName!,
      );
    }
    
    // WebRTC Channel
    if (_activeChannelType == 'webrtc') {
      if (_videoConferenceConfig != null) {
        return VideoConferenceView(/* ... */);
      }
      return VideoConferencePreJoinView(/* ... */);
    }
    
    return _EmptyState(message: 'Unknown channel type');
  }
  
  Future<void> _loadChannels() async {
    // Logic von dashboard_page hierher verschieben
  }
}
```

**Änderungen**:
- ✅ Erstelle `lib/app/views/channels_view_page.dart`
- ✅ Erstelle `lib/widgets/channels_context_panel.dart` (analog zu PeopleContextPanel)
- ✅ Verschiebe `_channels` State Management
- ✅ Verschiebe `_loadChannels()`
- ✅ Entferne Channels-Logik aus `dashboard_page.dart`

---

### Step 2.4: People View auslagern
**Ziel**: People als eigenständige View

**Erstelle**: `lib/app/views/people_view_page.dart`
```dart
class PeopleViewPage extends BaseView {
  @override
  State<PeopleViewPage> createState() => _PeopleViewPageState();
}

class _PeopleViewPageState extends BaseViewState<PeopleViewPage> {
  @override
  ContextPanelType get contextPanelType => ContextPanelType.people;
  
  @override
  Widget buildContextPanel() {
    // Optional: Recent contacts
    return PeopleContextPanel(
      host: widget.host,
      recentPeople: [],
      onPersonTap: (uuid, displayName) {
        context.go('/app/messages/$uuid');
      },
    );
  }
  
  @override
  Widget buildMainContent() {
    return PeopleScreen(
      host: widget.host,
      onMessageTap: (uuid, displayName) {
        context.go('/app/messages/$uuid', extra: {'displayName': displayName});
      },
      showRecentSection: true,
    );
  }
}
```

**Änderungen**:
- ✅ Erstelle `lib/app/views/people_view_page.dart`
- ✅ Entferne People-Logik aus `dashboard_page.dart`

---

### Step 2.5: Files View auslagern
**Ziel**: Files als eigenständige View

**Erstelle**: `lib/app/views/files_view_page.dart`
```dart
class FilesViewPage extends BaseView {
  @override
  State<FilesViewPage> createState() => _FilesViewPageState();
}

class _FilesViewPageState extends BaseViewState<FilesViewPage> {
  @override
  bool get shouldShowContextPanel => false; // Keine Context Panel für Files
  
  @override
  ContextPanelType get contextPanelType => ContextPanelType.none;
  
  @override
  Widget buildMainContent() {
    return const FileManagerScreen();
  }
}
```

**Änderungen**:
- ✅ Erstelle `lib/app/views/files_view_page.dart`
- ✅ Entferne Files-Logik aus `dashboard_page.dart`

---

## Phase 3: Routing Refactoring

### Step 3.1: GoRouter Konfiguration erweitern
**Ziel**: Separate Routen für alle Views mit optionalen Parametern

**Ändere**: `lib/main.dart` - GoRouter Konfiguration

```dart
ShellRoute(
  builder: (context, state, child) => DashboardPage(child: child),
  routes: [
    // Activities (Startseite)
    GoRoute(
      path: '/app',
      redirect: (context, state) => '/app/activities',
    ),
    GoRoute(
      path: '/app/activities',
      builder: (context, state) => ActivitiesViewPage(
        host: _getHost(state),
      ),
    ),
    
    // Messages mit optionaler Conversation ID
    GoRoute(
      path: '/app/messages',
      builder: (context, state) => MessagesViewPage(
        host: _getHost(state),
      ),
    ),
    GoRoute(
      path: '/app/messages/:conversationId',
      builder: (context, state) {
        final conversationId = state.pathParameters['conversationId'];
        final extra = state.extra as Map<String, dynamic>?;
        return MessagesViewPage(
          host: _getHost(state),
          conversationId: conversationId,
          conversationDisplayName: extra?['displayName'],
        );
      },
    ),
    
    // Channels mit optionaler Channel ID
    GoRoute(
      path: '/app/channels',
      builder: (context, state) => ChannelsViewPage(
        host: _getHost(state),
      ),
    ),
    GoRoute(
      path: '/app/channels/:channelId',
      builder: (context, state) {
        final channelId = state.pathParameters['channelId'];
        final extra = state.extra as Map<String, dynamic>?;
        return ChannelsViewPage(
          host: _getHost(state),
          channelId: channelId,
          channelName: extra?['name'],
          channelType: extra?['type'],
        );
      },
    ),
    
    // People
    GoRoute(
      path: '/app/people',
      builder: (context, state) => PeopleViewPage(
        host: _getHost(state),
      ),
    ),
    
    // Files
    GoRoute(
      path: '/app/files',
      builder: (context, state) => FilesViewPage(
        host: _getHost(state),
      ),
    ),
    
    // Settings (bestehend)
    ShellRoute(
      builder: (context, state, child) => SettingsSidebar(child: child),
      routes: [/* ... bestehende Settings Routes ... */],
    ),
  ],
),
```

**Helper Funktion**:
```dart
String _getHost(GoRouterState state) {
  final extra = state.extra;
  if (extra is Map) {
    return extra['host'] as String? ?? '';
  }
  return '';
}
```

**Änderungen**:
- ✅ Erweitere `main.dart` mit neuen Routen
- ✅ Füge Helper für Host-Extraktion hinzu
- ✅ Teste Navigation zwischen Views

---

### Step 3.2: DashboardPage vereinfachen
**Ziel**: DashboardPage nur noch als Navigation Shell

**Ändere**: `lib/app/dashboard_page.dart`

```dart
class DashboardPage extends StatefulWidget {
  final Widget child; // View wird von GoRouter bereitgestellt
  
  const DashboardPage({
    Key? key,
    required this.child,
  }) : super(key: key);
  
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int _selectedIndex = 0;
  
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final layoutType = LayoutConfig.getLayoutType(width);
    
    // Update selected index based on current route
    _updateSelectedIndexFromRoute();
    
    if (layoutType == LayoutType.desktop) {
      return Scaffold(
        body: Row(
          children: [
            // Icon Sidebar (60px)
            _buildIconSidebar(),
            
            // Child View (von GoRouter)
            Expanded(child: widget.child),
          ],
        ),
      );
    }
    
    // Mobile & Tablet: AdaptiveScaffold
    return AdaptiveScaffold(
      selectedIndex: _selectedIndex,
      onDestinationSelected: _onNavigationSelected,
      destinations: _getNavigationDestinations(context),
      body: widget.child,
    );
  }
  
  void _updateSelectedIndexFromRoute() {
    final location = GoRouterState.of(context).matchedLocation;
    if (location.startsWith('/app/activities')) {
      _selectedIndex = 0;
    } else if (location.startsWith('/app/people')) {
      _selectedIndex = 1;
    } else if (location.startsWith('/app/files')) {
      _selectedIndex = 2;
    } else if (location.startsWith('/app/channels')) {
      _selectedIndex = 3;
    } else if (location.startsWith('/app/messages')) {
      _selectedIndex = 4;
    }
  }
  
  void _onNavigationSelected(int index) {
    setState(() {
      _selectedIndex = index;
    });
    
    // Navigation via GoRouter
    switch (index) {
      case 0:
        context.go('/app/activities');
        break;
      case 1:
        context.go('/app/people');
        break;
      case 2:
        context.go('/app/files');
        break;
      case 3:
        context.go('/app/channels');
        break;
      case 4:
        context.go('/app/messages');
        break;
    }
  }
  
  Widget _buildIconSidebar() {
    // Bestehende Icon Sidebar Logik
  }
}
```

**Änderungen**:
- ✅ Entferne alle View-spezifischen State Variables
- ✅ Entferne `_buildContent()` Methode
- ✅ Entferne `_loadChannels()`, `_loadRecentPeople()`, etc.
- ✅ Behalte nur Navigation-Logik
- ✅ Reduziere von ~1100 Zeilen auf ~300 Zeilen

---

## Phase 4: Callback System

### Step 4.1: Event Bus für globale Events
**Ziel**: Dezentrale Kommunikation zwischen Views

**Erstelle**: `lib/services/event_bus.dart`
```dart
enum AppEvent {
  newMessage,
  newChannel,
  channelUpdated,
  userStatusChanged,
}

class EventBus {
  static final EventBus _instance = EventBus._internal();
  factory EventBus() => _instance;
  EventBus._internal();
  
  final _controllers = <AppEvent, StreamController<dynamic>>{};
  
  Stream<T> on<T>(AppEvent event) {
    if (!_controllers.containsKey(event)) {
      _controllers[event] = StreamController<T>.broadcast();
    }
    return _controllers[event]!.stream as Stream<T>;
  }
  
  void emit(AppEvent event, [dynamic data]) {
    if (_controllers.containsKey(event)) {
      _controllers[event]!.add(data);
    }
  }
  
  void dispose() {
    for (var controller in _controllers.values) {
      controller.close();
    }
    _controllers.clear();
  }
}
```

**Usage in Views**:
```dart
@override
void initState() {
  super.initState();
  
  // Subscribe to events
  _newMessageSub = EventBus().on<Map<String, dynamic>>(AppEvent.newMessage)
    .listen((message) {
      // Handle new message
      _updateMessageList(message);
    });
}

@override
void dispose() {
  _newMessageSub?.cancel();
  super.dispose();
}
```

**Änderungen**:
- ✅ Erstelle `lib/services/event_bus.dart`
- ✅ Registriere Events in Views
- ✅ Emittiere Events von Services (SignalService, SocketService)

---

### Step 4.2: Socket.IO Callbacks zentralisieren
**Ziel**: Ein Listener pro Event, broadcasted via EventBus

**Ändere**: `lib/services/socket_service.dart`
```dart
class SocketService {
  void _setupEventListeners() {
    _socket?.on('message:new', (data) {
      debugPrint('[SOCKET] New message received');
      EventBus().emit(AppEvent.newMessage, data);
    });
    
    _socket?.on('channel:new', (data) {
      debugPrint('[SOCKET] New channel created');
      EventBus().emit(AppEvent.newChannel, data);
    });
    
    _socket?.on('channel:updated', (data) {
      debugPrint('[SOCKET] Channel updated');
      EventBus().emit(AppEvent.channelUpdated, data);
    });
    
    // ... weitere Events
  }
}
```

**Änderungen**:
- ✅ Zentralisiere Socket.IO Listener in SocketService
- ✅ Emittiere Events via EventBus
- ✅ Views subscriben zu EventBus statt direkt zu Socket

---

## Phase 5: Testing & Migration

### Step 5.1: Schrittweise Migration
**Reihenfolge**:
1. ✅ Activities View (am einfachsten, keine Context Panel)
2. ✅ Files View (keine Context Panel)
3. ✅ People View (einfache Context Panel)
4. ✅ Messages View (komplexe Context Panel + Callbacks)
5. ✅ Channels View (komplexeste, mit Video Conference)

**Pro View**:
- ✅ View-Datei erstellen
- ✅ State Management verschieben
- ✅ Route hinzufügen
- ✅ In DashboardPage auskommentieren
- ✅ Testen
- ✅ Alte Logik entfernen

---

### Step 5.2: Testing Checkliste
Pro View testen:

**Navigation**:
- ✅ Direct navigation via URL (`/app/messages`)
- ✅ Navigation via Sidebar
- ✅ Navigation mit Parameter (`/app/messages/:id`)
- ✅ Browser Back/Forward funktioniert

**State Management**:
- ✅ Context Panel lädt korrekt
- ✅ Main Content lädt korrekt
- ✅ Load More funktioniert
- ✅ Refresh funktioniert

**Callbacks**:
- ✅ Neue Nachrichten erscheinen
- ✅ Status Updates funktionieren
- ✅ Navigation zwischen Views funktioniert

**Responsive**:
- ✅ Desktop Layout (Icon Sidebar + Context Panel + Main)
- ✅ Tablet Layout (Context Panel + Main)
- ✅ Mobile Layout (Full Screen)

---

## Phase 6: Cleanup & Optimization

### Step 6.1: Gemeinsame Komponenten extrahieren
**Erstelle**:
- ✅ `lib/widgets/context_panels/base_context_panel.dart` - Basis für alle Context Panels
- ✅ `lib/widgets/context_panels/people_context_panel.dart` - Für Messages & People
- ✅ `lib/widgets/context_panels/channels_context_panel.dart` - Für Channels
- ✅ `lib/widgets/empty_state.dart` - Wiederverwendbarer Empty State

---

### Step 6.2: Performance Optimierungen
**Optimierungen**:
- ✅ Lazy Loading für Views (nur laden wenn benötigt)
- ✅ Caching für Context Panel Daten
- ✅ Debouncing für Search/Filter
- ✅ Pagination für große Listen
- ✅ Virtual Scrolling für lange Listen

---

## Zusammenfassung

### Vorher (Monolith)
```
dashboard_page.dart (1100 Zeilen)
  ├─ Navigation
  ├─ Activities Logic
  ├─ Messages Logic + State
  ├─ Channels Logic + State
  ├─ People Logic
  ├─ Files Logic
  └─ All Context Panels
```

### Nachher (Modular)
```
dashboard_page.dart (300 Zeilen)
  └─ Navigation Shell

lib/app/views/
  ├─ activities_view_page.dart (150 Zeilen)
  ├─ messages_view_page.dart (250 Zeilen)
  ├─ channels_view_page.dart (300 Zeilen)
  ├─ people_view_page.dart (100 Zeilen)
  └─ files_view_page.dart (80 Zeilen)

lib/services/
  └─ event_bus.dart (100 Zeilen)
```

### Vorteile
✅ **Separation of Concerns**: Jede View ist unabhängig
✅ **Testbarkeit**: Views können einzeln getestet werden
✅ **Navigation**: Deep Linking funktioniert (`/app/messages/uuid`)
✅ **Wartbarkeit**: Kleinere, fokussierte Dateien
✅ **Performance**: Lazy Loading möglich
✅ **Skalierbarkeit**: Neue Views einfach hinzuzufügen

### Schätzung
- **Phase 1-2**: 2-3 Tage (Views extrahieren)
- **Phase 3**: 1 Tag (Routing)
- **Phase 4**: 1 Tag (Event Bus)
- **Phase 5**: 2-3 Tage (Testing & Migration)
- **Phase 6**: 1 Tag (Cleanup)

**Total**: ~7-9 Tage

---

## Nächste Schritte

1. **Review diesen Plan** - Feedback?
2. **Start mit Phase 1.1** - Base View erstellen
3. **Dann Phase 2.1** - Activities View (einfachste Migration)
4. **Iterativ weitermachen** - Eine View nach der anderen

Soll ich mit der Implementierung beginnen?
