# Troubleshoot Feature

## Overview

The Troubleshoot feature provides Signal Protocol diagnostics and maintenance operations for debugging encryption issues and managing cryptographic keys.

## Architecture

This feature follows **pragmatic Flutter architecture** with a flat structure:

```
features/troubleshoot/
├── pages/          # Full-screen UIs
│   └── troubleshoot_page.dart
├── widgets/        # Feature-specific widgets
│   ├── metrics_card.dart
│   └── troubleshoot_action_button.dart
├── state/          # State management
│   └── troubleshoot_provider.dart
└── models/         # Feature models
    └── key_metrics.dart
```

**Service Layer:**
- Business logic is in `services/troubleshoot/troubleshoot_service.dart`
- The service coordinates with SignalService and metrics collection

## Components

### Models

**KeyMetrics:**
- Immutable model representing Signal Protocol key management metrics
- Contains counts for identity regenerations, pre-key operations, decryption failures, etc.

### State Management

**TroubleshootProvider:**
- Uses `ChangeNotifier` for state management
- Coordinates with `TroubleshootService` for all operations
- Manages loading states, errors, and success messages
- Methods for key operations: delete, regenerate, rotate

### Service

**TroubleshootService** (`services/troubleshoot/`):
- `TroubleshootRepositoryImpl` - Implementation of domain repository

### Presentation Layer

**Pages:**
- `TroubleshootPage` - Main troubleshooting UI

**Providers:**
- `TroubleshootProvider` - State management using ChangeNotifier

**Widgets:**
- `MetricsCard` - Displays key management metrics
- `TroubleshootActionButton` - Action button with severity indicators
- `ChannelSelectionDialog` - Dialog for selecting channels

## Features

### Metrics Display

Real-time monitoring of:
- Identity key regenerations
- SignedPreKey rotations
- PreKeys regenerated/consumed
- Sessions invalidated
- Decryption failures
- Server key mismatches

### Maintenance Operations

**Critical Operations:**
- Delete Identity Key - Regenerates identity key pair (invalidates all sessions)

**High-Risk Operations:**
- Delete Signed PreKey - Removes signed pre-key (local & server)
- Delete PreKeys - Removes all pre-keys (local & server)
- Force PreKey Regeneration - Complete pre-key refresh

**Medium-Risk Operations:**
- Delete Group Key - Removes encryption key for specific channel

**Low-Risk Operations:**
- Force SignedPreKey Rotation - Manual rotation cycle

### Safety Features

- Confirmation dialogs for destructive operations
- Severity indicators (Critical, High, Medium, Low)
- Warning banners when issues are detected
- Automatic metrics refresh after operations

## Usage

### Accessing the Feature

1. Navigate to Settings
2. Select "Troubleshoot" from sidebar
3. View metrics and perform maintenance operations

### User Flow

```
Settings → Troubleshoot
    ├→ View Metrics (automatic load)
    ├→ Click Action Button
    ├→ Confirm in Dialog
    ├→ Operation Executes
    ├→ Success/Error Feedback
    └→ Metrics Auto-Refresh
```

## Dependencies

- `provider` - State management
- `flutter/material.dart` - UI framework
- `services/signal_service.dart` - Signal Protocol operations
- `services/key_management_metrics.dart` - Metrics collection
- `services/storage/sqlite_group_message_store.dart` - Channel data

## Testing

### Unit Tests (Domain Layer)

```dart
test('GetKeyMetrics returns current metrics', () async {
  final mockRepo = MockTroubleshootRepository();
  final useCase = GetKeyMetrics(mockRepo);
  
  when(mockRepo.getKeyMetrics()).thenAnswer((_) async => testMetrics);
  
  final result = await useCase();
  
  expect(result, equals(testMetrics));
});
```

### Widget Tests (Presentation Layer)

```dart
testWidgets('MetricsCard displays metrics correctly', (tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ChangeNotifierProvider(
        create: (_) => mockProvider,
        child: const MetricsCard(),
      ),
    ),
  );
  
  expect(find.text('Identity Regenerations'), findsOneWidget);
});
```

## Extension Points

### Adding New Operations

1. Add method to `TroubleshootRepository` interface
2. Implement in `TroubleshootRepositoryImpl`
3. Implement in `TroubleshootDataSourceImpl`
4. Add method to `TroubleshootProvider`
5. Add button to `TroubleshootPage`

### Adding New Metrics

1. Add field to `KeyMetrics` entity
2. Update `KeyMetricsModel.fromService()`
3. Add display in `MetricsCard._buildMetricsGrid()`

## Future Enhancements

- [ ] Export metrics as JSON/CSV
- [ ] Metrics history/timeline view
- [ ] Automated diagnostics and recommendations
- [ ] Session management UI
- [ ] Pre-key pool monitoring
- [ ] Network latency metrics

## Best Practices

### DO:
- ✅ Keep domain layer pure (no Flutter dependencies)
- ✅ Use dependency injection
- ✅ Show confirmation dialogs for destructive actions
- ✅ Provide clear error messages
- ✅ Auto-refresh metrics after operations

### DON'T:
- ❌ Call services directly from widgets
- ❌ Put business logic in providers
- ❌ Skip confirmation for critical operations
- ❌ Ignore error states
- ❌ Expose sensitive cryptographic material

## Code Style

Follows [Architecture Guidelines](../../docs/ARCHITECTURE_GUIDELINES.md):
- Snake_case for files
- PascalCase for classes
- Professional, concise documentation
- Type-safe operations
- Proper error handling

## Support

For issues or questions about this feature:
1. Check Signal Protocol documentation
2. Review `key_management_metrics.dart` for metric definitions
3. Consult `signal_service.dart` for available operations
