# Material 3 Theme & Layout Implementation - Action Plan

**Datum:** 3. November 2025  
**Ziel:** Einheitliches Material 3 Design System mit adaptivem Layout und auswählbaren Color Themes

---

## 📋 PHASE 1: ANALYSE & STRUKTUR (Foundation)

### 1.1 Bestandsaufnahme der aktuellen UI-Struktur
- [x] **Analyse durchgeführt**
  - Gefunden: ~20 Screens mit individuellen Scaffold/AppBar Implementierungen
  - Aktuelles Theme: `ThemeData.dark()` (basic, kein Material 3)
  - Navigation: Keine konsistente Bottom Navigation / Navigation Rail / Drawer
  - AppBar: Meist standard `AppBar` ohne Medium/Large Varianten

**Gefundene Screens:**
```
├── app/
│   ├── dashboard_page.dart           ✅ Scaffold + AppBar
│   ├── profile_page.dart             ✅ Verwendet SnackBar
│   ├── backupcode_web.dart           ✅ Scaffold
│   └── backupcode_settings_page.dart ✅ Scaffold
├── screens/
│   ├── messages/
│   │   ├── signal_group_chat_screen.dart   ✅ Scaffold + AppBar
│   │   └── direct_messages_screen.dart      ✅ Scaffold + AppBar
│   ├── file_transfer/
│   │   ├── file_manager_screen.dart         ✅ Scaffold + AppBar
│   │   ├── file_browser_screen.dart         ✅ Scaffold + AppBar
│   │   ├── file_upload_screen.dart          ✅ Scaffold + AppBar
│   │   ├── downloads_screen.dart            ✅ Scaffold + AppBar
│   │   └── file_transfer_hub.dart           ✅ Scaffold + AppBar
│   ├── channel/
│   │   └── channel_members_screen.dart      ✅ Scaffold + AppBar
│   ├── admin/
│   │   ├── role_management_screen.dart      ❌ Kein Scaffold
│   │   └── user_management_screen.dart      ❌ Kein Scaffold
│   └── signal_setup_screen.dart             ✅ Scaffold
└── views/
    ├── video_conference_view.dart            ✅ Scaffold + AppBar + bottomNavigationBar
    └── video_conference_prejoin_view.dart    ✅ Scaffold + AppBar
```

**Kritische Erkenntnisse:**
- ❌ Kein Material 3 Theme aktiviert (`useMaterial3: false` oder nicht gesetzt)
- ❌ Keine adaptiven Layouts (kein LayoutBuilder für responsive design)
- ❌ Keine Navigation Bar/Rail/Drawer Struktur
- ❌ Inkonsistente AppBar Styles
- ❌ Keine Theme-Persistierung (keine Settings für Color Scheme)

### 1.2 Ordnerstruktur für Theme System erstellen
```
client/lib/
├── theme/
│   ├── app_theme.dart                    # Material 3 ThemeData Generator
│   ├── color_schemes.dart                # Vordefinierte Color Schemes
│   ├── theme_provider.dart               # Provider für Theme-State
│   └── theme_extensions.dart             # Custom Theme Extensions
├── config/
│   └── layout_config.dart                # Breakpoints & Layout Konstanten
├── widgets/
│   ├── adaptive/
│   │   ├── adaptive_scaffold.dart        # Scaffold mit adaptiver Navigation
│   │   ├── adaptive_app_bar.dart         # AppBar (Small/Medium/Large)
│   │   └── adaptive_navigation.dart      # Bottom Bar / Rail / Drawer
│   └── theme/
│       └── theme_selector_dialog.dart    # Dialog für Theme-Auswahl
└── services/
    └── preferences_service.dart          # Speichert Theme-Präferenzen (IndexedDB/SharedPrefs)
```

---

## 📋 PHASE 2: THEME SYSTEM IMPLEMENTATION

### 2.1 Material 3 Theme Generator erstellen
**Datei:** `client/lib/theme/app_theme.dart`

