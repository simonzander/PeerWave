# PeerWave Design System - Implementation Guide

## ✅ Abgeschlossene Updates (November 2025)

### 1. **Farb-System**
```dart
// Layout-spezifische Backgrounds (Tonwert-Trennung)
AppThemeConstants.sidebarBackground      // #0E1114 (Native Desktop Sidebar)
AppThemeConstants.contextPanelBackground // #14181D (Channel/Message Listen)
AppThemeConstants.mainViewBackground     // #181C21 (Chat/Activity Content)
AppThemeConstants.inputBackground        // #181D23 (TextField, Search)
AppThemeConstants.appBackground          // #0E1218 (außerhalb Layout)

// Aktiver Channel (Discord-Style)
AppThemeConstants.activeChannelBackground // rgba(14, 132, 129, 0.08)
AppThemeConstants.activeChannelBorderStyle // Border(left: 2px solid #0E8481)

// Text Opacities
AppThemeConstants.textPrimary   // 85% Weiß (Items)
AppThemeConstants.textSecondary // 60% Grau (Headers)

// Highlight Color
ColorScheme.primary = #0E8481  // RGB(14, 132, 129) - Türkis
```

### 2. **Spacing-System** (6 / 12 / 20 / 26)
```dart
AppThemeConstants.spacingXs = 6   // Kleine Abstände, Padding in Badges
AppThemeConstants.spacingSm = 12  // Standard Padding (ListTiles, Inputs)
AppThemeConstants.spacingMd = 20  // Zwischen Sections
AppThemeConstants.spacingLg = 26  // Große Blöcke

// Presets
AppThemeConstants.paddingSm               // EdgeInsets.all(12)
AppThemeConstants.paddingHorizontalSm     // EdgeInsets.symmetric(horizontal: 12)
```

### 3. **Border Radius** (erwachsener Look)
```dart
AppThemeConstants.radiusSmall = 8    // Badges, Chips
AppThemeConstants.radiusStandard = 14 // Buttons, Inputs, Cards (STANDARD)
AppThemeConstants.radiusLarge = 20   // Modals, große Cards

// Presets
AppThemeConstants.borderRadiusStandard  // BorderRadius.all(Radius.circular(14))
```

### 4. **Animationen** (subtil & schnell)
```dart
AppThemeConstants.animationFast = 150ms    // Hover, Badge updates
AppThemeConstants.animationNormal = 250ms  // Navigation, Selection
AppThemeConstants.animationSlow = 350ms    // Drawer, Modal

// Curves
AppThemeConstants.animationCurve  // Curves.easeInOutCubic (Standard)
AppThemeConstants.fadeCurve       // Curves.easeOut (Opacity)
AppThemeConstants.slideCurve      // Curves.easeInOutQuart (Position)
```

### 5. **Typography**
```dart
// Context Panel Headers (UPPERCASE)
AppThemeConstants.contextHeaderStyle
// 11px / bold / letter-spacing: 1.5 / 60% Grau / UPPERCASE

// Standard
AppThemeConstants.fontSizeBody = 14    // Normal Text
AppThemeConstants.fontSizeCaption = 12 // Klein (Timestamps, Hints)
AppThemeConstants.fontSizeH2 = 20      // Überschriften
```

### 6. **Icons** (Filled Style)
```dart
AppThemeConstants.iconActivity = Icons.bolt
AppThemeConstants.iconPeople = Icons.people
AppThemeConstants.iconFiles = Icons.folder
AppThemeConstants.iconChannels = Icons.tag
AppThemeConstants.iconMessages = Icons.chat_bubble
AppThemeConstants.iconSettings = Icons.settings_rounded  // Rounded für filled look
```

---

## 🎨 Neue Widgets verwenden

### AnimatedSelectionTile
Für Channel/Message Listen mit Selection-Animation und linkem Border.

```dart
AnimatedSelectionTile(
  leading: Icon(Icons.tag, size: AppThemeConstants.iconSizeSmall),
  title: Text('# general'),
  trailing: AnimatedBadge(count: 5, isSmall: true),
  selected: true,  // Zeigt linken Border + Background
  onTap: () => navigateToChannel(),
)
```

