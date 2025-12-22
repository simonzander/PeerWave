# PeerWave Client Architecture Review

**Date:** December 22, 2025  
**Reviewer:** Architecture Analysis  
**Project:** PeerWave Flutter Client  
**Current State:** Mixed MVP/Service-based architecture

---

## Executive Summary

PeerWave is a feature-rich Flutter application for secure messaging, video conferencing, and file sharing. While the codebase demonstrates strong E2EE implementation and cross-platform support, the current architecture suffers from **inconsistent organization patterns** that hinder scalability and maintainability. This review provides actionable recommendations to align with Google Flutter standards and enterprise-grade architectural practices.

**Overall Grade:** C+ (Functional but needs restructuring)

---

## Current Architecture Analysis

### 1. Directory Structure Issues

#### 🔴 **Critical: Overlapping Presentation Layers**
```
lib/
├── pages/          ❌ Contains: theme_settings_page.dart
├── screens/        ❌ Contains: meetings_screen.dart, signal_setup_screen.dart
├── views/          ❌ Contains: video_conference_view.dart, meeting_prejoin_view.dart
└── app/            ❌ Contains: dashboard_page.dart, profile_page.dart
```

**Problem:** Four different folders (`pages/`, `screens/`, `views/`, `app/`) serve the same purpose - UI presentation. This creates:
- Confusion about where to place new UI components
- Inconsistent naming conventions
- Difficult code navigation
- No clear architectural intent

**Impact:** Increases onboarding time and makes refactors riskier because UI entrypoints are spread across multiple competing conventions.

---

#### 🟡 **Moderate: Flat Service Layer**
```
services/
├── activities_service.dart
├── api_service.dart
├── audio_processor_service.dart
├── auth_service_native.dart
├── call_service.dart
├── e2ee_service.dart
├── meeting_service.dart
├── message_listener_service.dart
├── signal_service.dart
├── socket_service.dart
├── user_profile_service.dart
├── video_conference_service.dart
└── [60+ more services]
```

**Problem:** 60+ services in a single flat directory with no domain grouping.

**Issues:**
- No separation of concerns by feature domain
- Hard to understand service dependencies
- Platform-specific files mixed with core logic (`auth_service_native.dart`, `auth_service_web.dart`)
- Storage services mixed with business logic services

---

#### 🟢 **Good: Some Proper Groupings**
```
✅ core/              # Infrastructure concerns
✅ extensions/        # Dart extensions
✅ models/           # Data models (though could be better organized)
✅ providers/        # State management (Provider pattern)
✅ theme/            # Theming configuration
✅ widgets/          # Reusable UI components
```

---

### 2. Architectural Pattern Analysis

#### **Current Pattern:** Service-Locator + Provider (Hybrid)

**Strengths:**
- Provider for state management is appropriate
- Services centralize business logic
- Platform-specific implementations use conditional imports correctly

**Weaknesses:**
- No clear separation between data, domain, and presentation layers
- Services do too much (God Object anti-pattern in some cases)
- Tight coupling between UI and services
- No repository abstraction layer
- Models are anemic (no behavior, just data)

---

### 3. Code Organization by Feature Domain

**Current State:** Technology-layered (bad for large apps)
```
lib/
├── services/       # ALL services
├── models/         # ALL models
├── screens/        # ALL screens
└── widgets/        # ALL widgets
```

**Problem:** To understand the "Meetings" feature, you must navigate:
- `services/meeting_service.dart`
- `models/meeting.dart`
- `screens/meetings_screen.dart`
- `views/meeting_video_conference_view.dart`
- `widgets/meeting_dialog.dart`

This violates **Feature Cohesion Principle**.

---

## Compliance with Google Flutter Standards

### ✅ **Strengths**

1. **File Naming:** Consistently uses snake_case (✓)
2. **Widget Structure:** Proper use of StatefulWidget/StatelessWidget (✓)
3. **Platform Adaptation:** Conditional imports for web/native (✓)
4. **Provider Pattern:** Correct implementation of ChangeNotifier (✓)

### ❌ **Gaps**

1. **No Clean Architecture layers** (Data → Domain → Presentation)
2. **Missing Repository Pattern** for data abstraction
3. **Services contain UI logic** (e.g., navigation in services)
4. **No Use Cases layer** (business logic mixed in services)
5. **Testing structure not evident** (no clear separation for testability)

---

## Alignment with Flutter’s Architectural Overview

Reference: https://docs.flutter.dev/resources/architectural-overview

Flutter is designed as an extensible **layered system** (Foundation → Animation/Painting/Gestures → Rendering → Widgets → Material/Cupertino) and promotes a **reactive, declarative UI model**.

Key implications for app architecture:

- Widgets are immutable configuration.
- `build()` should be **fast and side-effect free** (no network calls, disk I/O, service initialization, or long computations).
- UI should rebuild from state changes (`setState`, `InheritedWidget`, Provider/Riverpod/Bloc, etc.).
- Flutter internally maintains Widget/Element/RenderObject trees; keeping build “pure” makes updates predictable and performant.

### What PeerWave already does well (relative to Flutter’s model)

- Uses declarative UI patterns and Provider (Provider is a common wrapper around `InheritedWidget`).
- Uses conditional imports for web/native in several places, supporting platform differences cleanly.
- Has strong widget composition reuse in `widgets/`.

### Where PeerWave diverges (and why it matters)

1. **Very large composition root (`main.dart`)**
  - Flutter apps benefit from a small composition root that wires routing, DI, and top-level state. A very large `main.dart` makes dependency flow and feature boundaries harder to maintain.

2. **Side-effects risk leaking into UI rebuilds**
  - The current “service-locator + Provider” hybrid makes it easy to call services directly from UI. This can accidentally violate Flutter’s guidance that build should be fast and side-effect free, causing rebuild-driven bugs and jank.

3. **Platform-specific code is not clearly isolated**
  - Platform implementations (web/native) are present, but mixed into broad folders like `services/`. Long-term maintenance improves when platform concerns are centralized under a `core/platform/` (or similar) boundary.

4. **Feature cohesion is low**
  - Understanding a single feature requires jumping across `services/`, `models/`, and multiple UI folders. Flutter-scale apps are easier to evolve when features are cohesive modules.

### Additional Flutter architecture implications (practical guidance)

Flutter’s rendering pipeline (build → layout → paint → composite) is optimized when the widget layer stays declarative and cheap.

**Repo-specific “do/don’t” rules:**

- **Don’t** start async work inside `build()` (network, disk, crypto, socket setup). **Do** start it in lifecycle (`initState`, `didChangeDependencies`) or in a ViewModel/Provider and expose state.
- **Don’t** mutate state as a side effect of reading it (for example, “lazy loading” inside getters that a widget reads during build). **Do** trigger loads via explicit intent methods (e.g., `loadProfile(userId)`).
- **Do** keep expensive computations off the UI thread; compute asynchronously and store results in state. Use selectors (`Selector`/`Consumer`/Riverpod providers) to limit rebuild surfaces.
- **Do** treat `services/` as *implementation detail* behind repository interfaces. Widgets should depend on viewmodels/usecases/repositories, not on concrete services.

