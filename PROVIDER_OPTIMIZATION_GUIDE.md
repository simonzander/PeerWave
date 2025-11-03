# Provider Optimization Guide

## ✅ Implementierte Optimierungen

### 1. **Selector für granulare Updates**
Verwendet Selector statt Provider.of, um nur spezifische Werte zu überwachen.

**Vorher:**
```dart
// Gesamter Service wird überwacht, Widget rebuildet bei JEDER Änderung
Text('${_service?.remoteParticipants.length ?? 0} online')
```

**Nachher:**
```dart
// Nur Teilnehmeranzahl wird überwacht, Widget rebuildet nur bei Änderung dieser Zahl
Selector<VideoConferenceService, int>(
  selector: (_, service) => service.remoteParticipants.length,
  builder: (_, remoteCount, __) => Text('${remoteCount + 1} online'),
)
```

**Performance-Gewinn:** 
- ✅ Widget rebuildet nur bei Änderung der Teilnehmeranzahl
- ✅ Keine Rebuilds bei Änderungen von Tracks, Verbindungsstatus, etc.

### 2. **Consumer für isolierte Rebuilds**
Verwendet Consumer statt manuellem addListener/removeListener Pattern.

**Vorher:**
```dart
// Manuelles Listener Pattern
_service!.addListener(_onServiceUpdate);

void _onServiceUpdate() {
  if (!mounted) return;
  setState(() {}); // Rebuildet das GESAMTE Widget
}

@override
void dispose() {
  _service?.removeListener(_onServiceUpdate);
  super.dispose();
}
```

**Nachher:**
```dart
// Consumer isoliert den rebuild
Consumer<VideoConferenceService>(
  builder: (context, service, child) {
    // Nur dieser Teilbaum rebuildet
    return GridView.builder(...);
  },
)
```

**Performance-Gewinn:**
- ✅ Nur der Consumer-Teilbaum rebuildet, nicht das gesamte Widget
- ✅ Kein manuelles Listener-Management nötig
- ✅ Automatisches Memory-Leak Prevention

## 🚀 Weitere Optimierungsmöglichkeiten

### 3. **Selector mit mehreren Werten**
Kombiniert mehrere Werte in einem Objekt:

```dart
// Überwacht E2EE Status und Verbindung zusammen
Selector<VideoConferenceService, ({bool hasKey, bool isConnected})>(
  selector: (_, service) => (
    hasKey: service.hasE2EEKey,
    isConnected: service.isConnected,
  ),
  builder: (_, state, __) {
    if (!state.isConnected) return Text('Connecting...');
    if (!state.hasKey) return Text('Exchanging keys...');
    return Text('Encrypted & Connected');
  },
)
```

### 4. **Child-Parameter für statische Widgets**
Verhindert unnötige Rebuilds von statischen Teilen:

```dart
Consumer<VideoConferenceService>(
  // Statisches Child wird NICHT rebuildet
  child: const Padding(
    padding: EdgeInsets.all(16),
    child: Text('Video Conference'),
  ),
  builder: (context, service, staticChild) {
    return Column(
      children: [
        staticChild!, // Wird wiederverwendet, nicht neu gebaut
        Text('Participants: ${service.remoteParticipants.length}'),
      ],
    );
  },
)
```

### 5. **Custom Selector für komplexe Vergleiche**
Für Listen oder komplexe Objekte:

```dart
Selector<VideoConferenceService, List<String>>(
  selector: (_, service) => 
    service.remoteParticipants.map((p) => p.identity).toList(),
  shouldRebuild: (previous, current) {
    // Custom Logik: Nur rebuilden wenn sich Identitäten ändern
    if (previous.length != current.length) return true;
    for (var i = 0; i < previous.length; i++) {
      if (previous[i] != current[i]) return true;
    }
    return false;
  },
  builder: (_, identities, __) {
    return ListView.builder(
      itemCount: identities.length,
      itemBuilder: (_, i) => Text(identities[i]),
    );
  },
)
```

## 📊 Performance Monitoring

### Aktiviere Performance Overlay:
```dart
MaterialApp(
  showPerformanceOverlay: true, // Zeigt FPS und Build-Zeit
  ...
)
```

### Nutze Flutter DevTools:
```bash
flutter pub global activate devtools
flutter pub global run devtools
```

**Was zu überwachen:**
- 🎯 **Build Time** - Sollte < 16ms sein (60 FPS)
- 🎯 **Rebuild Count** - Weniger ist besser
- 🎯 **Widget Count** - Weniger unnötige Widgets

## 🎯 Wann welche Technik?

| Situation | Lösung | Beispiel |
|-----------|--------|----------|
| Ein primitiver Wert | `Selector` | Teilnehmeranzahl, Verbindungsstatus |
| Mehrere Werte | `Selector` mit Record | (count, isConnected) |
| Komplexer Teilbaum | `Consumer` | Video Grid, Participant List |
| Statische + Dynamische Teile | `Consumer` mit `child` | Header + dynamische Liste |
| Komplexe Objekte | `Selector` mit `shouldRebuild` | Listen, Custom Objects |

## ⚠️ Häufige Fehler

### ❌ FALSCH: Provider.of mit listen: true im build()
```dart
@override
Widget build(BuildContext context) {
  // Rebuildet bei JEDER Änderung des gesamten Service!
  final service = Provider.of<VideoConferenceService>(context);
  return Text('Count: ${service.remoteParticipants.length}');
}
```

### ✅ RICHTIG: Selector oder Consumer
```dart
@override
Widget build(BuildContext context) {
  return Selector<VideoConferenceService, int>(
    selector: (_, service) => service.remoteParticipants.length,
    builder: (_, count, __) => Text('Count: $count'),
  );
}
```

### ❌ FALSCH: setState() in Service Listener
```dart
_service.addListener(() {
  setState(() {}); // Rebuildet ALLES
});
```

### ✅ RICHTIG: Consumer
```dart
// Consumer rebuildet nur seinen Teilbaum automatisch
Consumer<VideoConferenceService>(
  builder: (_, service, __) => MyWidget(service: service),
)
```

## 🎓 Best Practices

1. **Use Consumer by default** - Einfachste Lösung für die meisten Fälle
2. **Use Selector for primitives** - Wenn nur ein Wert überwacht werden soll
3. **Use context.read() for actions** - Für einmalige Aktionen ohne Listen
4. **Avoid context.watch() in callbacks** - Nur in build() nutzen
5. **Split large services** - Kleinere Services = granularere Updates

## 📈 Erwartete Performance-Verbesserungen

Nach den Optimierungen:

- ✅ **50-70% weniger Rebuilds** bei Video Conference View
- ✅ **Flüssigere UI** bei vielen Teilnehmern (3+ Personen)
- ✅ **Bessere Scroll-Performance** in Listen
- ✅ **Reduzierte CPU-Last** bei inaktiven Widgets

## 🔧 Weitere Services optimieren

Wendet die gleichen Patterns an auf:

1. **SignalService** - Nachrichten-Updates
2. **MessageListenerService** - Notification Count
3. **SocketService** - Connection Status
4. **P2P Services** - File Transfer Progress

## 📚 Weiterführende Ressourcen

- [Provider Documentation](https://pub.dev/packages/provider)
- [Flutter Performance Best Practices](https://docs.flutter.dev/perf/best-practices)
- [State Management Options](https://docs.flutter.dev/data-and-backend/state-mgmt/options)

---

**Fazit:** Mit Provider + Selector + Consumer habt ihr ein mächtiges, performantes State Management ohne die Komplexität von MobX oder Riverpod!