**Tasks:**
- [ ] Material 3 ThemeData mit `useMaterial3: true` aktivieren
- [ ] ColorScheme für Light/Dark Mode definieren
- [ ] Typography (Material 3 Text Styles) konfigurieren
- [ ] Component Themes definieren:
  - [ ] AppBarTheme (Small, Medium, Large)
  - [ ] NavigationBarTheme
  - [ ] NavigationRailTheme
  - [ ] NavigationDrawerTheme
  - [ ] CardTheme (mit elevation + shadows)
  - [ ] ButtonTheme (Filled, Outlined, Text)
  - [ ] InputDecorationTheme
  - [ ] SnackBarTheme
  - [ ] DialogTheme
  - [ ] BottomSheetTheme
- [ ] Shape Schema (Rounded Corners: 12-28dp)
- [ ] Elevation System (0, 1, 2, 3, 4, 6, 8, 12, 16, 24)

**Beispiel-Struktur:**
```dart
class AppTheme {
  static ThemeData light({ColorScheme? colorScheme}) { ... }
  static ThemeData dark({ColorScheme? colorScheme}) { ... }
  
  // Helper methods
  static ColorScheme defaultLightScheme() { ... }
  static ColorScheme defaultDarkScheme() { ... }
}
```

### 2.2 Vordefinierte Color Schemes
**Datei:** `client/lib/theme/color_schemes.dart`

**Tasks:**
- [ ] 5-8 vordefinierte Color Schemes erstellen:
  - [ ] **PeerWave Dark** (Standard - Dark Theme mit Highlight Color RGB(0, 209, 178) - Türkis/Cyan)
  - [ ] **Monochrome Dark** (Dunkel - Graustufen mit weißen Akzenten)
  - [ ] **Monochrome Light** (Hell - Graustufen mit schwarzen Akzenten)
  - [ ] **Oceanic Green** (grün/türkis)
  - [ ] **Sunset Orange** (orange/rot)
  - [ ] **Lavender Purple** (lila/pink)
  - [ ] **Forest Green** (dunkelgrün)
  - [ ] **Cherry Red** (rot/rosa)
  - [ ] **Custom** (später: User kann eigene Farben wählen)

**Struktur:**
```dart
class ColorSchemes {
  static ColorScheme peerwaveDark(Brightness brightness) { ... }
  static ColorScheme monochromeDark(Brightness brightness) { ... }
  static ColorScheme monochromeLight(Brightness brightness) { ... }
  static ColorScheme oceanicGreen(Brightness brightness) { ... }
  // ...
  
  static List<ColorSchemeOption> get all => [...];
}

class ColorSchemeOption {
  final String id;
  final String name;
  final IconData icon;
  final ColorScheme light;
  final ColorScheme dark;
  final Color previewColor; // Für Theme-Vorschau
}
```

**PeerWave Dark Schema Details:**
```dart
// Primary/Highlight Color: RGB(0, 209, 178) = #00D1B2 (Türkis/Cyan)
static ColorScheme peerwaveDark(Brightness brightness) {
  final highlightColor = Color(0xFF00D1B2); // RGB(0, 209, 178)
  
  if (brightness == Brightness.dark) {
    return ColorScheme.dark(
      primary: highlightColor,              // #00D1B2 - Türkis
      onPrimary: Colors.black,              // Schwarzer Text auf Türkis
      secondary: Color(0xFF00FFC8),         // Helleres Türkis für Sekundär
      onSecondary: Colors.black,
      tertiary: Color(0xFF00B8A0),          // Dunkleres Türkis
      background: Color(0xFF121212),        // Fast Schwarz
      onBackground: Colors.white,
      surface: Color(0xFF1E1E1E),           // Dunkelgrau
      onSurface: Colors.white,
      error: Color(0xFFFF5555),             // Rot für Fehler
    );
  } else {
    // Light variant (falls gewünscht)
    return ColorScheme.light(
      primary: highlightColor,
      // ... angepasste Light Colors
    );
  }
}
```

**Monochrome Dark Schema:**
```dart
static ColorScheme monochromeDark(Brightness brightness) {
  return ColorScheme.dark(
    primary: Colors.white,                  // Weiß als Primary
    onPrimary: Colors.black,
    secondary: Color(0xFFE0E0E0),          // Hellgrau
    onSecondary: Colors.black,
    tertiary: Color(0xFFBDBDBD),           // Mittelgrau
    background: Color(0xFF000000),         // Schwarz
    onBackground: Colors.white,
    surface: Color(0xFF1A1A1A),            // Sehr Dunkelgrau
    onSurface: Colors.white,
    surfaceVariant: Color(0xFF2A2A2A),     // Dunkelgrau Variant
    error: Color(0xFFFFFFFF),              // Weiß für Fehler (kontrastreich)
  );
}
```