**Platform embedding / interop boundary:**

Flutter’s architecture cleanly separates Dart code from platform code (platform channels, FFI, plugins). For maintainability:

- Centralize platform-dependent code under a single boundary (example target: `core/platform/` and `core/interop/`).
- Keep `*_native.dart` / `*_web.dart` implementations behind a shared interface so features don’t import platform files directly.
- Prefer “data sources” (platform or network) at the edge, called via repositories/usecases.

**Packages as modules (high-value repository style):**

Flutter’s own ecosystem treats many capabilities as packages. PeerWave is large enough that you can incrementally extract internal packages to enforce boundaries:

- Start with cross-cutting, high-risk domains: `encryption`, `storage`, `video`.
- Extract to local path packages (for example, `packages/peerwave_encryption/`, `packages/peerwave_video/`) with a small, explicit public API.
- Keep `client/lib/` as the “app shell” that wires routing, DI, and feature composition.

---

## Widget, Element, and RenderObject Trees

Flutter maintains three parallel trees:

| Tree | Description | Lifecycle |
|------|-------------|-----------|
| **Widget Tree** | Immutable configuration objects created by `build()` | Recreated frequently (every frame if needed) |
| **Element Tree** | Persistent objects that manage widget-to-render mapping | Long-lived, updated when widget config changes |
| **RenderObject Tree** | Objects that perform layout and painting | Persistent, handles actual pixels |

### Why this matters for PeerWave

PeerWave has complex, stateful UI (video grids, encrypted message lists, file transfer progress). Understanding this model helps avoid performance pitfalls:

**DO:**
```dart
// Widget is just configuration - cheap to recreate
class ParticipantTile extends StatelessWidget {
  final Participant participant;
  const ParticipantTile({required this.participant});
  
  @override
  Widget build(BuildContext context) {
    // Element tree persists; only widget config is replaced
    return Container(
      child: VideoView(participant.videoTrack),
    );
  }
}
```

**DON'T:**
```dart
// Expensive object creation in build - this allocates on every rebuild
class ParticipantTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final processor = AudioProcessor(); // Created every build!
    return Container(child: ...);
  }
}
```

### Keys and Element Reuse

When Flutter rebuilds a widget tree, it matches elements by **widget type and key**. For PeerWave's dynamic lists (participants, messages, channels), use `Key` to help Flutter track identity:

```dart
// Use ValueKey for participant grids
ListView.builder(
  itemBuilder: (context, index) {
    final participant = participants[index];
    return ParticipantTile(
      key: ValueKey(participant.id), // Helps Flutter track this across rebuilds
      participant: participant,
    );
  },
)
```

---

## Widget Lifecycle and State

### StatefulWidget Lifecycle

```
createState() -> initState() -> didChangeDependencies()
       |
    build() <- setState() / didUpdateWidget()
       |
   deactivate() -> dispose()
```

### PeerWave-Specific Lifecycle Rules

| Lifecycle Method | What to Do | PeerWave Examples |
|------------------|-----------|-------------------|
| `initState()` | Initialize controllers, start subscriptions | Subscribe to socket events, init video room |
| `didChangeDependencies()` | Access inherited widgets (after initState) | Read `Provider.of<T>(context)` the first time |
| `build()` | Return widget tree ONLY. No side effects! | Compose UI from state |
| `didUpdateWidget()` | React to parent-passed config changes | Update when participant ID changes |
| `deactivate()` | Pause resources (may reactivate) | Pause video streams |
| `dispose()` | Release resources permanently | Close socket, dispose controllers |

### Critical: What NOT to do in `build()`

```dart
// ANTI-PATTERN: Side effects in build
@override
Widget build(BuildContext context) {
  // Network call in build - BAD
  apiService.loadMessages(conversationId);
  
  // Logging/analytics in build - BAD
  analytics.logScreenView('chat');
  
  // Starting listeners in build - BAD
  socket.on('message', handleMessage);
  
  return Container(...);
}

// CORRECT: Side effects in lifecycle methods
@override
void initState() {
  super.initState();
  _loadMessages();
  _setupSocketListeners();
}

@override
Widget build(BuildContext context) {
  // Pure function of state -> UI
  return Consumer<MessageProvider>(
    builder: (context, provider, _) => MessageList(
      messages: provider.messages,
      isLoading: provider.isLoading,
    ),
  );
}
```

---

## Render Pipeline Optimization

Flutter's render pipeline: **Build -> Layout -> Paint -> Composite**

### Layout Performance

PeerWave's video grid is layout-intensive. Follow these rules:

1. **Avoid `Intrinsic` widgets in hot paths** (`IntrinsicWidth`, `IntrinsicHeight` cause expensive 2-pass layout)
2. **Use `const` constructors** - skips rebuild entirely
3. **Limit rebuild scope** with `Consumer`/`Selector`

```dart
// Rebuilds entire tree when any video state changes - BAD
@override
Widget build(BuildContext context) {
  final conferenceState = context.watch<VideoConferenceProvider>();
  return Column(
    children: [
      VideoGrid(participants: conferenceState.participants),
      ControlBar(isMuted: conferenceState.isMuted), // Rebuilds even if only participants changed
    ],
  );
}

// Granular rebuilds with Selector - GOOD
@override
Widget build(BuildContext context) {
  return Column(
    children: [
      Selector<VideoConferenceProvider, List<Participant>>(
        selector: (_, provider) => provider.participants,
        builder: (_, participants, __) => VideoGrid(participants: participants),
      ),
      Selector<VideoConferenceProvider, bool>(
        selector: (_, provider) => provider.isMuted,
        builder: (_, isMuted, __) => ControlBar(isMuted: isMuted),
      ),
    ],
  );
}
```

### Paint Optimization

For PeerWave's message bubbles and video overlays:

- Use `RepaintBoundary` around expensive-to-paint subtrees (video tiles)
- Avoid `Opacity` widget; prefer `FadeTransition` or color alpha
- Cache decoded images

```dart
// Isolate video tile painting
RepaintBoundary(
  child: VideoParticipantTile(participant: participant),
)
```

---

## Platform Channels & FFI in PeerWave

### Current Platform Integration Points

| Feature | Mechanism | Current Location |
|---------|-----------|------------------|
| WebAuthn | Platform Channel (JS interop on web) | `services/webauthn_service.dart` |
| E2EE (Windows) | FFI + native crypto | `services/windows_e2ee_manager.dart` |
| System Tray | Platform Channel | `services/system_tray_service.dart` |
| Notifications | Platform Channel | `services/notification_service.dart` |
| Secure Storage | Plugin (flutter_secure_storage) | `services/secure_session_storage.dart` |

### Recommended Platform Boundary Structure

```
lib/
  core/
    platform/
      platform_service.dart           # Abstract interface
      platform_service_native.dart    # iOS/Android/Desktop impl
      platform_service_web.dart       # Web impl
      channels/
        webauthn_channel.dart
        notification_channel.dart
        system_tray_channel.dart
```

### FFI Best Practices (for E2EE)

