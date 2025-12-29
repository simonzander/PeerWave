# PeerWave Architecture Guidelines

**Quick Start for Contributors** | **Last Updated:** December 23, 2025

---

## Quick Reference: Where Does My Code Go?

| What are you building? | Where does it go? |
|------------------------|-------------------|
| New feature (auth, settings, etc.) | `features/<name>/` with `pages/`, `widgets/`, `state/`, `models/` |
| Feature-specific widget | `features/<feature>/widgets/` |
| Reusable button/card/modal | `widgets/<category>/` (buttons, cards, modals, etc.) |
| Feature state management | `features/<feature>/state/<feature>_provider.dart` |
| Cross-feature state (theme, etc.) | `providers/<name>_provider.dart` |
| Business logic (2+ features use it) | `services/<domain>/` (messaging, video, auth, storage) |
| Feature-specific model | `features/<feature>/models/` |
| Shared model (User, Message, etc.) | `core/<domain>/models/` |
| Utilities | `core/utils/` |

---

## The Architecture in 30 Seconds

**PeerWave uses pragmatic, Flutter-idiomatic architecture:**

```
UI → State (Provider) → Services → Platform/Network
```

**Default for most features: Keep it simple and cohesive**
- Feature folder with pages, widgets, state, models
- State management with Provider/ChangeNotifier
- Services for business logic and data access

**Use Clean Architecture only when you need:**
- Security-critical features (crypto, auth)
- Multiple implementations (web vs native, mock vs real)
- Complex testability requirements

**Key Rule:** Dependencies flow one way → UI depends on state, state depends on services, service depends on platform

---

## Directory Structure

### Overview
```
lib/
 main.dart
 features/           # Feature modules (grouped by domain)
    authentication/
    messaging/
    video_conferencing/
    <feature>/
        pages/      # Full-screen UIs
        widgets/    # Feature-specific widgets
        state/      # Providers/controllers
        models/     # Feature models
 services/           # Business logic (grouped by domain)
    messaging/
    video/
    auth/
    storage/
 core/              # Shared infrastructure
    config/
    error/
    network/
    models/        # Shared models (User, Message, etc.)
 providers/         # Cross-feature state
 widgets/           # Reusable components (modals, buttons, cards, etc.)
 utils/             # Utilities
```

### Feature Template

Most features should use this flat structure:

```
features/<feature_name>/
 pages/             # Full screens
    <feature>_page.dart
 widgets/           # Feature-specific widgets
    <widget>_card.dart
    <widget>_list.dart
 state/             # State management
    <feature>_provider.dart
 models/            # Feature models
     <feature>_model.dart
```

**When to add more:**
- Logic used by 2+ features → move to `services/<domain>/`
- Models used across features → move to `core/<domain>/models/`
- Reusable widgets → move to `widgets/<category>/`

---

## Core Principles

1. **Feature Cohesion:** Keep related code together (UI, state, logic in same feature folder)
2. **Simple by Default:** Don't over-engineer. Add layers only when complexity justifies it
3. **One-Way Dependencies:** UI → State → Services → Platform
4. **Practical Testability:** Test critical logic (crypto, parsing, state). Don't test everything
5. **No God Objects:** Target <300 lines per file

---

## Naming Conventions

### Files & Classes

| Type | Convention | Example |
|------|------------|---------|
| Dart files | `snake_case.dart` | `user_profile_page.dart` |
| Classes | `PascalCase` | `UserProfilePage` |
| Variables | `camelCase` | `isLoading` |
| Private | `_camelCase` | `_userId` |
| Constants | `camelCase` | `maxRetries` |

### Consistent Terminology

Use these terms consistently across the codebase:

- **Page:** Full-screen UI (`login_page.dart`)
- **Widget:** UI component (`user_avatar_widget.dart`)
- **Provider:** State management (`profile_provider.dart`)
- **Service:** Business logic (`auth_service.dart`)
- **Model:** Data structure (`user_model.dart`)

---

## State Management Pattern

### Provider + ChangeNotifier (Current Standard)

```dart
// State Provider
class ProfileProvider extends ChangeNotifier {
  final ProfileService _service;
  
  ProfileState _state = ProfileState.initial();
  ProfileState get state => _state;
  
  Future<void> loadProfile(String userId) async {
    _state = _state.copyWith(isLoading: true);
    notifyListeners();
    
    try {
      final profile = await _service.getProfile(userId);
      _state = _state.copyWith(profile: profile, isLoading: false);
    } catch (e) {
      _state = _state.copyWith(error: e.toString(), isLoading: false);
    }
    notifyListeners();
  }
}

// UI Usage
Consumer<ProfileProvider>(
  builder: (context, provider, _) {
    if (provider.state.isLoading) return LoadingWidget();
    if (provider.state.error != null) return ErrorWidget(provider.state.error);
    return ProfileView(profile: provider.state.profile);
  },
)
```

**Best Practices:**
- Keep providers focused (one responsibility)
- Use `Selector` for granular rebuilds
- Dispose resources properly
- Handle errors explicitly

---

## Error Handling

### Simple Pattern (Most Cases)

```dart
try {
  final result = await service.doSomething();
  // handle success
} catch (e) {
  // handle error, show to user
  _error = e.toString();
  notifyListeners();
}
```

### Either Pattern (Complex Cases)

For features needing explicit error types (auth, crypto, critical flows):