**Features:**
- ✅ Hover-Effekt (5% primary color opacity)
- ✅ Linker Border (2px) wenn selected
- ✅ Background (8% türkis) wenn selected
- ✅ 150ms Animation (easeInOutCubic)
- ✅ 14px Border Radius
- ✅ 12px Padding horizontal

### AnimatedBadge
Badge mit Appear/Disappear Animation (Scale + Fade).

```dart
AnimatedBadge(
  count: unreadCount,
  isSmall: true,  // 16x16 statt 20x20
)
```

**Features:**
- ✅ Scale Animation (0.0 → 1.0 mit easeOutBack)
- ✅ Fade Animation (opacity 0.0 → 1.0)
- ✅ 8px Border Radius (klein für Details)
- ✅ Verschwindet automatisch bei count = 0
- ✅ "99+" für count > 99

### ContextPanelHeader
UPPERCASE Header für Context Panel Sections.

```dart
ContextPanelHeader(
  title: 'Channels',  // Wird zu "CHANNELS"
  trailing: IconButton(
    icon: Icon(Icons.expand_more),
    onPressed: () => toggleExpanded(),
  ),
)
```

**Features:**
- ✅ Automatisch UPPERCASE
- ✅ 11px / bold / letter-spacing: 1.5
- ✅ 60% Grau (textSecondary)
- ✅ Optional trailing Widget

### HoverAnimatedContainer
Container mit Hover-Effekt für Buttons/Cards.

```dart
HoverAnimatedContainer(
  onTap: () => doSomething(),
  child: Padding(
    padding: AppThemeConstants.paddingSm,
    child: Text('Hover me!'),
  ),
)
```

**Features:**
- ✅ Hover-Color mit 150ms Animation
- ✅ InkWell Ripple-Effekt
- ✅ Konfigurierbar (hoverColor, borderRadius)

### SlidePageRoute
Custom Page Transition (Slide + Fade).

```dart
Navigator.of(context).push(
  SlidePageRoute(
    builder: (context) => NewScreen(),
    startOffset: Offset(1.0, 0.0),  // Von rechts (Standard)
  ),
);
```

**Features:**
- ✅ Slide von rechts nach links
- ✅ Kombiniert mit Fade-In
- ✅ 250ms Duration (easeInOutQuart)
- ✅ Konfigurierbar (startOffset für andere Richtungen)

### AnimatedSection
Expandable Section mit smooth Animation.

```dart
AnimatedSection(
  expanded: _channelsExpanded,
  child: Column(
    children: channelsList,
  ),
)
```

**Features:**
- ✅ CrossFade Animation (250ms)
- ✅ Size Animation (height grows/shrinks)
- ✅ Fade Curve für smooth Transition

---

## 🚀 Migration Guide

### Alte ListTiles ersetzen:
```dart
// ❌ ALT
ListTile(
  title: Text('Channel'),
  selected: true,
  onTap: () {},
)

// ✅ NEU
AnimatedSelectionTile(
  title: Text('Channel'),
  selected: true,
  onTap: () {},
)
```

### Alte Badges ersetzen:
```dart
// ❌ ALT
if (count > 0)
  Container(
    padding: EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: Colors.red,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(count.toString()),
  )

// ✅ NEU
AnimatedBadge(count: count, isSmall: true)
```

### Alte Headers ersetzen:
```dart
// ❌ ALT
Text(
  'CHANNELS',
  style: TextStyle(fontSize: 12, color: Colors.grey),
)

// ✅ NEU
ContextPanelHeader(title: 'Channels')
```

### Divider entfernen:
```dart
// ❌ ALT
Column(
  children: [
    Widget1(),
    Divider(),  // ← ENTFERNEN
    Widget2(),
  ],
)

// ✅ NEU - Tonwert-Trennung durch Container Background
Column(
  children: [
    Container(
      color: AppThemeConstants.contextPanelBackground,
      child: Widget1(),
    ),
    Container(
      color: AppThemeConstants.mainViewBackground,
      child: Widget2(),
    ),
  ],
)
```