```dart
// Isolate FFI calls behind a repository interface
abstract class CryptoRepository {
  Future<Uint8List> encrypt(Uint8List plaintext, Uint8List key);
  Future<Uint8List> decrypt(Uint8List ciphertext, Uint8List key);
}

// Implementation uses FFI internally
class NativeCryptoRepository implements CryptoRepository {
  late final DynamicLibrary _lib;
  
  @override
  Future<Uint8List> encrypt(Uint8List plaintext, Uint8List key) async {
    // FFI call - isolated from UI
    return compute(_encryptNative, EncryptParams(plaintext, key));
  }
}
```

---

## Web Support Considerations

PeerWave supports web via Flutter web. Key architectural implications:

### Renderers

| Renderer | Best For | PeerWave Consideration |
|----------|----------|------------------------|
| **CanvasKit** (default) | Complex UI, consistent rendering | Preferred for video conferencing UI |
| **Skwasm** (WASM) | Performance-critical, modern browsers | Consider for future WebRTC integration |

### Web-Specific Architecture Rules

1. **No `dart:io` in shared code** - Use conditional imports
   ```dart
   // Current approach is correct
   import 'auth_service_web.dart' if (dart.library.io) 'auth_service_native.dart';
   ```

2. **IndexedDB vs SQLite** - PeerWave correctly uses `idb_factory_web.dart` / `idb_factory_native.dart`

3. **Web Workers for E2EE**
   - Current: `web/e2ee_worker.js` (good)
   - Recommendation: Keep crypto off main thread for UI responsiveness

4. **Deferred Loading** - For large features, use deferred imports:
   ```dart
   // Load video conferencing lazily
   import 'features/video_conferencing/video_conferencing.dart' deferred as video;
   
   Future<void> joinCall() async {
     await video.loadLibrary();
     video.joinConference(roomId);
   }
   ```

### Web Bundle Size Strategy

Current PeerWave web build may be large due to:
- LiveKit SDK
- E2EE libraries
- Signal Protocol

**Recommendations:**
- Split by route (video conferencing, messaging, file transfer)
- Use `--split-debug-info` and `--obfuscate` for release
- Consider lazy loading heavy features

---

## Anti-Patterns Checklist (PeerWave-Specific)

Use this checklist during code review:

### Critical Anti-Patterns

| Anti-Pattern | Why It's Bad | PeerWave Risk Areas |
|--------------|--------------|---------------------|
| Side effects in `build()` | Causes infinite loops, jank | Message loading, profile fetching |
| God Objects | Hard to test, modify | `video_conference_service.dart` (2156 lines!) |
| Direct service calls from widgets | Tight coupling, untestable | Many screens call `ApiService` directly |
| Mutable global state | Race conditions, unpredictable | Singleton services with mutable state |
| `async` in `build()` | Can't await, causes rebuild loops | `FutureBuilder` misuse |

### Moderate Anti-Patterns

| Anti-Pattern | Why It's Bad | PeerWave Examples |
|--------------|--------------|-------------------|
| Mixed presentation folders | Confusing navigation | `pages/`, `screens/`, `views/`, `app/` |
| Platform code in features | Hard to test, maintain | Scattered `*_web.dart` / `*_native.dart` |
| No repository abstraction | Can't swap implementations | Services hit API directly |
| Inline styles | Inconsistent theming | Hardcoded colors in widgets |

### Code Smell Indicators

```dart
// main.dart > 500 lines -> Extract to feature routers
// Current: 1798 lines! Critical refactor needed

// Service > 500 lines -> Split responsibilities
// video_conference_service.dart: 2156 lines

// > 3 providers in one widget -> Consider composition
MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => A()),
    ChangeNotifierProvider(create: (_) => B()),
    ChangeNotifierProvider(create: (_) => C()),
    ChangeNotifierProvider(create: (_) => D()),
    ChangeNotifierProvider(create: (_) => E()), // Too many
  ],
  child: ...
)

// Deeply nested callbacks -> Extract to methods
socket.on('event', (data) {
  // 50 lines of logic - BAD
  // Should be: _handleSocketEvent(data)
});
```

---

## Composition Root Refactoring (main.dart)

### Current Problem

`main.dart` is **1798 lines** - a severe composition root bloat. This violates Flutter's guidance to keep the composition root small.

### Target Structure

```dart
// main.dart (< 50 lines)
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies();
  runApp(const PeerWaveApp());
}

class PeerWaveApp extends StatelessWidget {
  const PeerWaveApp();
  
  @override
  Widget build(BuildContext context) {
    return AppProviders(
      child: MaterialApp.router(
        routerConfig: appRouter,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
      ),
    );
  }
}
```

```dart
// core/di/injection.dart
Future<void> configureDependencies() async {
  await initCore();
  await initFeatures();
}

// core/routing/app_router.dart
final appRouter = GoRouter(
  routes: [
    ...authRoutes,
    ...dashboardRoutes,
    ...videoConferencingRoutes,
    ...adminRoutes,
  ],
);

// features/authentication/routes.dart
final authRoutes = [
  GoRoute(path: '/login', builder: (_, __) => const LoginPage()),
  GoRoute(path: '/register', builder: (_, __) => const RegisterPage()),
];
```

### Migration Steps

1. Extract route definitions to feature-specific files
2. Move providers to `AppProviders` widget
3. Extract DI setup to `core/di/`
4. Keep `main.dart` as thin entry point only

## MVP Structure Review (what “MVP” means in Flutter)

Flutter’s reactive UI model maps most naturally to **MVVM-ish** structures (Page/Widget + ViewModel/Controller), or to “Clean Architecture” (Presentation/Domain/Data). Classic MVP (Presenter + View) is possible, but tends to fight Flutter’s rebuild model unless you keep the presenter strictly UI-agnostic and treat `build()` as a pure projection of state.

### Recommendation for PeerWave

- Keep widgets as the “View”.
- Use `ChangeNotifier` (or a later choice like Riverpod/Bloc) as a **ViewModel/Controller**.
- Keep side effects (network/storage) out of widgets.
- Prefer **feature-first** modules where each feature contains:
  - `presentation/` (pages, widgets, providers/viewmodels)
  - `domain/` (use cases, repository interfaces, entities)
  - `data/` (repository implementations, datasources, DTO/models)

This preserves Flutter’s core mental model: `UI = f(state)`.

## Recommended Architecture: Clean Architecture + Feature-First

### **Target Architecture Pattern**

```
┌─────────────────────────────────────────────────────┐
│                   Presentation                       │
│  (UI, Widgets, Pages, ViewModels/Controllers)       │
├─────────────────────────────────────────────────────┤
│                     Domain                           │
│  (Use Cases, Entities, Repository Interfaces)       │
├─────────────────────────────────────────────────────┤
│                      Data                            │
│  (Repository Impl, Data Sources, DTOs, Mappers)     │
└─────────────────────────────────────────────────────┘
```

**Dependency Rule:** Dependencies point inward only.

---

## Proposed Restructuring Plan

### **Phase 1: Feature-First Organization (Priority: HIGH)**

Reorganize by business domains rather than technical layers:

