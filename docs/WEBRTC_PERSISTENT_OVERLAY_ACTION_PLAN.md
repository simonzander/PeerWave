# WebRTC Persistent Overlay & Navigation - Action Plan

## 📋 Übersicht

**Ziel**: WebRTC-Calls sollen während der Navigation in der App weiterlaufen. Ein Overlay zeigt Video/Screenshare, eine Top Bar zeigt Call-Status.

**Herausforderungen**:
- WebRTC-Session darf nicht unterbrochen werden bei Navigation
- Overlay muss verschiebbar und schließbar sein
- Top Bar zeigt Kanal + Call-Zeit
- Funktioniert auf Web, Desktop, Mobile
- Bei Reload: Automatischer Rejoin

---

## 🏗️ Architektur-Ansatz

### Option 1: **Global Provider + Overlay Widget** (EMPFOHLEN ✅)

```
┌─────────────────────────────────────────┐
│          App Root (MaterialApp)         │
│  ┌────────────────────────────────────┐ │
│  │  ChangeNotifierProvider<           │ │
│  │    VideoConferenceService>         │ │
│  │  ┌──────────────────────────────┐ │ │
│  │  │  Stack                       │ │ │
│  │  │  ├─ GoRouter (Pages)         │ │ │
│  │  │  ├─ CallTopBar (global)      │ │ │
│  │  │  └─ CallOverlay (draggable)  │ │ │
│  │  └──────────────────────────────┘ │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

**Vorteile**:
- ✅ WebRTC-Service bleibt aktiv während Navigation
- ✅ Overlay persistent über allen Seiten
- ✅ Funktioniert auf allen Plattformen (Web, Desktop, Mobile)
- ✅ State wird global gehalten

**Nachteile**:
- ⚠️ Bei Browser-Reload gehen Connections verloren (benötigt Rejoin-Logic)

---

## 📐 Komponenten-Design

### 1. **CallTopBar** - Globale Status-Leiste

**Position**: Top der App (über AppBar der Pages)  
**Sichtbar**: Nur wenn aktiver Call  
**Inhalt**:
- Channel-Name
- Call-Duration (z.B. "00:06")
- Participant-Count
- Overlay öffnen/schließen Button
- Leave-Call Button

```dart
class CallTopBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<VideoConferenceService>(
      builder: (context, service, _) {
        if (!service.isInCall) return SizedBox.shrink();
        
        return Container(
          height: 56,
          color: Colors.green.shade700,
          child: Row(
            children: [
              // Channel name
              Text(service.channelName),
              // Call duration (live timer)
              CallDurationTimer(startTime: service.callStartTime),
              // Participant count
              Text('${service.participants.length} online'),
              Spacer(),
              // Toggle overlay button
              IconButton(
                icon: Icon(Icons.videocam),
                onPressed: () => service.toggleOverlayVisible(),
              ),
              // Leave button
              IconButton(
                icon: Icon(Icons.call_end),
                onPressed: () => service.leaveCall(),
              ),
            ],
          ),
        );
      },
    );
  }
}
```

---

### 2. **CallOverlay** - Verschiebbares Video-Fenster

**Position**: Draggable, Standard: Bottom-Right  
**Größe**: 320x180px (16:9) - skalierbar  
**Inhalt**:
- Video-Grid (kompakte Ansicht)
- Minimize/Maximize Button
- Close Button (versteckt Overlay, Call läuft weiter)

```dart
class CallOverlay extends StatefulWidget {
  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  Offset position = Offset(100, 100); // Draggable position
  bool isMinimized = false;
  
  @override
  Widget build(BuildContext context) {
    return Consumer<VideoConferenceService>(
      builder: (context, service, _) {
        if (!service.isInCall || !service.isOverlayVisible) {
          return SizedBox.shrink();
        }
        
        return Positioned(
          left: position.dx,
          top: position.dy,
          child: Draggable(
            feedback: _buildOverlayContent(service),
            child: _buildOverlayContent(service),
            onDragEnd: (details) {
              setState(() {
                position = details.offset;
              });
            },
          ),
        );
      },
    );
  }
  
