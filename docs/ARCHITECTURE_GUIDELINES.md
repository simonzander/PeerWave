# PeerWave Architecture Guidelines

**Version:** 1.0  
**Last Updated:** December 22, 2025  
**Status:** Active - Phase 1 Foundation

---

## Table of Contents

1. [Overview](#overview)
2. [Core Principles](#core-principles)
3. [Directory Structure](#directory-structure)
4. [Layer Responsibilities](#layer-responsibilities)
5. [Naming Conventions](#naming-conventions)
6. [Code Organization Rules](#code-organization-rules)
7. [Dependency Management](#dependency-management)
8. [State Management](#state-management)
9. [Error Handling](#error-handling)
10. [Testing Strategy](#testing-strategy)
11. [Migration Process](#migration-process)
12. [Code Review Checklist](#code-review-checklist)

---

## Overview

PeerWave follows **Clean Architecture** with **Feature-First** organization, aligned with Flutter's architectural principles and Google coding standards.

### Architecture Pattern

```
┌─────────────────────────────────────────┐
│         Presentation Layer              │
│  (UI, Widgets, Pages, ViewModels)       │
├─────────────────────────────────────────┤
│           Domain Layer                  │
│  (Use Cases, Entities, Repositories)    │
├─────────────────────────────────────────┤
│            Data Layer                   │
│  (Repository Impl, Data Sources, DTOs)  │
└─────────────────────────────────────────┘
```

**Key Rule:** Dependencies flow **inward only** (Presentation → Domain → Data → Core)

---

## Core Principles

### 1. Feature Cohesion
- **One feature = One directory** containing all its layers
- All code related to a feature lives in `features/<feature_name>/`
- Easy to find, understand, and modify feature code

### 2. Separation of Concerns
- **Presentation:** UI and user interaction only
- **Domain:** Business logic, platform-agnostic
- **Data:** External data sources and caching

### 3. Dependency Inversion
- High-level modules don't depend on low-level modules
- Both depend on abstractions (interfaces)
- Widgets depend on ViewModels, not Services directly

### 4. Single Responsibility
- Each class has one reason to change
- No God Objects (target: <300 lines per file)
- Extract responsibilities when classes grow

### 5. Testability First
- Pure Dart domain layer (no Flutter dependencies)
- Mock-friendly interfaces
- Dependency injection for all components

---

## Directory Structure

### Target Structure

```
lib/
├── main.dart                          # Entry point (<50 lines)
├── core/                              # Shared infrastructure
│   ├── config/                        # App configuration
│   ├── constants/                     # App-wide constants
│   ├── di/                            # Dependency injection
│   ├── error/                         # Error handling
│   ├── network/                       # HTTP client, interceptors
│   ├── platform/                      # Platform-specific code
│   └── utils/                         # Utility functions
├── features/                          # Feature modules
│   ├── authentication/
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
│   ├── messaging/
│   ├── video_conferencing/
│   └── ...
└── shared/                            # Shared UI components
    ├── widgets/
    └── layouts/
```

### Feature Module Template

Every feature follows this structure:

```
features/<feature_name>/
├── data/
│   ├── datasources/
│   │   ├── <feature>_remote_datasource.dart
│   │   └── <feature>_local_datasource.dart
│   ├── models/
│   │   └── <model>_model.dart
│   └── repositories/
│       └── <feature>_repository_impl.dart
├── domain/
│   ├── entities/
│   │   └── <entity>.dart
│   ├── repositories/
│   │   └── <feature>_repository.dart
│   └── usecases/
│       ├── <action>_<entity>.dart
│       └── ...
└── presentation/
    ├── pages/
    │   └── <page>_page.dart
    ├── widgets/
    │   └── <widget>.dart
    └── providers/
        └── <feature>_provider.dart
```

---

## Layer Responsibilities

### Presentation Layer (`presentation/`)

**Purpose:** User interface and user interaction

**Responsibilities:**
- Display data from ViewModels/Providers
- Handle user input
- Navigate between screens
- Show loading/error states

**Rules:**
- ✅ Stateless/StatefulWidget only
- ✅ Use `const` constructors wherever possible
- ✅ No direct service/repository calls
- ✅ No business logic
- ❌ No async work in `build()`
- ❌ No navigation logic in widgets

**Example:**
```dart
class ProfilePage extends StatelessWidget {
  final String userId;
  
  const ProfilePage({required this.userId, super.key});
  
  @override
  Widget build(BuildContext context) {
    return Consumer<ProfileProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading) return const CircularProgressIndicator();
        if (provider.error != null) return ErrorWidget(provider.error!);
        
        return ProfileView(profile: provider.profile);
      },
    );
  }
}
```

### Domain Layer (`domain/`)

**Purpose:** Business logic and business rules

**Responsibilities:**
- Define business entities
- Define repository interfaces
- Implement use cases (business operations)
- Validate business rules

**Rules:**
- ✅ Pure Dart only (no Flutter dependencies)
- ✅ Platform-agnostic
- ✅ 100% testable with unit tests
- ❌ No UI imports
- ❌ No implementation details (HTTP, database, etc.)

**Example:**
```dart
// Entity
class UserProfile {
  final String id;
  final String displayName;
  final String? avatarUrl;
  
  UserProfile({required this.id, required this.displayName, this.avatarUrl});
  
  // Business logic can live here
  bool get hasAvatar => avatarUrl != null && avatarUrl!.isNotEmpty;
}

// Repository Interface
abstract class ProfileRepository {
  Future<Either<Failure, UserProfile>> getProfile(String userId);
  Future<Either<Failure, void>> updateProfile(UserProfile profile);
}

// Use Case
class GetUserProfile {
  final ProfileRepository repository;
  
  GetUserProfile(this.repository);
  
  Future<Either<Failure, UserProfile>> call(String userId) async {
    return repository.getProfile(userId);
  }
}
```

### Data Layer (`data/`)

**Purpose:** Data access and persistence

**Responsibilities:**
- Implement repository interfaces
- Fetch data from remote/local sources
- Map DTOs to domain entities
- Cache data
- Handle network/database errors

**Rules:**
- ✅ Implements domain repository interfaces
- ✅ Uses data sources for actual I/O
- ✅ Maps between models (DTOs) and entities
- ❌ No business logic
- ❌ No UI concerns

**Example:**
```dart
// Model (DTO)
class UserProfileModel extends UserProfile {
  UserProfileModel({
    required super.id,
    required super.displayName,
    super.avatarUrl,
  });
  
  factory UserProfileModel.fromJson(Map<String, dynamic> json) {
    return UserProfileModel(
      id: json['id'],
      displayName: json['display_name'],
      avatarUrl: json['avatar_url'],
    );
  }
}

// Data Source
abstract class ProfileRemoteDataSource {
  Future<UserProfileModel> getProfile(String userId);
}

// Repository Implementation
class ProfileRepositoryImpl implements ProfileRepository {
  final ProfileRemoteDataSource remoteDataSource;
  final ProfileLocalDataSource localDataSource;
  
  ProfileRepositoryImpl({
    required this.remoteDataSource,
    required this.localDataSource,
  });
  
  @override
  Future<Either<Failure, UserProfile>> getProfile(String userId) async {
    try {
      final profile = await remoteDataSource.getProfile(userId);
      await localDataSource.cacheProfile(profile);
      return Right(profile);
    } on ServerException {
      return Left(ServerFailure());
    }
  }
}
```

---

## Naming Conventions

### Files

| Type | Convention | Example |
|------|------------|---------|
| Dart files | snake_case | `user_profile_page.dart` |
| Test files | `<name>_test.dart` | `user_profile_page_test.dart` |
| Models | `<name>_model.dart` | `user_profile_model.dart` |
| Use cases | `<verb>_<noun>.dart` | `get_user_profile.dart` |
| Repositories | `<name>_repository.dart` | `profile_repository.dart` |
| Providers | `<name>_provider.dart` | `profile_provider.dart` |

### Classes

| Type | Convention | Example |
|------|------------|---------|
| Classes | PascalCase | `UserProfile` |
| Interfaces | PascalCase | `ProfileRepository` |
| Implementations | `<Name>Impl` | `ProfileRepositoryImpl` |
| Use cases | `<Verb><Noun>` | `GetUserProfile` |
| Providers | `<Name>Provider` | `ProfileProvider` |
| Models | `<Name>Model` | `UserProfileModel` |

### Variables

| Type | Convention | Example |
|------|------------|---------|
| Variables | camelCase | `isLoading` |
| Constants | camelCase | `maxRetries` |
| Private | `_camelCase` | `_userId` |
| Static const | camelCase | `defaultTimeout` |

### Terminology

**Consistent naming across the app:**

- **Page:** Full-screen UI (`login_page.dart`)
- **Widget:** Reusable UI component (`user_avatar.dart`)
- **Provider:** State management (`profile_provider.dart`)
- **Repository:** Data access abstraction (`profile_repository.dart`)
- **UseCase:** Single business operation (`get_user_profile.dart`)
- **Entity:** Business object (`user_profile.dart`)
- **Model:** Data transfer object (`user_profile_model.dart`)

---

## Code Organization Rules

### Import Order

```dart
// 1. Dart imports
import 'dart:async';
import 'dart:io';

// 2. Flutter imports
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// 3. Package imports (alphabetical)
import 'package:provider/provider.dart';
import 'package:http/http.dart';

// 4. Project imports (alphabetical, use relative for same feature)
import 'package:peerwave/core/error/failures.dart';
import 'package:peerwave/features/auth/domain/entities/user.dart';

// 5. Relative imports (same feature only)
import '../domain/entities/profile.dart';
```

### Class Structure

```dart
class ExampleClass {
  // 1. Static constants
  static const String defaultValue = 'default';
  
  // 2. Instance fields
  final String id;
  final String name;
  
  // 3. Constructor
  ExampleClass({required this.id, required this.name});
  
  // 4. Named constructors
  ExampleClass.empty() : id = '', name = '';
  
  // 5. Getters
  String get displayName => name.toUpperCase();
  
  // 6. Public methods
  void publicMethod() { }
  
  // 7. Private methods
  void _privateMethod() { }
  
  // 8. Overrides
  @override
  String toString() => 'ExampleClass($id, $name)';
}
```

### Widget Lifecycle

```dart
class ExampleWidget extends StatefulWidget {
  // Constructor and fields
  
  @override
  State<ExampleWidget> createState() => _ExampleWidgetState();
}

class _ExampleWidgetState extends State<ExampleWidget> {
  // 1. State fields
  
  // 2. initState - subscriptions, controllers
  @override
  void initState() {
    super.initState();
    // Setup code
  }
  
  // 3. didChangeDependencies - inherited widgets
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Access Provider, Theme, etc.
  }
  
  // 4. didUpdateWidget - react to widget changes
  @override
  void didUpdateWidget(ExampleWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Handle widget updates
  }
  
  // 5. build - pure function
  @override
  Widget build(BuildContext context) {
    // NO side effects here!
    return Container();
  }
  
  // 6. dispose - cleanup
  @override
  void dispose() {
    // Dispose controllers, cancel subscriptions
    super.dispose();
  }
}
```

---

## Dependency Management

### Using GetIt for Dependency Injection

```dart
// core/di/injection_container.dart
final getIt = GetIt.instance;

Future<void> configureDependencies() async {
  // External
  final prefs = await SharedPreferences.getInstance();
  getIt.registerLazySingleton(() => prefs);
  
  // Core
  getIt.registerLazySingleton(() => ApiClient());
  getIt.registerLazySingleton<NetworkInfo>(() => NetworkInfoImpl());
  
  // Features - Authentication
  getIt.registerFactory(() => LoginUser(getIt()));
  getIt.registerLazySingleton<AuthRepository>(
    () => AuthRepositoryImpl(
      remoteDataSource: getIt(),
      localDataSource: getIt(),
    ),
  );
}
```

### Registration Types

| Type | When to Use | Example |
|------|-------------|---------|
| `registerFactory` | Create new instance each time | Use cases, providers |
| `registerLazySingleton` | Single instance, created when first needed | Repositories, services |
| `registerSingleton` | Single instance, created immediately | Rare - initialized objects |

---

## State Management

### Provider Pattern (Current)

```dart
// Provider
class ProfileProvider extends ChangeNotifier {
  final GetUserProfile getUserProfile;
  
  UserProfile? _profile;
  bool _isLoading = false;
  String? _error;
  
  UserProfile? get profile => _profile;
  bool get isLoading => _isLoading;
  String? get error => _error;
  
  ProfileProvider({required this.getUserProfile});
  
  Future<void> loadProfile(String userId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    
    final result = await getUserProfile(userId);
    result.fold(
      (failure) {
        _error = failure.message;
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
}

// UI
Consumer<ProfileProvider>(
  builder: (context, provider, _) {
    if (provider.isLoading) return const LoadingWidget();
    if (provider.error != null) return ErrorWidget(provider.error!);
    return ProfileView(profile: provider.profile);
  },
)

// Or use Selector for granular rebuilds
Selector<ProfileProvider, String?>(
  selector: (_, provider) => provider.profile?.displayName,
  builder: (_, displayName, __) => Text(displayName ?? ''),
)
```

---

## Error Handling

### Failure Pattern

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
  const NetworkFailure([String message = 'No connection']) : super(message);
}

class CacheFailure extends Failure {
  const CacheFailure([String message = 'Cache error']) : super(message);
}

// core/error/exceptions.dart
class ServerException implements Exception {
  final String? message;
  ServerException([this.message]);
}

class NetworkException implements Exception {}
class CacheException implements Exception {}
```

### Using Either for Error Handling

```dart
import 'package:dartz/dartz.dart';

// Repository
Future<Either<Failure, UserProfile>> getProfile(String userId) async {
  try {
    final profile = await remoteDataSource.getProfile(userId);
    return Right(profile);
  } on ServerException {
    return Left(ServerFailure());
  } on SocketException {
    return Left(NetworkFailure());
  }
}

// Use Case
final result = await getUserProfile('123');
result.fold(
  (failure) => print('Error: ${failure.message}'),
  (profile) => print('Success: ${profile.displayName}'),
);
```

---

## Testing Strategy

### Test Structure

```
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
        │       └── login_user_test.dart
        └── presentation/
            └── providers/
                └── auth_provider_test.dart
```

### Testing Pyramid

- **70% Unit Tests** - Domain layer (use cases, entities)
- **20% Widget Tests** - Presentation layer widgets
- **10% Integration Tests** - End-to-end flows

### Unit Test Template

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

@GenerateMocks([AuthRepository])
void main() {
  late LoginUser useCase;
  late MockAuthRepository mockRepository;
  
  setUp(() {
    mockRepository = MockAuthRepository();
    useCase = LoginUser(mockRepository);
  });
  
  group('LoginUser', () {
    const tEmail = 'test@example.com';
    const tPassword = 'password123';
    final tUser = User(id: '1', email: tEmail);
    
    test('should return User when login succeeds', () async {
      // Arrange
      when(mockRepository.login(tEmail, tPassword))
          .thenAnswer((_) async => Right(tUser));
      
      // Act
      final result = await useCase(tEmail, tPassword);
      
      // Assert
      expect(result, Right(tUser));
      verify(mockRepository.login(tEmail, tPassword));
      verifyNoMoreInteractions(mockRepository);
    });
    
    test('should return Failure when login fails', () async {
      // Arrange
      when(mockRepository.login(tEmail, tPassword))
          .thenAnswer((_) async => Left(ServerFailure()));
      
      // Act
      final result = await useCase(tEmail, tPassword);
      
      // Assert
      expect(result, Left(ServerFailure()));
    });
  });
}
```

---

## Migration Process

### Phase-by-Phase Migration

**Phase 1: Foundation (Current)**
- ✅ Create directory structure
- ✅ Document guidelines
- ✅ Set up DI framework
- ⏳ Create core infrastructure

**Phase 2: Pilot Feature**
- Choose simple feature (User Profile)
- Implement full Clean Architecture
- Write tests
- Document learnings

**Phase 3: Critical Features**
- Authentication
- Messaging
- Video Conferencing

**Phase 4: Remaining Features**
- Meetings, File Transfer, Settings

**Phase 5: Cleanup**
- Remove old code
- Performance optimization

### Migration Checklist per Feature

- [ ] Create feature directory structure
- [ ] Define domain entities
- [ ] Define repository interface
- [ ] Implement use cases
- [ ] Create data models
- [ ] Implement data sources
- [ ] Implement repository
- [ ] Create provider/ViewModel
- [ ] Build UI pages/widgets
- [ ] Write unit tests
- [ ] Write widget tests
- [ ] Update imports in consuming code
- [ ] Remove old implementation

---

## Code Review Checklist

### Architecture Compliance

- [ ] Feature code is in correct `features/<feature>/` directory
- [ ] Layers are properly separated (presentation/domain/data)
- [ ] Dependencies flow inward only
- [ ] No UI code in domain layer
- [ ] No business logic in presentation layer

### Code Quality

- [ ] Classes are <300 lines
- [ ] Methods are <50 lines
- [ ] No duplicate code
- [ ] Proper error handling with Either<Failure, T>
- [ ] All public APIs are documented
- [ ] No `// TODO` or `// FIXME` in production code

### Flutter Best Practices

- [ ] No side effects in `build()` methods
- [ ] `const` constructors used where possible
- [ ] Keys used for dynamic lists
- [ ] Proper disposal of controllers/streams
- [ ] No memory leaks

### Testing

- [ ] Unit tests for use cases (domain)
- [ ] Unit tests for repositories (data)
- [ ] Widget tests for complex widgets
- [ ] Test coverage >70%
- [ ] No skipped tests without reason

### Performance

- [ ] No expensive operations in build()
- [ ] Large lists use ListView.builder
- [ ] Images are cached appropriately
- [ ] Selector used to limit rebuilds

---

## Quick Reference

### When to Use What

| Scenario | Use |
|----------|-----|
| Creating new feature | Follow feature template structure |
| Sharing code between features | Put in `core/` or `shared/` |
| Platform-specific code | Put in `core/platform/` with interface |
| API calls | Create data source in `data/datasources/` |
| Business logic | Create use case in `domain/usecases/` |
| Data transformation | Create model in `data/models/` |
| UI state | Create provider in `presentation/providers/` |
| Reusable widget | Put in `shared/widgets/` |
| Feature-specific widget | Put in `features/<feature>/presentation/widgets/` |

### Common Patterns

**Fetching data:**
```
UI → Provider → UseCase → Repository → DataSource → API/DB
```

**Error handling:**
```
Exception (Data) → Failure (Domain) → Error State (Presentation)
```

**State flow:**
```
User Action → Provider Method → UseCase → Repository → Update State → Notify UI
```

---

## Additional Resources

- [Architecture Review Document](./ARCHITECTURE_REVIEW.md) - Complete analysis
- [Flutter Architectural Overview](https://docs.flutter.dev/resources/architectural-overview)
- [Clean Architecture by Uncle Bob](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [Effective Dart](https://dart.dev/guides/language/effective-dart)

---

**Questions or suggestions?** Contact the Architecture Team

**Last Updated:** December 22, 2025
