# Core Directory

Contains **shared infrastructure** used across all features.

## Structure

```
core/
├── config/        # App configuration, environment settings
├── constants/     # App-wide constants
├── di/            # Dependency injection setup
├── error/         # Error handling (Failures, Exceptions)
├── network/       # HTTP client, interceptors, network utilities
├── platform/      # Platform-specific code abstractions
├── storage/       # Existing storage implementations
├── theme/         # Existing theme configuration
├── utils/         # Utility functions, extensions
└── version/       # Existing version management
```

## Guidelines

### What Belongs in Core

✅ **YES:**
- Infrastructure code used by multiple features
- Platform abstractions (web/native)
- Network client and interceptors
- Error types (Failures, Exceptions)
- Utility functions
- App configuration
- Dependency injection setup

❌ **NO:**
- Feature-specific business logic (goes in `features/<feature>/domain/`)
- UI widgets (goes in `shared/widgets/` or feature-specific)
- Feature-specific models (goes in feature directories)

### Dependencies

Core modules should have:
- Minimal external dependencies
- No dependencies on `features/`
- No Flutter Material/Cupertino widgets (use foundation only)

### Current vs New Structure

**Existing (being migrated):**
- `core/storage/` - Keep as-is
- `core/update/` - Keep as-is
- `core/version/` - Keep as-is

**New (being added):**
- `core/di/` - Dependency injection
- `core/config/` - Configuration
- `core/constants/` - Constants
- `core/error/` - Error handling
- `core/network/` - Network layer
- `core/platform/` - Platform abstractions

## Migration Status

🚧 **Phase 1 Foundation** - Directory structure created

Next steps:
1. Create error handling (Failures, Exceptions)
2. Set up dependency injection with get_it
3. Create network layer abstractions
4. Migrate platform-specific code to core/platform/

## See Also

- [ARCHITECTURE_GUIDELINES.md](../../docs/ARCHITECTURE_GUIDELINES.md)