```dart
lib/
├── main.dart
├── app.dart
│
├── core/                              # Shared infrastructure
│   ├── config/
│   │   ├── app_config.dart
│   │   └── environment.dart
│   ├── constants/
│   │   ├── api_constants.dart
│   │   └── storage_keys.dart
│   ├── error/
│   │   ├── exceptions.dart
│   │   └── failures.dart
│   ├── network/
│   │   ├── api_client.dart
│   │   ├── interceptors/
│   │   └── network_info.dart
│   ├── platform/
│   │   ├── platform_service.dart
│   │   ├── platform_native.dart
│   │   └── platform_web.dart
│   ├── storage/
│   │   ├── secure_storage.dart
│   │   └── local_storage.dart
│   ├── theme/
│   │   ├── app_theme.dart
│   │   ├── theme_provider.dart
│   │   └── colors.dart
│   ├── utils/
│   │   ├── date_formatter.dart
│   │   ├── validators.dart
│   │   └── extensions/
│   └── di/                           # Dependency Injection
│       └── injection_container.dart
│
├── features/                         # Feature modules
│   │
│   ├── authentication/               # Auth feature
│   │   ├── data/
│   │   │   ├── datasources/
│   │   │   │   ├── auth_remote_datasource.dart
│   │   │   │   └── auth_local_datasource.dart
│   │   │   ├── models/
│   │   │   │   ├── user_model.dart
│   │   │   │   └── session_model.dart
│   │   │   └── repositories/
│   │   │       └── auth_repository_impl.dart
│   │   ├── domain/
│   │   │   ├── entities/
│   │   │   │   ├── user.dart
│   │   │   │   └── session.dart
│   │   │   ├── repositories/
│   │   │   │   └── auth_repository.dart
│   │   │   └── usecases/
│   │   │       ├── login_user.dart
│   │   │       ├── logout_user.dart
│   │   │       ├── register_user.dart
│   │   │       └── verify_otp.dart
│   │   └── presentation/
│   │       ├── pages/
│   │       │   ├── login_page.dart
│   │       │   ├── register_page.dart
│   │       │   └── otp_verification_page.dart
│   │       ├── widgets/
│   │       │   ├── auth_form.dart
│   │       │   └── webauthn_button.dart
│   │       └── providers/
│   │           └── auth_provider.dart
│   │
│   ├── messaging/                    # Chat/DM feature
│   │   ├── data/
│   │   │   ├── datasources/
│   │   │   │   ├── message_remote_datasource.dart
│   │   │   │   ├── message_local_datasource.dart
│   │   │   │   └── signal_protocol_datasource.dart
│   │   │   ├── models/
│   │   │   │   ├── message_model.dart
│   │   │   │   └── conversation_model.dart
│   │   │   └── repositories/
│   │   │       └── message_repository_impl.dart
│   │   ├── domain/
│   │   │   ├── entities/
│   │   │   │   ├── message.dart
│   │   │   │   └── conversation.dart
│   │   │   ├── repositories/
│   │   │   │   └── message_repository.dart
│   │   │   └── usecases/
│   │   │       ├── send_message.dart
│   │   │       ├── encrypt_message.dart
│   │   │       ├── decrypt_message.dart
│   │   │       └── load_conversation.dart
│   │   └── presentation/
│   │       ├── pages/
│   │       │   ├── conversations_page.dart
│   │       │   └── chat_page.dart
│   │       ├── widgets/
│   │       │   ├── message_bubble.dart
│   │       │   ├── message_input.dart
│   │       │   └── conversation_list_tile.dart
│   │       └── providers/
│   │           ├── message_provider.dart
│   │           └── conversation_provider.dart
│   │
│   ├── channels/                     # Group channels feature
│   │   ├── data/
│   │   │   ├── datasources/
│   │   │   ├── models/
│   │   │   └── repositories/
│   │   ├── domain/
│   │   │   ├── entities/
│   │   │   ├── repositories/
│   │   │   └── usecases/
│   │   └── presentation/
│   │       ├── pages/
│   │       ├── widgets/
│   │       └── providers/
│   │
│   ├── video_conferencing/           # Video calls feature
│   │   ├── data/
│   │   │   ├── datasources/
│   │   │   │   ├── livekit_datasource.dart
│   │   │   │   └── ice_server_datasource.dart
│   │   │   ├── models/
│   │   │   │   ├── participant_model.dart
│   │   │   │   └── video_settings_model.dart
│   │   │   └── repositories/
│   │   │       └── video_conference_repository_impl.dart
│   │   ├── domain/
│   │   │   ├── entities/
│   │   │   │   ├── participant.dart
│   │   │   │   └── video_session.dart
│   │   │   ├── repositories/
│   │   │   │   └── video_conference_repository.dart
│   │   │   └── usecases/
│   │   │       ├── join_conference.dart
│   │   │       ├── toggle_camera.dart
│   │   │       ├── toggle_microphone.dart
│   │   │       └── share_screen.dart
│   │   └── presentation/
│   │       ├── pages/
│   │       │   ├── video_conference_page.dart
│   │       │   ├── prejoin_page.dart
│   │       │   └── meeting_page.dart
│   │       ├── widgets/
│   │       │   ├── video_participant_tile.dart
│   │       │   ├── video_controls_bar.dart
│   │       │   └── video_grid_layout.dart
│   │       └── providers/
│   │           └── video_conference_provider.dart
│   │
│   ├── meetings/                     # Scheduled meetings feature
│   │   ├── data/
│   │   ├── domain/
│   │   └── presentation/
│   │
│   ├── file_transfer/                # File sharing feature
│   │   ├── data/
│   │   ├── domain/
│   │   └── presentation/
│   │
│   ├── user_profile/                 # User profile feature
│   │   ├── data/
│   │   ├── domain/
│   │   └── presentation/
│   │
│   ├── encryption/                   # E2EE feature (cross-cutting)
│   │   ├── data/
│   │   │   ├── datasources/
│   │   │   │   ├── signal_protocol_datasource.dart
│   │   │   │   ├── key_store_datasource.dart
│   │   │   │   └── session_store_datasource.dart
│   │   │   ├── models/
│   │   │   └── repositories/
│   │   ├── domain/
│   │   │   ├── entities/
│   │   │   ├── repositories/
│   │   │   └── usecases/
│   │   │       ├── encrypt_message.dart
│   │   │       ├── decrypt_message.dart
│   │   │       ├── generate_keys.dart
│   │   │       └── exchange_keys.dart
│   │   └── presentation/
│   │
│   └── settings/                     # Settings feature
│       ├── data/
│       ├── domain/
│       └── presentation/
│
└── shared/                          # Shared UI components
    ├── widgets/
    │   ├── buttons/
    │   ├── dialogs/
    │   ├── inputs/
    │   └── loading/
    └── layouts/
        ├── app_layout.dart
        └── responsive_layout.dart
```

---

## Module Map (Current → Target)

This section maps the current layout into a **feature-first module structure** that is consistent with Flutter’s reactive architecture (pure `build()`, state-driven UI) and Google/Dart conventions.

### Module rules (high-value repo standard)