```dart
// Define failures
abstract class Failure {
  final String message;
  const Failure(this.message);
}

class NetworkFailure extends Failure {
  const NetworkFailure() : super('No internet connection');
}

// Use in service
Future<Either<Failure, User>> login(String email, String password) async {
  try {
    final user = await _api.login(email, password);
    return Right(user);
  } on SocketException {
    return Left(NetworkFailure());
  }
}

// Handle in provider
final result = await _service.login(email, password);
result.fold(
  (failure) => _state = _state.copyWith(error: failure.message),
  (user) => _state = _state.copyWith(user: user),
);
```

---

## Code Organization

### Import Order

```dart
// 1. Dart SDK
import 'dart:async';

// 2. Flutter
import 'package:flutter/material.dart';

// 3. Packages (alphabetical)
import 'package:provider/provider.dart';

// 4. Project imports (alphabetical)
import 'package:peerwave/core/error/failures.dart';
import 'package:peerwave/features/auth/state/auth_provider.dart';

// 5. Relative imports (same feature only)
import '../models/profile.dart';
```

### Class Structure

```dart
class Example {
  // 1. Static constants
  static const defaultValue = 'default';
  
  // 2. Instance fields
  final String id;
  
  // 3. Constructor
  Example({required this.id});
  
  // 4. Getters
  String get displayId => id.toUpperCase();
  
  // 5. Public methods
  void publicMethod() {}
  
  // 6. Private methods
  void _privateMethod() {}
  
  // 7. Overrides
  @override
  String toString() => 'Example($id)';
}
```

---

## Testing Strategy

### Test What Matters

- **Unit Tests:** Critical business logic, state management, complex calculations
- **Widget Tests:** Complex UI interactions, conditional rendering
- **Integration Tests:** Key user flows (login, sending messages, video calls)

**Don't test:**
- Simple getters/setters
- Framework code
- Third-party libraries

### Quick Example

```dart
void main() {
  late ProfileProvider provider;
  late MockProfileService mockService;
  
  setUp(() {
    mockService = MockProfileService();
    provider = ProfileProvider(mockService);
  });
  
  test('loads profile successfully', () async {
    // Arrange
    when(mockService.getProfile('123'))
        .thenAnswer((_) async => testProfile);
    
    // Act
    await provider.loadProfile('123');
    
    // Assert
    expect(provider.state.profile, equals(testProfile));
    expect(provider.state.isLoading, isFalse);
  });
}
```

---

## Migration Guide

**This is guidance for new code.** Existing code doesn't need immediate refactoring.

### When to Migrate

Migrate incrementally when you're:
- Already touching a file for a feature
- Adding significant new functionality
- Fixing bugs in hard-to-maintain code

### Migration Priorities

**1. New Features (High Priority)**
- Always use the new structure for new features
- Create `features/<name>/` with pages, widgets, state, models

**2. Consolidate Presentation (Medium Priority)**
- We have `pages/`, `screens/`, `views/`, `app/` doing the same thing
- Move feature-specific UIs to `features/<name>/pages/` when touching them
- Keep simple standalone pages in `pages/` for now

**3. Group Services (Low Priority)**
- When working on related features, group services by domain:
  - `services/messaging/` (signal, encryption, etc.)
  - `services/video/` (conference, call, audio)
  - `services/auth/` (auth, webauthn)

### Quick Checklist (Per Feature)

- [ ] Create `features/<feature>/` with subfolders
- [ ] Move pages to `features/<feature>/pages/`
- [ ] Move feature widgets to `features/<feature>/widgets/`
- [ ] Move provider to `features/<feature>/state/`
- [ ] Move models (or to `core/<domain>/models/` if shared)
- [ ] Update imports
- [ ] Test thoroughly

---

## Code Review Checklist

### Architecture
- [ ] Code is in the correct folder (`features/`, `services/`, `widgets/`)
- [ ] Dependencies flow one way (UI → State → Services)
- [ ] No business logic in UI widgets
- [ ] Features are cohesive (related code together)

### Code Quality
- [ ] Files are <300 lines
- [ ] Clear, descriptive names
- [ ] Proper error handling
- [ ] No duplicate code
- [ ] Public APIs documented

### Flutter Best Practices
- [ ] `const` constructors where possible
- [ ] No side effects in `build()`
- [ ] Keys used for dynamic lists
- [ ] Controllers/streams disposed properly
- [ ] Efficient rebuilds (Selector, const widgets)

### Testing
- [ ] Critical logic has unit tests
- [ ] Complex UI has widget tests
- [ ] No skipped tests without reason

---

## Examples from PeerWave

### Good Example: Feature Structure

```
features/troubleshoot/
 pages/
    troubleshoot_page.dart          # Main screen
 widgets/
    test_card.dart                  # Feature-specific widget
    result_display.dart
 state/
    troubleshoot_provider.dart      # State management
 models/
     test_result.dart                # Feature model
```

### Good Example: Service Structure

```
services/
 messaging/
    signal_service.dart
    message_listener.dart
    encryption_service.dart
 video/
    conference_service.dart
    audio_processor.dart
 auth/
     auth_service.dart
     webauthn_service.dart
```

---

## Additional Resources

- [Architecture Review](./ARCHITECTURE_REVIEW.md) - Detailed analysis and decisions
- [Effective Dart Style Guide](https://dart.dev/guides/language/effective-dart/style)
- [Flutter Best Practices](https://docs.flutter.dev/perf/best-practices)

---

**Questions?** Open an issue or contact the maintainers.

**Last Updated:** December 23, 2025
