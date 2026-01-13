// Default implementation stub for platforms that don't have specific implementations
import 'notification_service.dart' as desktop;

/// Export the desktop notification service as default
dynamic get notificationService => desktop.NotificationService.instance;