**Monochrome Light Schema:**
```dart
static ColorScheme monochromeLight(Brightness brightness) {
  return ColorScheme.light(
    primary: Colors.black,                  // Schwarz als Primary
    onPrimary: Colors.white,
    secondary: Color(0xFF424242),          // Dunkelgrau
    onSecondary: Colors.white,
    tertiary: Color(0xFF616161),           // Mittelgrau
    background: Color(0xFFFFFFFF),         // Weiß
    onBackground: Colors.black,
    surface: Color(0xFFF5F5F5),            // Sehr Hellgrau
    onSurface: Colors.black,
    surfaceVariant: Color(0xFFEEEEEE),     // Hellgrau Variant
    error: Color(0xFF000000),              // Schwarz für Fehler (kontrastreich)
  );
}
```

### 2.3 Theme Provider (State Management)
**Datei:** `client/lib/theme/theme_provider.dart`

**Tasks:**
- [ ] ChangeNotifier für Theme State
- [ ] Methoden:
  - [ ] `setThemeMode(ThemeMode mode)` → Light/Dark/System
  - [ ] `setColorScheme(String schemeId)` → Wechselt Color Scheme
  - [ ] `getTheme()` → Gibt aktuelles ThemeData zurück
- [ ] Integration mit PreferencesService für Persistierung
- [ ] Initialisierung mit gespeicherten Präferenzen

**Beispiel:**
```dart
class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  String _colorSchemeId = 'peerwave_dark'; // Standard: PeerWave Dark
  
  ThemeData get lightTheme => AppTheme.light(
    colorScheme: ColorSchemes.byId(_colorSchemeId).light
  );
  
  ThemeData get darkTheme => AppTheme.dark(
    colorScheme: ColorSchemes.byId(_colorSchemeId).dark
  );
  
  void setColorScheme(String id) {
    _colorSchemeId = id;
    _save();
    notifyListeners();
  }
}
```

### 2.4 Preferences Service
**Datei:** `client/lib/services/preferences_service.dart`

**Tasks:**
- [ ] Service für Theme-Persistierung erstellen
- [ ] Web: IndexedDB (idb_browser package)
- [ ] Native: SharedPreferences (shared_preferences package)
- [ ] Methoden:
  - [ ] `saveThemeMode(ThemeMode mode)`
  - [ ] `loadThemeMode() → ThemeMode`
  - [ ] `saveColorScheme(String id)`
  - [ ] `loadColorScheme() → String`

---

## 📋 PHASE 3: ADAPTIVE LAYOUT SYSTEM

### 3.1 Layout Configuration
**Datei:** `client/lib/config/layout_config.dart`

**Tasks:**
- [ ] Breakpoints definieren:
  ```dart
  class LayoutBreakpoints {
    static const double mobile = 600;      // < 600: Smartphone
    static const double tablet = 840;      // 600-840: Tablet (portrait)
    static const double desktop = 1200;    // > 840: Tablet (landscape) / Desktop
  }
  ```
- [ ] Layout Types enum:
  ```dart
  enum LayoutType {
    mobile,    // Bottom Navigation Bar
    tablet,    // Navigation Rail
    desktop,   // Navigation Drawer (permanent)
  }
  ```
- [ ] Helper Methode:
  ```dart
  static LayoutType getLayoutType(double width) {
    if (width < mobile) return LayoutType.mobile;
    if (width < desktop) return LayoutType.tablet;
    return LayoutType.desktop;
  }
  ```

### 3.2 Adaptive Scaffold Widget
**Datei:** `client/lib/widgets/adaptive/adaptive_scaffold.dart`

**Tasks:**
- [ ] `AdaptiveScaffold` Widget erstellen
- [ ] Automatische Navigation-Auswahl basierend auf Screen-Breite:
  - **< 600px:** Bottom Navigation Bar
  - **600-1200px:** Navigation Rail (links)
  - **> 1200px:** Navigation Drawer (permanent, links)
- [ ] Props:
  - `body`: Content Widget
  - `destinations`: List<NavigationDestination>
  - `selectedIndex`: Aktuell ausgewählter Tab
  - `onDestinationSelected`: Callback
  - `appBarTitle`: Optional Widget/String
  - `appBarActions`: Optional List<Widget>
  - `floatingActionButton`: Optional FAB