  Widget _buildOverlayContent(VideoConferenceService service) {
    return Container(
      width: isMinimized ? 240 : 320,
      height: isMinimized ? 135 : 180,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Stack(
        children: [
          // Video Grid (compact)
          _buildCompactVideoGrid(service),
          
          // Controls overlay
          Positioned(
            top: 4,
            right: 4,
            child: Row(
              children: [
                // Minimize/Maximize
                IconButton(
                  icon: Icon(
                    isMinimized ? Icons.fullscreen : Icons.fullscreen_exit,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () => setState(() => isMinimized = !isMinimized),
                ),
                // Close overlay (call continues)
                IconButton(
                  icon: Icon(Icons.close, color: Colors.white, size: 20),
                  onPressed: () => service.hideOverlay(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

---

### 3. **VideoConferenceService** - Erweiterungen

**Neue Properties**:
```dart
class VideoConferenceService extends ChangeNotifier {
  // Existing
  Room? room;
  List<RemoteParticipant> remoteParticipants = [];
  
  // NEW: Persistent call state
  bool isInCall = false;
  String? channelId;
  String? channelName;
  DateTime? callStartTime;
  
  // NEW: Overlay state
  bool isOverlayVisible = true;
  Offset overlayPosition = Offset(100, 100);
  
  // NEW: Methods
  void toggleOverlayVisible() {
    isOverlayVisible = !isOverlayVisible;
    notifyListeners();
  }
  
  void hideOverlay() {
    isOverlayVisible = false;
    notifyListeners();
  }
  
  void showOverlay() {
    isOverlayVisible = true;
    notifyListeners();
  }
  
  Future<void> leaveCall() async {
    await leaveRoom();
    isInCall = false;
    channelId = null;
    channelName = null;
    callStartTime = null;
    isOverlayVisible = false;
    notifyListeners();
  }
}
```

---

## 🔧 Implementation Schritte

### **Phase 1: Service-Erweiterung**

#### Schritt 1.1: VideoConferenceService erweitern
**Datei**: `client/lib/services/video_conference_service.dart`

- [ ] Property `bool isInCall` hinzufügen
- [ ] Property `String? channelId` hinzufügen
- [ ] Property `String? channelName` hinzufügen
- [ ] Property `DateTime? callStartTime` hinzufügen
- [ ] Property `bool isOverlayVisible` hinzufügen
- [ ] Property `Offset overlayPosition` hinzufügen
- [ ] Method `toggleOverlayVisible()` implementieren
- [ ] Method `hideOverlay()` implementieren
- [ ] Method `showOverlay()` implementieren
- [ ] `joinRoom()` aktualisieren: `isInCall = true`, `callStartTime` setzen
- [ ] `leaveRoom()` aktualisieren: State zurücksetzen

#### Schritt 1.2: Rejoin-Logic bei Reload
**Datei**: `client/lib/services/video_conference_service.dart`

- [ ] Property `bool shouldRejoin` in LocalStorage speichern
- [ ] Property `String? lastChannelId` in LocalStorage speichern
- [ ] Method `checkForRejoin()` implementieren (bei App-Start aufrufen)
- [ ] Wenn `shouldRejoin == true`: Automatisch `joinRoom(lastChannelId)` aufrufen
- [ ] Bei erfolgreichem Join: `shouldRejoin = false` setzen
- [ ] Bei `leaveRoom()`: `shouldRejoin = false` setzen

```dart
Future<void> checkForRejoin() async {
  final prefs = await SharedPreferences.getInstance();
  final shouldRejoin = prefs.getBool('shouldRejoin') ?? false;
  final lastChannelId = prefs.getString('lastChannelId');
  
  if (shouldRejoin && lastChannelId != null) {
    debugPrint('[VideoConference] Auto-rejoin detected for channel: $lastChannelId');
    try {
      await joinRoom(lastChannelId);
      await prefs.setBool('shouldRejoin', false);
    } catch (e) {
      debugPrint('[VideoConference] Auto-rejoin failed: $e');
      await prefs.setBool('shouldRejoin', false);
    }
  }
}
```

---

### **Phase 2: UI-Komponenten erstellen**

#### Schritt 2.1: CallTopBar Widget
**Datei**: `client/lib/widgets/call_top_bar.dart` (NEU)

- [ ] Datei erstellen
- [ ] `Consumer<VideoConferenceService>` verwenden
- [ ] Nur anzeigen wenn `service.isInCall == true`
- [ ] Channel-Name anzeigen
- [ ] Call-Duration mit Timer anzeigen (Format: "MM:SS")
- [ ] Participant-Count anzeigen
- [ ] Toggle-Overlay Button implementieren
- [ ] Leave-Call Button implementieren
- [ ] Style: Grüner Hintergrund (ähnlich WhatsApp Call Bar)

#### Schritt 2.2: CallDurationTimer Widget
**Datei**: `client/lib/widgets/call_duration_timer.dart` (NEU)

- [ ] Datei erstellen
- [ ] `Timer.periodic(Duration(seconds: 1))` für Live-Update
- [ ] Berechne Differenz: `DateTime.now() - callStartTime`
- [ ] Format: "MM:SS" oder "HH:MM:SS" (wenn > 1 Stunde)
- [ ] Auto-dispose Timer

```dart
class CallDurationTimer extends StatefulWidget {
  final DateTime startTime;
  
  const CallDurationTimer({required this.startTime});
  
  @override
  State<CallDurationTimer> createState() => _CallDurationTimerState();
}

class _CallDurationTimerState extends State<CallDurationTimer> {
  late Timer _timer;
  Duration _elapsed = Duration.zero;
  
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(Duration(seconds: 1), (_) {
      setState(() {
        _elapsed = DateTime.now().difference(widget.startTime);
      });
    });
  }
  
  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    final minutes = _elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    
    return Text(
      '$minutes:$seconds',
      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
    );
  }
}
```

#### Schritt 2.3: CallOverlay Widget
**Datei**: `client/lib/widgets/call_overlay.dart` (NEU)

- [ ] Datei erstellen
- [ ] `Consumer<VideoConferenceService>` verwenden
- [ ] Nur anzeigen wenn `service.isInCall && service.isOverlayVisible`
- [ ] `Positioned` + `Draggable` für verschiebbare Position
- [ ] Video-Grid in kompakter Ansicht (max 4 Participants sichtbar)
- [ ] Minimize/Maximize Button (ändert Größe)
- [ ] Close Button (versteckt Overlay, Call läuft weiter)
- [ ] Shadow für bessere Sichtbarkeit
- [ ] Bounds-Checking: Overlay bleibt im sichtbaren Bereich

**Draggable-Logic für Web**:
```dart
// For Web: Use GestureDetector instead of Draggable
GestureDetector(
  onPanUpdate: (details) {
    setState(() {
      position += details.delta;
      
      // Keep in bounds
      final size = MediaQuery.of(context).size;
      position = Offset(
        position.dx.clamp(0, size.width - overlayWidth),
        position.dy.clamp(0, size.height - overlayHeight),
      );
    });
  },
  child: _buildOverlayContent(),
)
```

---

### **Phase 3: App-Integration**

#### Schritt 3.1: main.dart aktualisieren
**Datei**: `client/lib/main.dart`

- [ ] `VideoConferenceService` als Singleton initialisieren
- [ ] In `MultiProvider` einfügen (bereits vorhanden)
- [ ] Bei App-Start: `videoConferenceService.checkForRejoin()` aufrufen

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize services
  final videoConferenceService = VideoConferenceService();
  
  // Check for rejoin (after reload)
  await videoConferenceService.checkForRejoin();
  
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: videoConferenceService),
        // ... other providers
      ],
      child: MyApp(),
    ),
  );
}
```

#### Schritt 3.2: App Root Layout anpassen
**Datei**: `client/lib/main.dart` oder `client/lib/app/app_layout.dart`

- [ ] `MaterialApp.builder` verwenden für globales Overlay
- [ ] `Stack` mit `GoRouter` + `CallTopBar` + `CallOverlay`

```dart
MaterialApp.router(
  routerConfig: _router,
  builder: (context, child) {
    return Stack(
      children: [
        // Main content
        child!,
        
        // Global CallTopBar (fixed at top)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: CallTopBar(),
        ),
        
        // Global CallOverlay (draggable)
        CallOverlay(),
      ],
    );
  },
)
```

#### Schritt 3.3: VideoConferenceView anpassen
**Datei**: `client/lib/views/video_conference_view.dart`

**Änderungen**:
- [ ] AppBar entfernen (wird durch CallTopBar ersetzt)
- [ ] Body: Nur Video-Grid anzeigen
- [ ] Controls: Reduzieren auf Mic/Camera Toggle
- [ ] Leave-Button entfernen (ist in CallTopBar)
- [ ] Bei Navigation weg von View: `service.showOverlay()` aufrufen

**Alternative**: View komplett entfernen, nur noch Overlay verwenden

---

### **Phase 4: Navigation-Integration**

#### Schritt 4.1: Channel-Navigation anpassen
**Datei**: `client/lib/screens/dashboard/channels_list_view.dart`

- [ ] Bei WebRTC-Channel-Click:
  - Nicht mehr zu `/app/channels/:id` navigieren
  - Stattdessen: `videoConferenceService.joinRoom()` aufrufen
  - Overlay automatisch anzeigen
  - User bleibt auf aktueller Seite

```dart
onTap: () async {
  if (type == 'webrtc') {
    // Join call without navigation
    final service = context.read<VideoConferenceService>();
    await service.joinRoom(uuid, channelName: name);
    service.showOverlay();
  } else {
    // Signal channels: Navigate normally
    context.go('/app/channels/$uuid', extra: {...});
  }
}
```

#### Schritt 4.2: Routes anpassen
**Datei**: `client/lib/main.dart`

- [ ] Route `/app/channels/:id` prüfen: Ist User bereits in Call?
- [ ] Wenn ja: Nicht zur VideoConferenceView navigieren
- [ ] Wenn nein: PreJoin-View anzeigen

```dart
GoRoute(
  path: '/app/channels/:id',
  builder: (context, state) {
    final service = context.read<VideoConferenceService>();
    
    // If already in this call, stay on current page
    if (service.isInCall && service.channelId == channelUuid) {
      return PreviousPage(); // or redirect to /app/channels
    }
    
    // Show PreJoin for new calls
    return ChannelsViewPage(...);
  },
)
```

---

### **Phase 5: Platform-spezifische Anpassungen**

#### Schritt 5.1: Web - Picture-in-Picture (Optional)
**Datei**: `client/lib/widgets/call_overlay_web.dart`

- [ ] Nutze `dart:html` für native PiP-API
- [ ] Fallback: Custom Overlay wie oben

```dart
import 'dart:html' as html;

void enablePictureInPicture() {
  final videoElement = html.querySelector('video');
  if (videoElement is html.VideoElement) {
    videoElement.requestPictureInPicture();
  }
}
```

#### Schritt 5.2: Mobile - System PiP (Android/iOS)
**Paket**: `pip_view` oder `floating_overlay`

- [ ] Add dependency: `pip_view: ^0.1.0`
- [ ] Wrap CallOverlay mit PiPView
- [ ] Enable Auto-PiP bei App-Hintergrund

```dart
PiPView(
  builder: (context) => CallOverlay(),
  onPiPClose: () {
    // User closed PiP
    final service = context.read<VideoConferenceService>();
    service.hideOverlay();
  },
)
```

#### Schritt 5.3: Desktop - Always-on-Top Window (Optional)
**Paket**: `window_manager`

- [ ] Add dependency: `window_manager: ^0.3.0`
- [ ] Create separate "Always-on-Top" window for overlay
- [ ] Kommunikation zwischen Main-Window und Overlay-Window

---

## 🔒 Persistence & State Management

### LocalStorage Schema

```json
{
  "shouldRejoin": true,
  "lastChannelId": "98a65a11-56a7-4837-a018-80de1c853253",
  "lastChannelName": "Join Test",
  "callStartTime": "2025-11-13T17:05:00.000Z",
  "overlayPosition": {
    "dx": 100,
    "dy": 100
  },
  "overlayVisible": true,
  "overlayMinimized": false
}
```

### Save-Trigger

- **Bei joinRoom()**: State in LocalStorage speichern
- **Bei leaveRoom()**: State aus LocalStorage löschen
- **Bei Overlay-Move**: Position in LocalStorage speichern (debounced)

---

## 🧪 Testing-Strategie

### Unit Tests
- [ ] `VideoConferenceService.toggleOverlayVisible()`
- [ ] `VideoConferenceService.checkForRejoin()`
- [ ] `CallDurationTimer` - Timer updates correctly

### Widget Tests
- [ ] `CallTopBar` - Shows only when in call
- [ ] `CallTopBar` - Leave button works
- [ ] `CallOverlay` - Draggable within bounds
- [ ] `CallOverlay` - Close button hides overlay

### Integration Tests
- [ ] Join call → Navigate to different page → Overlay still visible
- [ ] Join call → Close overlay → Open from TopBar → Overlay reappears
- [ ] Join call → Reload page → Auto-rejoin works
- [ ] Leave call → TopBar and Overlay disappear

---

## 📱 Platform-Matrix

| Feature | Web | Android | iOS | Windows | macOS | Linux |
|---------|-----|---------|-----|---------|-------|-------|
| Global Overlay | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Draggable | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| TopBar | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Rejoin after Reload | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Native PiP | ⚠️ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Always-on-Top | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |

---

## 🚀 Rollout-Plan

### Sprint 1: Foundation (3-5 Tage)
- [ ] Phase 1: Service-Erweiterung
- [ ] Phase 2: CallTopBar + CallDurationTimer
- [ ] Testen auf Desktop

### Sprint 2: Overlay & Navigation (3-5 Tage)
- [ ] Phase 2: CallOverlay (draggable)
- [ ] Phase 3: App-Integration
- [ ] Phase 4: Navigation-Integration
- [ ] Testen auf Web

### Sprint 3: Persistence & Polish (2-3 Tage)
- [ ] Rejoin-Logic
- [ ] LocalStorage-Persistence
- [ ] Bounds-Checking
- [ ] Testen auf Mobile

### Sprint 4: Platform-Optimierung (Optional, 2-3 Tage)
- [ ] Native PiP (Mobile)
- [ ] Always-on-Top (Desktop)
- [ ] Performance-Optimierung

---

## 🎯 Erfolgs-Kriterien

1. ✅ User kann WebRTC-Call starten und zu anderen Seiten navigieren
2. ✅ Overlay bleibt sichtbar und ist verschiebbar
3. ✅ TopBar zeigt Call-Status live an
4. ✅ Bei Reload: Automatischer Rejoin
5. ✅ Overlay kann geschlossen und wieder geöffnet werden
6. ✅ Leave-Button beendet Call von überall

---

## 🔧 Alternative Ansätze

### Alternative 1: Separate Window (Desktop only)
- Neues Fenster für Video-Call
- Immer im Vordergrund
- ❌ Nicht für Web/Mobile geeignet

### Alternative 2: Split-Screen Layout
- App teilt sich in Navigation + Video
- ❌ Weniger flexibel
- ❌ Mehr Screen Real Estate

### Alternative 3: Native PiP überall
- Nutzt System-PiP wenn verfügbar
- Fallback auf Custom Overlay
- ✅ Beste User Experience
- ⚠️ Komplex in der Implementierung

---

## 📚 Dependencies

```yaml
dependencies:
  # Existing
  livekit_client: ^2.0.0
  provider: ^6.0.0
  go_router: ^13.0.0
  shared_preferences: ^2.2.0
  
  # NEW (Optional)
  pip_view: ^0.1.0              # Mobile PiP
  window_manager: ^0.3.0        # Desktop always-on-top
  flutter_localizations:        # Already included
    sdk: flutter
```

---

## 💡 Zusätzliche Features (Nice-to-have)

1. **Minimize to Icon**: Overlay wird zu kleinem Icon-Button (nur Avatar)
2. **Hover to Expand**: Icon expandiert bei Hover zu vollem Overlay
3. **Snap-to-Grid**: Overlay rastet an Bildschirmkanten ein
4. **Multi-Call Support**: Mehrere Calls parallel (Tabs im Overlay)
5. **Notification Badge**: Ungelesene Chat-Nachrichten während Call
6. **Screen Sharing Indicator**: Zeigt an, wer gerade Screen teilt
7. **Recording Indicator**: Zeigt an, wenn Call aufgezeichnet wird

---

## 🐛 Bekannte Herausforderungen & Lösungen

### Problem 1: WebRTC Connection bei Reload verloren
**Lösung**: LocalStorage + Auto-Rejoin Logic

### Problem 2: Overlay überdeckt wichtige UI-Elemente
**Lösung**: Snap-to-Edges, Always stay in bounds, Semi-transparent bei Drag

### Problem 3: Multiple Instances bei Multi-Tab (Web)
**Lösung**: BroadcastChannel API für Tab-Synchronisation

```dart
import 'dart:html' as html;

void setupTabSync() {
  final channel = html.BroadcastChannel('webrtc_call_state');
  
  channel.onMessage.listen((event) {
    final data = event.data as Map<String, dynamic>;
    if (data['type'] == 'call_started') {
      // Another tab started call, disable join in this tab
    }
  });
  
  // Broadcast when joining
  channel.postMessage({
    'type': 'call_started',
    'channelId': channelId,
  });
}
```

### Problem 4: Performance bei vielen Participants
**Lösung**: Overlay zeigt max 4 Participants, Rest als Count

---

## 📊 Metriken & Monitoring

**Zu tracken**:
- Anzahl Rejoins nach Reload
- Durchschnittliche Overlay-Position
- Häufigkeit von Overlay-Close/Open
- Call-Dauer während Navigation
- Abbruchrate bei Navigation

---

## ✅ Checkliste für Go-Live

- [ ] Alle 4 Phasen implementiert
- [ ] Unit Tests: 80%+ Coverage
- [ ] Widget Tests: Alle kritischen Pfade
- [ ] Integration Tests: Haupt-Szenarien
- [ ] Manuelle Tests auf Web, Desktop, Mobile
- [ ] Performance-Tests (10+ Participants)
- [ ] Accessibility-Tests (Screen Reader, Keyboard Navigation)
- [ ] Documentation aktualisiert
- [ ] User-Guide erstellt (How to use Overlay)

---

**Geschätzte Implementierungszeit**: 10-15 Tage  
**Empfohlener Start**: Phase 1 + 2 (Foundation + TopBar)  
**MVP**: Global Overlay + TopBar + Rejoin-Logic