- Each module owns its **UI + state + domain + data**.
- Modules expose a small public API (ideally via a single entrypoint file like `features/<feature>/<feature>.dart`).
- Dependencies flow inward: `presentation → domain → data → core`.
- Cross-cutting concerns live in `core/` (or in internal packages) and are consumed via interfaces.

### App shell (composition root)

**Target module:** `app_shell/` (or keep `app/` but make it strictly shell)

**Owns:** routing, DI composition, top-level navigation layout, global providers.

**Current sources (examples):**
- `lib/main.dart`
- `lib/app/app_layout.dart`
- `lib/providers/navigation_state_provider.dart`
- Navigation UI in `lib/widgets/navigation_sidebar.dart`, `lib/widgets/desktop_navigation_drawer.dart`

**Target:** `lib/app_shell/presentation/*` + `lib/core/di/*`

---

### authentication

**Target:** `lib/features/authentication/{presentation,domain,data}`

**Owns:** login/register/OTP/webauthn, session lifecycle, token storage.

**Current sources (examples):**
- `lib/auth/*`
- `lib/services/auth_service_web.dart`, `lib/services/auth_service_native.dart`
- `lib/services/session_auth_service.dart`, `lib/services/logout_service.dart`
- `lib/services/webauthn_service.dart`

**Notes:**
- Keep conditional imports behind a single interface in `data/` (e.g., `AuthPlatformDataSource`).

---

### user_profile (people)

**Target:** `lib/features/user_profile/{presentation,domain,data}`

**Owns:** profiles, avatars, presence display, profile caching.

**Current sources (examples):**
- `lib/services/user_profile_service.dart`
- `lib/widgets/user_avatar.dart`, `lib/widgets/participant_profile_display.dart`
- `lib/screens/people/*`

---

### messaging (1:1 + message list UI)

**Target:** `lib/features/messaging/{presentation,domain,data}`

**Owns:** conversations, messages, send/edit/delete, local caching/queues.

**Current sources (examples):**
- `lib/screens/messages/*`
- `lib/widgets/message_list.dart`, `lib/widgets/enhanced_message_input.dart`
- `lib/services/offline_message_queue.dart`, `lib/services/recent_conversations_service.dart`
- Message stores currently in `lib/services/*store*.dart` and `lib/services/storage/*`

**Notes:**
- Split “message crypto” from “message UI”: crypto belongs to `encryption` module/package.

---

### channels (group channels + channel messaging)

**Target:** `lib/features/channels/{presentation,domain,data}`

**Owns:** channel list, channel settings, members, channel-scoped message flows.

**Current sources (examples):**
- `lib/screens/channel/*`
- `lib/widgets/channels_context_panel.dart`
- `lib/services/starred_channels_service.dart`

---

### meetings

**Target:** `lib/features/meetings/{presentation,domain,data}`

**Owns:** meeting scheduling/list, RSVP, meeting authorization, admission/waiting room.

**Current sources (examples):**
- `lib/screens/meetings_screen.dart`, `lib/screens/meeting_rsvp_confirmation_screen.dart`
- `lib/services/meeting_service.dart`, `lib/services/meeting_authorization_service.dart`
- `lib/widgets/admission_overlay.dart`

---

### video_conferencing (LiveKit calling UI + state)

**Target:** `lib/features/video_conferencing/{presentation,domain,data}`

**Owns:** call prejoin, in-call UI, participant grid, audio/video toggles, screen share UX.

**Current sources (examples):**
- Views: `lib/views/video_conference_view.dart`, `lib/views/video_conference_prejoin_view.dart`
- Meeting call views: `lib/views/meeting_prejoin_view.dart`, `lib/views/meeting_video_conference_view.dart`
- Widgets: `lib/widgets/video_grid_layout.dart`, `lib/widgets/video_controls_bar.dart`, `lib/widgets/video_participant_tile.dart`
- Services: `lib/services/video_conference_service.dart`, `lib/services/video_quality_manager.dart`

**Notes:**
- In target architecture, `video_conference_service.dart` becomes a set of smaller units:
  - `LiveKitDataSource` (data)
  - `VideoConferenceRepository` (domain interface)
  - `JoinConference/ToggleCamera/...` (domain use cases)
  - `VideoConferenceController/ViewModel` (presentation state)

---

### file_transfer

**Target:** `lib/features/file_transfer/{presentation,domain,data}`

**Owns:** file selection/upload/download, transfer sessions, transfer UI.

**Current sources (examples):**
- `lib/services/file_transfer/*`
- `lib/screens/file_transfer/*`
- `lib/providers/file_transfer_stats_provider.dart`
- `lib/widgets/file_message_widget.dart`, `lib/widgets/partial_download_dialog.dart`

---

### activities

**Target:** `lib/features/activities/{presentation,domain,data}`

**Owns:** activity feed, call/missed-call entries, admin activities.

**Current sources (examples):**
- `lib/screens/activities/*`
- `lib/services/activities_service.dart`

---

### notifications

**Target:** `lib/features/notifications/{presentation,domain,data}`

**Owns:** in-app notifications, notification preferences, listeners.

**Current sources (examples):**
- `lib/services/notification_service.dart`, `lib/services/notification_listener_service.dart`
- `lib/services/user_notification_settings_service.dart`
- `lib/providers/notification_provider.dart`
- `lib/widgets/incoming_call_notification.dart`, `lib/widgets/update_notification_banner.dart`

---

### admin (roles + user management)

**Target:** `lib/features/admin/{presentation,domain,data}`

**Owns:** role management, user management, privileged screens.

**Current sources (examples):**
- `lib/screens/admin/*`
- `lib/providers/role_provider.dart`
- `lib/services/role_api_service.dart`, `lib/services/user_management_service.dart`
- Models: `lib/models/role.dart`, `lib/models/user_roles.dart`

---

### encryption (cross-cutting, high-risk)

**Target:** prefer **internal package** first, then feature module if needed.

**Suggested internal package:** `packages/peerwave_encryption/`

**Owns:** Signal Protocol stores, sender keys, crypto primitives, E2EE orchestration.

**Current sources (examples):**
- `lib/services/e2ee_crypto_service.dart`, `lib/services/e2ee_service.dart`
- `lib/services/signal_service.dart`, `lib/services/sender_key_store.dart`
- `lib/services/permanent_*_store.dart`
- `lib/services/native_crypto_service.dart`, `lib/services/windows_e2ee_manager.dart`

**Notes:**
- Encryption should be “edge-controlled”: callers request operations via use cases; UI never touches key stores directly.

---

### realtime (socket + signaling)

**Suggested internal package:** `packages/peerwave_realtime/`

**Owns:** socket lifecycle, event bus abstractions, LiveKit/meeting signaling glue.

**Current sources (examples):**
- `lib/services/socket_service.dart`, `lib/services/socket_service_native.dart`, `lib/services/external_guest_socket_service.dart`
- `lib/services/event_bus.dart`
- Meeting signaling callbacks currently tied to video services

---

### core (shared infrastructure)

**Target:** `lib/core/*` (and optional `packages/peerwave_core/`)

**Owns:** API client, server config, storage primitives, device identity, preferences, shared error types.