- [ ] Responsive AppBar:
  - **Mobile:** Small AppBar
  - **Tablet:** Medium AppBar
  - **Desktop:** Large AppBar (mit Extended Header)

**Beispiel-Struktur:**
```dart
class AdaptiveScaffold extends StatelessWidget {
  final Widget body;
  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final Widget? appBarTitle;
  final List<Widget>? appBarActions;
  
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutType = LayoutConfig.getLayoutType(constraints.maxWidth);
        
        switch (layoutType) {
          case LayoutType.mobile:
            return _buildMobileLayout();
          case LayoutType.tablet:
            return _buildTabletLayout();
          case LayoutType.desktop:
            return _buildDesktopLayout();
        }
      },
    );
  }
}
```

### 3.3 Adaptive AppBar Widget
**Datei:** `client/lib/widgets/adaptive/adaptive_app_bar.dart`

**Tasks:**
- [ ] Small AppBar (Mobile)
  - Höhe: 64dp
  - Title: Single line
  - Actions: Icons only
- [ ] Medium AppBar (Tablet)
  - Höhe: 112dp
  - Title: Larger text
  - Subtitle: Optional
- [ ] Large AppBar (Desktop)
  - Höhe: 152dp
  - Title: Extra large
  - Subtitle + Description: Optional
  - Floating Effect (elevation on scroll)

**API:**
```dart
class AdaptiveAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final Widget? subtitle;
  final List<Widget>? actions;
  final AppBarSize size; // small, medium, large
  
  @override
  Size get preferredSize {
    switch (size) {
      case AppBarSize.small: return Size.fromHeight(64);
      case AppBarSize.medium: return Size.fromHeight(112);
      case AppBarSize.large: return Size.fromHeight(152);
    }
  }
}
```

### 3.4 Adaptive Navigation Widget
**Datei:** `client/lib/widgets/adaptive/adaptive_navigation.dart`

**Tasks:**
- [ ] `BottomNavigationWidget` (Mobile)
  - Material 3 NavigationBar
  - 3-5 Destinations
  - Icons + Labels
- [ ] `NavigationRailWidget` (Tablet)
  - Leading: Optional Header/Logo
  - Expanded: false (collapsed by default)
  - Destinations mit Icons + Labels
- [ ] `NavigationDrawerWidget` (Desktop)
  - Permanent drawer
  - Header: Logo + User info
  - Destinations: Full width items
  - Footer: Settings / Logout

---

## 📋 PHASE 4: SCREEN MIGRATION

### 4.1 Core Screens (Priorität HOCH)
**Zu migrieren:**
- [ ] `app/dashboard_page.dart`
  - Haupt-Navigation implementieren
  - AdaptiveScaffold verwenden
  - Material 3 Cards für Content
- [ ] `screens/messages/signal_group_chat_screen.dart`
  - AppBar: Medium/Large
  - Message List: Material 3 Cards
  - Input: Material 3 TextField
- [ ] `screens/messages/direct_messages_screen.dart`
  - Gleiche Behandlung wie Group Chat
- [ ] `app/profile_page.dart`
  - Large AppBar mit Avatar
  - Form Fields: Material 3 Style

### 4.2 File Transfer Screens (Priorität MITTEL)
**Zu migrieren:**
- [ ] `screens/file_transfer/file_manager_screen.dart`
- [ ] `screens/file_transfer/file_browser_screen.dart`
- [ ] `screens/file_transfer/file_upload_screen.dart`
- [ ] `screens/file_transfer/downloads_screen.dart`
- [ ] `screens/file_transfer/file_transfer_hub.dart`

**Gemeinsame Änderungen:**
- Large AppBar für Desktop
- Cards mit elevation für File Items
- FABs für Upload Actions
- Progress Indicators: Material 3 Style

### 4.3 Admin Screens (Priorität NIEDRIG)
**Zu migrieren:**
- [ ] `screens/admin/role_management_screen.dart`
  - Scaffold + AppBar hinzufügen
  - Table → Material 3 DataTable
- [ ] `screens/admin/user_management_screen.dart`
  - Gleiche Behandlung

