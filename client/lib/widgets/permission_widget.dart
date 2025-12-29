import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/role_provider.dart';

/// Widget that conditionally renders based on user permissions
class PermissionWidget extends StatelessWidget {
  /// The permission required to show the child widget
  final String permission;

  /// Optional channel ID for channel-specific permissions
  final String? channelId;

  /// The widget to show if the user has the permission
  final Widget child;

  /// Optional widget to show if the user doesn't have the permission
  final Widget? fallback;

  /// Whether to show the fallback widget or nothing when permission is denied
  final bool showFallback;

  const PermissionWidget({
    super.key,
    required this.permission,
    required this.child,
    this.channelId,
    this.fallback,
    this.showFallback = false,
  });

  @override
  Widget build(BuildContext context) {
    final roleProvider = Provider.of<RoleProvider>(context);

    final hasPermission = channelId != null
        ? roleProvider.hasChannelPermission(channelId!, permission)
        : roleProvider.hasServerPermission(permission);

    if (hasPermission) {
      return child;
    } else if (showFallback && fallback != null) {
      return fallback!;
    } else {
      return const SizedBox.shrink();
    }
  }
}

/// Widget that shows content only to administrators
class AdminOnlyWidget extends StatelessWidget {
  final Widget child;
  final Widget? fallback;
  final bool showFallback;

  const AdminOnlyWidget({
    super.key,
    required this.child,
    this.fallback,
    this.showFallback = false,
  });

  @override
  Widget build(BuildContext context) {
    final roleProvider = Provider.of<RoleProvider>(context);

    if (roleProvider.isAdmin) {
      return child;
    } else if (showFallback && fallback != null) {
      return fallback!;
    } else {
      return const SizedBox.shrink();
    }
  }
}

/// Widget that shows content only to moderators or higher
class ModeratorOnlyWidget extends StatelessWidget {
  final Widget child;
  final Widget? fallback;
  final bool showFallback;

  const ModeratorOnlyWidget({
    super.key,
    required this.child,
    this.fallback,
    this.showFallback = false,
  });

  @override
  Widget build(BuildContext context) {
    final roleProvider = Provider.of<RoleProvider>(context);

    if (roleProvider.isAdmin || roleProvider.isModerator) {
      return child;
    } else if (showFallback && fallback != null) {
      return fallback!;
    } else {
      return const SizedBox.shrink();
    }
  }
}

/// Widget that shows content only to channel owners
class ChannelOwnerWidget extends StatelessWidget {
  final String channelId;
  final Widget child;
  final Widget? fallback;
  final bool showFallback;

  const ChannelOwnerWidget({
    super.key,
    required this.channelId,
    required this.child,
    this.fallback,
    this.showFallback = false,
  });

  @override
  Widget build(BuildContext context) {
    final roleProvider = Provider.of<RoleProvider>(context);

    if (roleProvider.isAdmin || roleProvider.isChannelOwner(channelId)) {
      return child;
    } else if (showFallback && fallback != null) {
      return fallback!;
    } else {
      return const SizedBox.shrink();
    }
  }
}

/// Widget that shows content only to channel moderators or higher
class ChannelModeratorWidget extends StatelessWidget {
  final String channelId;
  final Widget child;
  final Widget? fallback;
  final bool showFallback;

  const ChannelModeratorWidget({
    super.key,
    required this.channelId,
    required this.child,
    this.fallback,
    this.showFallback = false,
  });

  @override
  Widget build(BuildContext context) {
    final roleProvider = Provider.of<RoleProvider>(context);

    if (roleProvider.isAdmin ||
        roleProvider.isChannelOwner(channelId) ||
        roleProvider.isChannelModerator(channelId)) {
      return child;
    } else if (showFallback && fallback != null) {
      return fallback!;
    } else {
      return const SizedBox.shrink();
    }
  }
}