**Current sources (examples):**
- `lib/services/api_service.dart`, `lib/services/server_connection_service.dart`
- `lib/services/server_config_web.dart`, `lib/services/server_config_native.dart`
- `lib/services/preferences_service.dart`, `lib/services/device_identity_service.dart`, `lib/services/clientid_*`
- `lib/core/storage/*`

---

## Suggested internal package extraction order

To get “high-value module repository” boundaries without a big-bang refactor:

1. `peerwave_encryption` (highest risk, most cross-cutting)
2. `peerwave_storage` (secure/local stores + migrations)
3. `peerwave_realtime` (socket/signal/eventing)
4. `peerwave_video` (LiveKit integration glue; keep UI in the app)

Each package should have:

- A small public API surface (exports)
- Strict dependency rules (no importing app UI)
- Independent unit tests

---

### **Phase 2: Implement Repository Pattern (Priority: HIGH)**

**Before (Current):**
```dart
// Service directly accesses API
class UserProfileService {
  Future<Map<String, dynamic>> getProfile(String userId) async {
    final response = await ApiService.get('/people/profiles');
    return response.data;
  }
}

// UI directly depends on service
class ProfilePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final profile = await UserProfileService.instance.getProfile(userId);
    return Text(profile['displayName']);
  }
}
```

**After (Clean Architecture):**
```dart
// 1. Domain Layer - Entity (Pure Dart, no Flutter)
class UserProfile {
  final String id;
  final String displayName;
  final String? profilePicture;
  
  UserProfile({
    required this.id,
    required this.displayName,
    this.profilePicture,
  });
}

// 2. Domain Layer - Repository Interface
abstract class UserProfileRepository {
  Future<Either<Failure, UserProfile>> getProfile(String userId);
  Future<Either<Failure, void>> updateProfile(UserProfile profile);
}

// 3. Domain Layer - Use Case
class GetUserProfile {
  final UserProfileRepository repository;
  
  GetUserProfile(this.repository);
  
  Future<Either<Failure, UserProfile>> call(String userId) {
    return repository.getProfile(userId);
  }
}

// 4. Data Layer - Model (with JSON serialization)
class UserProfileModel extends UserProfile {
  UserProfileModel({
    required String id,
    required String displayName,
    String? profilePicture,
  }) : super(id: id, displayName: displayName, profilePicture: profilePicture);
  
  factory UserProfileModel.fromJson(Map<String, dynamic> json) {
    return UserProfileModel(
      id: json['id'],
      displayName: json['displayName'],
      profilePicture: json['picture'],
    );
  }
  
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'displayName': displayName,
      'picture': profilePicture,
    };
  }
}

// 5. Data Layer - Remote Data Source
abstract class UserProfileRemoteDataSource {
  Future<UserProfileModel> getProfile(String userId);
}

class UserProfileRemoteDataSourceImpl implements UserProfileRemoteDataSource {
  final ApiClient apiClient;
  
  UserProfileRemoteDataSourceImpl(this.apiClient);
  
  @override
  Future<UserProfileModel> getProfile(String userId) async {
    final response = await apiClient.get('/people/profiles?uuids=$userId');
    if (response.statusCode == 200) {
      return UserProfileModel.fromJson(response.data[0]);
    } else {
      throw ServerException();
    }
  }
}

// 6. Data Layer - Repository Implementation
class UserProfileRepositoryImpl implements UserProfileRepository {
  final UserProfileRemoteDataSource remoteDataSource;
  final UserProfileLocalDataSource localDataSource;
  final NetworkInfo networkInfo;
  
  UserProfileRepositoryImpl({
    required this.remoteDataSource,
    required this.localDataSource,
    required this.networkInfo,
  });
  
  @override
  Future<Either<Failure, UserProfile>> getProfile(String userId) async {
    if (await networkInfo.isConnected) {
      try {
        final profile = await remoteDataSource.getProfile(userId);
        await localDataSource.cacheProfile(profile);
        return Right(profile);
      } on ServerException {
        return Left(ServerFailure());
      }
    } else {
      try {
        final cachedProfile = await localDataSource.getCachedProfile(userId);
        return Right(cachedProfile);
      } on CacheException {
        return Left(CacheFailure());
      }
    }
  }
}

// 7. Presentation Layer - Provider/ViewModel
class UserProfileProvider extends ChangeNotifier {
  final GetUserProfile getUserProfile;
  
  UserProfile? _profile;
  bool _isLoading = false;
  String? _errorMessage;
  
  UserProfile? get profile => _profile;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  
  UserProfileProvider({required this.getUserProfile});
  
  Future<void> loadProfile(String userId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    
    final result = await getUserProfile(userId);
    
    result.fold(
      (failure) {
        _errorMessage = _mapFailureToMessage(failure);
        _isLoading = false;
        notifyListeners();
      },
      (profile) {
        _profile = profile;
        _isLoading = false;
        notifyListeners();
      },
    );
  }
  
  String _mapFailureToMessage(Failure failure) {
    if (failure is ServerFailure) return 'Server error';
    if (failure is CacheFailure) return 'No cached data';
    return 'Unexpected error';
  }
}

// 8. Presentation Layer - UI
class ProfilePage extends StatelessWidget {
  final String userId;
  
  const ProfilePage({required this.userId});
  
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => getIt<UserProfileProvider>()..loadProfile(userId),
      child: Consumer<UserProfileProvider>(
        builder: (context, provider, _) {
          if (provider.isLoading) {
            return CircularProgressIndicator();
          }
          
          if (provider.errorMessage != null) {
            return Text('Error: ${provider.errorMessage}');
          }
          
          final profile = provider.profile;
          if (profile == null) {
            return Text('No profile data');
          }
          
          return Column(
            children: [
              Text(profile.displayName),
              if (profile.profilePicture != null)
                Image.network(profile.profilePicture!),
            ],
          );
        },
      ),
    );
  }
}
```

**Benefits:**
- ✅ Testable business logic (UseCases are pure Dart)
- ✅ Platform-independent domain layer
- ✅ Easy to mock dependencies
- ✅ Clear separation of concerns
- ✅ Offline-first capability built-in

---

### **Phase 3: Dependency Injection (Priority: HIGH)**

Use `get_it` for dependency injection:

```dart
// core/di/injection_container.dart
final getIt = GetIt.instance;

Future<void> init() async {
  // Features - Authentication
  getIt.registerFactory(() => LoginUser(getIt()));
  getIt.registerFactory(() => LogoutUser(getIt()));
  
  getIt.registerLazySingleton<AuthRepository>(
    () => AuthRepositoryImpl(
      remoteDataSource: getIt(),
      localDataSource: getIt(),
      networkInfo: getIt(),
    ),
  );
  
  getIt.registerLazySingleton<AuthRemoteDataSource>(
    () => AuthRemoteDataSourceImpl(getIt()),
  );
  
  // Core
  getIt.registerLazySingleton(() => ApiClient());
  getIt.registerLazySingleton<NetworkInfo>(() => NetworkInfoImpl());
  
  // External
  final sharedPreferences = await SharedPreferences.getInstance();
  getIt.registerLazySingleton(() => sharedPreferences);
}

// main.dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await init(); // Initialize DI
  runApp(MyApp());
}
```

