// Platform-specific notification service export
// Uses conditional imports to provide the correct implementation for each platform

export 'notification_service_impl.dart'
    if (dart.library.io) 'notification_service_platform_io.dart'
    if (dart.library.html) 'notification_service.dart'; // Web uses original desktop service
