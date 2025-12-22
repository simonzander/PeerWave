# Shared Directory

Contains **reusable UI components** used across multiple features.

## Structure

```
shared/
├── widgets/       # Reusable widgets (buttons, dialogs, inputs, etc.)
└── layouts/       # Layout components (app shell, responsive layouts)
```

## Guidelines

### When to Put a Widget in Shared

✅ **YES - Put in `shared/widgets/`:**
- Widget is used by 2+ features
- Generic, reusable UI components
- No feature-specific business logic
- Examples: buttons, dialogs, loading indicators, form inputs

❌ **NO - Keep in feature:**
- Widget is specific to one feature
- Contains feature-specific logic
- Tightly coupled to a feature's domain

### Examples

**Shared widgets:**
```dart
shared/widgets/
├── buttons/
│   ├── primary_button.dart
│   ├── secondary_button.dart
│   └── icon_button.dart
├── dialogs/
│   ├── confirmation_dialog.dart
│   └── error_dialog.dart
├── inputs/
│   ├── text_field.dart
│   └── password_field.dart
└── loading/
    ├── loading_indicator.dart
    └── skeleton_loader.dart
```

**Feature-specific widgets** (stay in feature):
```dart
features/messaging/presentation/widgets/
├── message_bubble.dart           # Specific to messaging
├── message_input.dart            # Specific to messaging
└── conversation_list_tile.dart   # Specific to messaging
```

### Shared Layouts

```dart
shared/layouts/
├── app_layout.dart          # Main app shell
├── responsive_layout.dart   # Responsive wrapper
└── modal_layout.dart        # Modal/dialog layout
```

## Dependencies

Shared widgets should:
- Have minimal dependencies
- Not depend on feature-specific code
- Use theme and design system tokens
- Be fully documented

## Migration Status

🚧 **Phase 1 Foundation** - Directory structure created

Existing reusable widgets in `lib/widgets/` will be gradually moved here.

## See Also

- [ARCHITECTURE_GUIDELINES.md](../../docs/ARCHITECTURE_GUIDELINES.md)