---

### **Phase 4: State Management Consistency (Priority: MEDIUM)**

**Current:** Mixed Provider usage (some with ChangeNotifier, some direct service calls)

**Recommendation:** Standardize on one of:

1. **Provider + ChangeNotifier** (current, keep if team is comfortable)
2. **Riverpod** (modern, better than Provider)
3. **Bloc/Cubit** (more structured, testable)

**For PeerWave's complexity, recommend:**
- **Riverpod** for new code (better dependency injection, compile-time safety)
- Gradually migrate from Provider

**Example with Riverpod:**
```dart
// Domain layer
final getUserProfileProvider = Provider<GetUserProfile>((ref) {
  return GetUserProfile(ref.read(userProfileRepositoryProvider));
});

// State provider
final userProfileProvider = StateNotifierProvider.autoDispose
    .family<UserProfileNotifier, AsyncValue<UserProfile>, String>(
  (ref, userId) {
    return UserProfileNotifier(
      getUserProfile: ref.read(getUserProfileProvider),
      userId: userId,
    );
  },
);

// Notifier
class UserProfileNotifier extends StateNotifier<AsyncValue<UserProfile>> {
  final GetUserProfile getUserProfile;
  final String userId;
  
  UserProfileNotifier({
    required this.getUserProfile,
    required this.userId,
  }) : super(const AsyncValue.loading()) {
    _loadProfile();
  }
  
  Future<void> _loadProfile() async {
    final result = await getUserProfile(userId);
    result.fold(
      (failure) => state = AsyncValue.error(failure, StackTrace.current),
      (profile) => state = AsyncValue.data(profile),
    );
  }
}

// UI
class ProfilePage extends ConsumerWidget {
  final String userId;
  
  const ProfilePage({required this.userId});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileState = ref.watch(userProfileProvider(userId));
    
    return profileState.when(
      data: (profile) => Text(profile.displayName),
      loading: () => CircularProgressIndicator(),
      error: (error, _) => Text('Error: $error'),
    );
  }
}
```

---

## Migration Strategy

### **Phased Approach (18-24 weeks)**

#### **Phase 1: Foundation (Weeks 1-4)**
- [ ] Set up feature-first directory structure
- [ ] Create core infrastructure layer
- [ ] Implement dependency injection with get_it
- [ ] Define architectural guidelines document
- [ ] Create code generation templates

#### **Phase 2: Pilot Feature Migration (Weeks 5-8)**
- [ ] Choose one feature (e.g., User Profile) as pilot
- [ ] Migrate to Clean Architecture pattern
- [ ] Write comprehensive tests
- [ ] Document learnings and adjust approach
- [ ] Create migration checklist for other features

#### **Phase 3: Critical Features (Weeks 9-16)**
- [ ] Migrate Authentication feature
- [ ] Migrate Messaging feature
- [ ] Migrate Video Conferencing feature
- [ ] Migrate Channels feature

#### **Phase 4: Remaining Features (Weeks 17-22)**
- [ ] Migrate Meetings feature
- [ ] Migrate File Transfer feature
- [ ] Migrate Settings feature

#### **Phase 5: Cleanup & Optimization (Weeks 23-24)**
- [ ] Remove old architecture code
- [ ] Consolidate duplicate code
- [ ] Performance optimization
- [ ] Final documentation update

---

## Testing Strategy

### **Current State:** Limited test coverage evident

### **Target State:**
```
lib/
└── features/
    └── authentication/
        ├── data/
        ├── domain/
        ├── presentation/
        └── test/  ❌ Tests should be in test/ directory at root

test/
└── features/
    └── authentication/
        ├── data/
        │   ├── datasources/
        │   │   └── auth_remote_datasource_test.dart
        │   ├── models/
        │   │   └── user_model_test.dart
        │   └── repositories/
        │       └── auth_repository_impl_test.dart
        ├── domain/
        │   └── usecases/
        │       ├── login_user_test.dart
        │       └── logout_user_test.dart
        └── presentation/
            └── providers/
                └── auth_provider_test.dart
```

**Testing Pyramid:**
- **70% Unit Tests** (UseCases, Repositories, Models)
- **20% Widget Tests** (UI components)
- **10% Integration Tests** (E2E flows)

**Target Coverage:** 80%+

---

## Naming Conventions Audit

### ✅ **Currently Correct:**
- File names: `user_profile_service.dart` (snake_case ✓)
- Class names: `UserProfileService` (PascalCase ✓)
- Variables: `isLoading`, `profilePicture` (camelCase ✓)

### 🔧 **Improvements Needed:**

1. **Consolidate naming terminology:**
   - Current: `page`, `screen`, `view` used interchangeably
   - Recommendation: Use `page` only (e.g., `login_page.dart`)

2. **Service suffix overuse:**
   - Current: `UserProfileService`, `AuthService`, `MeetingService`
   - Better: Use specific names based on layer:
     - **Repository:** `UserProfileRepository`
     - **UseCase:** `GetUserProfile`, `UpdateUserProfile`
     - **DataSource:** `AuthRemoteDataSource`

3. **Model naming:**
   - Current: Mixed `Model` suffix usage
   - Recommendation: 
     - **Entity** (domain): `UserProfile`
     - **Model** (data): `UserProfileModel`
     - **DTO**: `UserProfileDto` (if needed for API contracts)

---

## Code Quality Recommendations

### **1. Reduce God Objects**

**Current Example:**
```dart
// video_conference_service.dart is 2156 lines! ❌
class VideoConferenceService {
  // Too many responsibilities:
  - WebRTC connection management
  - E2EE handling
  - UI state management
  - Audio processing
  - Video quality management
  - Participant management
  - Screen sharing
  - LiveKit API calls
}
```

**Recommended Refactoring:**
```dart
// Split into multiple single-responsibility classes

// Domain Use Cases
class JoinVideoConference { }
class LeaveVideoConference { }
class ToggleCamera { }
class ToggleMicrophone { }
class ShareScreen { }

// Data Repositories
class LiveKitRepository { }
class WebRTCRepository { }

// Services (infrastructure)
class E2EEEncryptionService { }
class AudioProcessingService { }
class VideoQualityService { }

// Presentation State
class VideoConferenceProvider { }
```

### **2. Extract Configuration**

Move hardcoded values to configuration files:

```dart
// core/config/video_config.dart
class VideoConfig {
  static const String defaultVideoQuality = '720p';
  static const int maxParticipants = 50;
  static const Duration connectionTimeout = Duration(seconds: 30);
  
  static const List<String> supportedCodecs = ['VP8', 'VP9', 'H264'];
}

// core/config/api_config.dart
class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:3000',
  );
  
  static const Duration requestTimeout = Duration(seconds: 30);
}
```

### **3. Improve Error Handling**

**Current:** Mixed error handling approaches