### 4.4 Video Conference (Priorität NIEDRIG)
**Zu migrieren:**
- [ ] `views/video_conference_view.dart`
  - Fullscreen Mode: Minimal AppBar
  - Controls: Material 3 FABs
- [ ] `views/video_conference_prejoin_view.dart`
  - Large AppBar
  - Preview Card: Material 3 Style

---

## 📋 PHASE 5: THEME SELECTOR UI

### 5.1 Theme Selector Dialog
**Datei:** `client/lib/widgets/theme/theme_selector_dialog.dart`

**Tasks:**
- [ ] Dialog mit Color Scheme Auswahl
- [ ] Grid Layout (2x4 oder 3x3)
- [ ] Jedes Schema zeigt:
  - Preview Colors (primary, secondary, tertiary)
  - Schema Name
  - Selected Indicator (Checkmark)
- [ ] Light/Dark Mode Toggle
- [ ] Preview Modus (zeigt App mit neuem Theme)

**Integration:**
- [ ] Settings Page: "Appearance" Section
- [ ] Button: "Choose Theme"
- [ ] Opens ThemeSelectorDialog

### 5.2 Settings Integration
**Datei:** `app/settings_sidebar.dart` (oder neue Settings Page)

**Tasks:**
- [ ] Appearance Section hinzufügen:
  ```
  Appearance
  ├── Theme Mode
  │   └── [ Light | Dark | System ]
  ├── Color Scheme
  │   └── [Current Scheme Preview] → Opens Dialog
  └── Font Size (optional)
      └── [ Small | Medium | Large ]
  ```

---

## 📋 PHASE 6: TESTING & POLISH

### 6.1 Responsive Testing
**Devices:**
- [ ] Mobile (360x640, 414x896)
- [ ] Tablet Portrait (768x1024)
- [ ] Tablet Landscape (1024x768)
- [ ] Desktop (1920x1080, 2560x1440)

**Test Cases:**
- [ ] Navigation wechselt korrekt (Bottom → Rail → Drawer)
- [ ] AppBar Größe passt sich an
- [ ] Padding/Margins sind konsistent (16dp horizontal)
- [ ] Cards/Shapes haben korrekte Rounded Corners (12-28dp)
- [ ] Alle Screens sind scrollbar bei kleinen Displays

