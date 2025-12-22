# Features Directory

This directory contains all **feature modules** organized by business domain.

## Structure

Each feature follows **Clean Architecture** with three layers:

```
features/<feature_name>/
├── data/              # Data access & external dependencies
├── domain/            # Business logic (platform-agnostic)
└── presentation/      # UI and user interaction
```

## Current Status

🚧 **Migration in Progress** - Phase 1 Foundation

### Planned Features

1. **authentication** - Login, registration, OTP, WebAuthn
2. **user_profile** - User profiles, avatars, presence
3. **messaging** - 1:1 messaging, conversations
4. **channels** - Group channels, channel messaging
5. **meetings** - Scheduled meetings, RSVP
6. **video_conferencing** - LiveKit video calls
7. **file_transfer** - File upload/download
8. **activities** - Activity feed
9. **notifications** - In-app notifications
10. **admin** - Role management, user administration
11. **encryption** - E2EE (may become internal package)
12. **settings** - App settings

## Adding a New Feature

1. Create feature directory: `features/<feature_name>/`
2. Follow the template structure (see ARCHITECTURE_GUIDELINES.md)
3. Implement layers: domain → data → presentation
4. Write tests alongside implementation
5. Update this README

## Layer Details

### Domain Layer (`domain/`)
- **Pure Dart** - no Flutter or external dependencies
- Contains: entities, repository interfaces, use cases
- 100% unit testable

### Data Layer (`data/`)
- Implements repository interfaces from domain
- Contains: data sources, models (DTOs), repository implementations
- Handles external data sources (API, database, cache)

### Presentation Layer (`presentation/`)
- Flutter UI code
- Contains: pages, widgets, providers/ViewModels
- Depends on domain layer only (via use cases)

## Dependencies

Dependencies must flow **inward only**:
```
presentation → domain → data → core
```

Never:
- ❌ domain depending on data
- ❌ domain depending on presentation
- ❌ presentation depending on data

## See Also

- [ARCHITECTURE_GUIDELINES.md](../../../docs/ARCHITECTURE_GUIDELINES.md) - Complete guidelines
- [ARCHITECTURE_REVIEW.md](../../../docs/ARCHITECTURE_REVIEW.md) - Architecture analysis