---

## 📐 Layout-Struktur

### Desktop (Native with Server Bar):
```
┌─────────────────────────────────────────────────┐
│ [Server Bar] │ [Sidebar] │ [Context] │ [Main]  │
│    #0E1114   │  #0E1114  │  #14181D  │ #181C21 │
│   (72px)     │   (icons) │  (list)   │(content)│
└─────────────────────────────────────────────────┘
```

### Web/Mobile/Tablet (ohne Server Bar):
```
┌───────────────────────────────────────┐
│ [Sidebar/Drawer] │ [Context] │ [Main] │
│     #0E1114      │  #14181D  │#181C21 │
└───────────────────────────────────────┘
```

**Wichtig:** Keine vertikalen Divider zwischen Sections - nur Tonwert-Trennung!

---

## 🎯 Best Practices

### 1. Spacing konsequent nutzen
```dart
// ✅ GUT
padding: AppThemeConstants.paddingSm

// ❌ NICHT
padding: EdgeInsets.all(10)  // Custom Werte vermeiden
```

### 2. Animationen konsistent
```dart
// ✅ GUT
AnimatedContainer(
  duration: AppThemeConstants.animationNormal,
  curve: AppThemeConstants.animationCurve,
  ...
)

// ❌ NICHT
AnimatedContainer(
  duration: Duration(milliseconds: 200),  // Custom Werte
  curve: Curves.linear,  // Falsche Curve
  ...
)
```

### 3. Farben aus Constants
```dart
// ✅ GUT
color: AppThemeConstants.textPrimary

// ❌ NICHT
color: Colors.white.withOpacity(0.85)  // Direkte Values
```

### 4. Icons filled bevorzugen
```dart
// ✅ GUT
Icon(AppThemeConstants.iconSettings)  // settings_rounded

// ❌ NICHT
Icon(Icons.settings_outlined)  // Outlined vermeiden
```

---

## 📊 Performance-Tipps

1. **AnimatedWidgets sind optimiert** - kein Rebuild des gesamten Baums
2. **MouseRegion nur wo nötig** - nicht in ScrollViews mit 100+ Items
3. **const Constructors nutzen** - für statische Styles
4. **Keys bei Listen** - für bessere Animation Performance

```dart
// ✅ PERFORMANT
ListView.builder(
  itemBuilder: (context, index) {
    return AnimatedSelectionTile(
      key: ValueKey(channels[index].uuid),  // ← Key für Animationen
      ...
    );
  },
)
```

---

## 🧪 Testing

Siehe `design_system_example.dart` für vollständiges Beispiel mit:
- ✅ Context Panel mit UPPERCASE Headers
- ✅ AnimatedSelectionTile mit Badges
- ✅ Hover-Effekte
- ✅ Page Transitions
- ✅ Expandable Sections
- ✅ Tonwert-Trennung (kein Divider)

**Zum Testen:**
```dart
Navigator.of(context).push(
  MaterialPageRoute(
    builder: (context) => const DesignSystemExample(),
  ),
);
```

---

## 🎨 Color Scheme Palette

| Name | Hex | RGB | Verwendung |
|------|-----|-----|-----------|
| Highlight | #0E8481 | 14, 132, 129 | Primary Color, Border, Hover |
| Sidebar | #0E1114 | 14, 17, 20 | Navigation Sidebar |
| Context Panel | #14181D | 20, 24, 29 | Channel/Message Listen |
| Main View | #181C21 | 24, 28, 33 | Chat Content |
| Input BG | #181D23 | 24, 29, 35 | TextField Background |
| App BG | #0E1218 | 14, 18, 24 | Scaffold |
| Text Primary | rgba(255,255,255,0.85) | - | Normal Text |
| Text Secondary | rgba(255,255,255,0.6) | - | Headers, Hints |
| Active Channel BG | rgba(14,132,129,0.08) | - | Selected Item |

---

**Weitere Fragen?** Siehe `app_theme_constants.dart` für vollständige API-Dokumentation.