### 6.2 Theme Testing
**Test Cases:**
- [ ] Light/Dark Mode Wechsel funktioniert
- [ ] Alle Color Schemes funktionieren:
  - [ ] PeerWave Dark (Standard mit Highlight #00D1B2)
  - [ ] Monochrome Dark
  - [ ] Monochrome Light
  - [ ] Oceanic Green
  - [ ] Sunset Orange
  - [ ] Lavender Purple
  - [ ] Forest Green
  - [ ] Cherry Red
- [ ] Theme wird persistiert (nach Reload)
- [ ] Alle Widgets verwenden Theme Colors (keine hardcoded colors)
- [ ] Kontrast ist ausreichend (WCAG AA Standard)

### 6.3 Performance Testing
**Metriken:**
- [ ] Theme Wechsel < 100ms
- [ ] Layout Rebuild < 16ms (60fps)
- [ ] IndexedDB Load < 50ms
- [ ] Keine Memory Leaks bei Theme-Wechsel

---

## 📋 PHASE 7: DOCUMENTATION

### 7.1 Developer Documentation
**Datei:** `MATERIAL3_USAGE.md`

**Inhalt:**
- [ ] Wie man AdaptiveScaffold verwendet
- [ ] Wie man eigene Color Schemes hinzufügt
- [ ] Theme Customization Guide
- [ ] Breakpoint Guidelines
- [ ] Component Usage Examples

### 7.2 User Documentation
**Datei:** `docs/USER_THEME_GUIDE.md`

**Inhalt:**
- [ ] Wie man Theme ändert
- [ ] Verfügbare Color Schemes
- [ ] Screenshots

---

## 📊 GESCHÄTZTER ZEITAUFWAND

| Phase | Tasks | Geschätzte Zeit |
|-------|-------|-----------------|
| Phase 1: Analyse | Abgeschlossen | ✅ Done |
| Phase 2: Theme System | 12 Tasks | 8-12 Stunden |
| Phase 3: Adaptive Layout | 10 Tasks | 12-16 Stunden |
| Phase 4: Screen Migration | 15 Screens | 20-30 Stunden |
| Phase 5: Theme Selector | 5 Tasks | 4-6 Stunden |
| Phase 6: Testing | 15 Tests | 6-8 Stunden |
| Phase 7: Documentation | 2 Docs | 2-3 Stunden |
| **GESAMT** | **~65 Tasks** | **52-75 Stunden** |

---

## 🎯 PRIORITÄTEN

### Sprint 1 (Woche 1-2): Foundation
- Phase 2.1-2.3: Theme System (Core)
- Phase 3.1-3.2: Adaptive Scaffold (Basic)

### Sprint 2 (Woche 3): Core Screens
- Phase 4.1: Dashboard + Message Screens

### Sprint 3 (Woche 4): Polish
- Phase 5: Theme Selector UI
- Phase 6: Testing

### Sprint 4 (Woche 5): Complete
- Phase 4.2-4.4: Remaining Screens
- Phase 7: Documentation

---

## 🚀 QUICK START (für Entwicklung)

### Schritt 1: Dependencies hinzufügen
```yaml
# pubspec.yaml
dependencies:
  provider: ^6.0.0          # Theme State Management
  shared_preferences: ^2.0.0  # Native Preferences
  idb_browser: ^2.0.0       # Web Storage
```

### Schritt 2: Main.dart anpassen
```dart
void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, _) {
        return MaterialApp.router(
          theme: themeProvider.lightTheme,
          darkTheme: themeProvider.darkTheme,
          themeMode: themeProvider.themeMode,
          // ... rest
        );
      },
    );
  }
}
```

### Schritt 3: Erste Screen Migration
```dart
// Vorher:
Scaffold(
  appBar: AppBar(title: Text('Chat')),
  body: ListView(...),
)

// Nachher:
AdaptiveScaffold(
  appBarTitle: Text('Chat'),
  destinations: [...],
  selectedIndex: 0,
  onDestinationSelected: (i) => {...},
  body: ListView(...),
)
```

---

## 📝 NOTIZEN

### Design Prinzipien (Material 3)
1. **Elevation System:** Verwende Material 3 Elevation (keine harten Schatten)
2. **Color System:** Primary, Secondary, Tertiary + Container Varianten
3. **Shape System:** Rounded Corners (12-28dp), keine scharfen Ecken
4. **Typography:** Material 3 Type Scale (Display, Headline, Title, Body, Label)
5. **State Layers:** Hover, Focus, Pressed States (automatisch durch Material 3)

### Migration Checklist (pro Screen)
- [ ] Scaffold → AdaptiveScaffold
- [ ] AppBar → AdaptiveAppBar
- [ ] Hardcoded Colors → Theme Colors
- [ ] Container → Card (wo sinnvoll)
- [ ] Padding: 16dp horizontal Standard
- [ ] BorderRadius: 12-28dp
- [ ] Elevation: 0, 1, 2, 3, 4 (Material 3)

### Breaking Changes
⚠️ **Achtung:** Migration kann Breaking Changes verursachen:
- Widget API ändert sich (neue Props)
- Layout Struktur ändert sich (Navigation)
- Color References ändern sich (Theme statt Hardcoded)

**Empfehlung:** Feature Branch + Schrittweise Migration

---

## ✅ AKZEPTANZKRITERIEN

**Das Projekt gilt als abgeschlossen, wenn:**
1. ✅ Alle Screens verwenden Material 3 Components
2. ✅ Adaptive Navigation funktioniert (Mobile/Tablet/Desktop)
3. ✅ 5+ Color Schemes verfügbar
4. ✅ Theme-Wechsel funktioniert + persistiert
5. ✅ Alle Tests bestanden
6. ✅ Documentation vollständig
7. ✅ Keine hardcoded Colors mehr (außer schwarz/weiß für Kontrast)
8. ✅ Performance: Theme-Wechsel < 100ms
9. ✅ Responsive: Alle Breakpoints getestet
10. ✅ Accessibility: WCAG AA Kontrast erfüllt

---

**Status:** 📋 **PLAN ERSTELLT - BEREIT FÜR IMPLEMENTATION**

**Nächste Schritte:**
1. Review dieses Plans
2. Dependencies installieren (`flutter pub get`)
3. Beginne mit Phase 2.1 (Theme Generator)