**Recommended:**
```dart
// core/error/failures.dart
abstract class Failure {
  final String message;
  const Failure(this.message);
}

class ServerFailure extends Failure {
  const ServerFailure([String message = 'Server error']) : super(message);
}

class NetworkFailure extends Failure {
  const NetworkFailure([String message = 'Network error']) : super(message);
}

class CacheFailure extends Failure {
  const CacheFailure([String message = 'Cache error']) : super(message);
}

class E2EEFailure extends Failure {
  const E2EEFailure([String message = 'Encryption error']) : super(message);
}

// core/error/exceptions.dart
class ServerException implements Exception {}
class CacheException implements Exception {}
class NetworkException implements Exception {}
```

### **4. Add Documentation**

Follow Effective Dart documentation guidelines:

```dart
/// Manages user authentication state and operations.
///
/// This repository handles login, logout, registration, and session
/// management. It coordinates between remote and local data sources
/// to provide offline-first capabilities.
///
/// Example:
/// ```dart
/// final authRepo = getIt<AuthRepository>();
/// final result = await authRepo.login(email, password);
/// result.fold(
///   (failure) => print('Login failed: ${failure.message}'),
///   (user) => print('Logged in: ${user.displayName}'),
/// );
/// ```
abstract class AuthRepository {
  /// Attempts to log in a user with [email] and [password].
  ///
  /// Returns [Right<User>] on success, [Left<Failure>] on error.
  Future<Either<Failure, User>> login({
    required String email,
    required String password,
  });
}
```

---

## Performance Considerations

### **1. Widget Rebuilds**
- Use `const` constructors wherever possible
- Implement `Selector` for Provider to prevent unnecessary rebuilds
- Extract expensive widgets to separate classes

### **2. Memory Management**
- Dispose controllers, streams, and notifiers properly
- Use `AutoDispose` variants with Riverpod
- Profile memory usage in video conferencing features

### **3. Build Optimization**
- Lazy load features (deferred imports for large features)
- Use code splitting for web builds
- Optimize image loading and caching

---

## Comparison with Industry Standards

### **Google Flutter Projects:**
- ✅ Flutter Gallery: Uses feature-first organization
- ✅ Flutter Samples: Clean separation of concerns
- ✅ Firebase Flutter: Repository pattern throughout

### **Enterprise Flutter Apps:**
- ✅ Reflectly: Clean Architecture + BLoC
- ✅ Alibaba (Xianyu): Feature modules with clear boundaries
- ✅ Nubank: Domain-driven design with hexagonal architecture

**PeerWave Gap Analysis:**
- Missing: Clear architectural layers
- Missing: Consistent use of repository pattern
- Missing: Comprehensive test coverage
- Missing: Dependency injection framework
- Present: Good widget composition ✓
- Present: Proper use of Provider ✓

---

## Security Architecture Review

### ✅ **Strengths:**
- Signal Protocol implementation (E2EE)
- Secure storage for keys
- Platform-specific secure storage

### 🔧 **Improvements:**
- Centralize all encryption logic in `features/encryption/`
- Create audit logging for key operations
- Implement key rotation strategy in use cases
- Add security tests for critical paths

---

## Actionable Checklist

### **Immediate Actions (This Sprint)**
- [ ] Create `ARCHITECTURE_GUIDELINES.md` document
- [ ] Set up `get_it` dependency injection
- [ ] Rename `pages/` → delete, move to appropriate `features/*/presentation/pages/`
- [ ] Rename `screens/` → move to appropriate `features/*/presentation/pages/`
- [ ] Rename `views/` → move to `features/video_conferencing/presentation/pages/`

### **Short Term (Next 2 Sprints)**
- [ ] Migrate User Profile feature to Clean Architecture
- [ ] Implement repository pattern for one feature
- [ ] Set up test structure and achieve 30% coverage
- [ ] Extract video_conference_service.dart responsibilities

### **Medium Term (Next Quarter)**
- [ ] Migrate all core features to feature-first structure
- [ ] Achieve 70% test coverage
- [ ] Implement comprehensive error handling
- [ ] Add code generation for boilerplate (freezed, json_serializable)

### **Long Term (Next 6 Months)**
- [ ] Complete architecture migration
- [ ] Achieve 85% test coverage
- [ ] Implement CI/CD with architecture compliance checks
- [ ] Create developer onboarding guide based on new architecture

---

## Conclusion

PeerWave has a **solid technical foundation** with excellent E2EE implementation and cross-platform support. However, the current architecture hinders scalability and maintainability. By adopting **Clean Architecture with feature-first organization**, the codebase will become:

- ✅ **Easier to navigate** (features are self-contained)
- ✅ **More testable** (clear dependency boundaries)
- ✅ **Easier to onboard** (consistent patterns)
- ✅ **More maintainable** (single responsibility classes)
- ✅ **Better scalability** (add features without affecting others)

**Recommended Priority:** **HIGH**  
**Estimated Effort:** **18-24 weeks** with 2-3 developers  
**ROI:** Significant reduction in technical debt, improved development velocity after migration

---

## References

### Flutter Official Documentation
1. [Flutter architectural overview](https://docs.flutter.dev/resources/architectural-overview) - Core concepts: layers, widgets, rendering
2. [Architecting Flutter apps](https://docs.flutter.dev/app-architecture) - App architecture patterns
3. [Inside Flutter](https://docs.flutter.dev/resources/inside-flutter) - Framework design philosophy
4. [Understanding constraints](https://docs.flutter.dev/ui/layout/constraints) - Layout system deep dive
5. [Flutter performance best practices](https://docs.flutter.dev/perf/best-practices) - Optimization guidelines
6. [Web renderers](https://docs.flutter.dev/platform-integration/web/renderers) - CanvasKit vs Skwasm

### Dart & Code Quality
7. [Effective Dart](https://dart.dev/guides/language/effective-dart) - Style, documentation, usage, design
8. [Google Flutter repo style guide](https://github.com/flutter/flutter/wiki/Style-guide-for-Flutter-repo)
9. [Dart language tour](https://dart.dev/language) - Language fundamentals

### Architecture Patterns
10. [Flutter Architecture Samples](https://github.com/brianegan/flutter_architecture_samples) - Multiple patterns compared
11. [Uncle Bob's Clean Architecture](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
12. [Domain-Driven Design (DDD)](https://martinfowler.com/bliki/DomainDrivenDesign.html)
13. [Flutter Clean Architecture (TDD) example](https://resocoder.com/flutter-clean-architecture-tdd/)

### State Management
14. [Provider package](https://pub.dev/packages/provider) - Current state management
15. [Riverpod documentation](https://riverpod.dev/) - Recommended migration target
16. [Flutter Bloc](https://bloclibrary.dev/) - Alternative pattern

### Platform Integration
17. [Writing custom platform-specific code](https://docs.flutter.dev/platform-integration/platform-channels)
18. [Dart FFI](https://dart.dev/interop/c-interop) - Native code integration
19. [Add Flutter to existing app](https://docs.flutter.dev/add-to-app) - Embedding patterns

---

**Review Status:** DRAFT  
**Last Updated:** December 22, 2025  
**Next Review Date:** Q2 2026 (Post-Migration Phase 1)  
**Document Maintainer:** Architecture Team
