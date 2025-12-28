import 'package:flutter/material.dart';
import 'dart:convert';
import '../services/user_profile_service.dart';
import '../theme/semantic_colors.dart';
import '../theme/avatar_colors.dart';

/// Widget to display user avatar with picture or initials
class UserAvatar extends StatefulWidget {
  final String? userId;
  final String? displayName;
  final String? pictureData; // base64 or URL
  final double size;
  final bool showOnlineStatus;
  final bool isOnline;

  const UserAvatar({
    super.key,
    this.userId,
    this.displayName,
    this.pictureData,
    this.size = 40,
    this.showOnlineStatus = false,
    this.isOnline = false,
  });

  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<UserAvatar> {
  String? _loadedDisplayName;
  String? _loadedPicture;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void didUpdateWidget(UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload if userId changed
    if (widget.userId != oldWidget.userId) {
      _loadProfile();
    }
  }

  void _loadProfile() {
    final userIdValue = widget.userId;
    if (userIdValue != null && userIdValue.isNotEmpty) {
      final profile = UserProfileService.instance.getProfileOrLoad(
        userIdValue,
        onLoaded: (profile) {
          if (mounted && profile != null) {
            setState(() {
              _loadedDisplayName = profile['displayName'] as String?;
              _loadedPicture = profile['picture'] as String?;
            });
          }
        },
      );

      // Use cached data immediately if available
      if (profile != null) {
        _loadedDisplayName = profile['displayName'] as String?;
        _loadedPicture = profile['picture'] as String?;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Use loaded profile data, falling back to widget properties
    String? effectiveDisplayName = widget.displayName ?? _loadedDisplayName;
    String? effectivePicture = widget.pictureData ?? _loadedPicture;

    // Fallback to userId if no displayName
    effectiveDisplayName ??= widget.userId ?? 'U';

    // Get first letter for initials
    final initials = _getInitials(effectiveDisplayName);

    // Parse picture data
    ImageProvider? imageProvider;
    if (effectivePicture != null && effectivePicture.isNotEmpty) {
      try {
        if (effectivePicture.startsWith('data:image/')) {
          // Base64 encoded image
          final base64Data = effectivePicture.split(',').last;
          final bytes = base64Decode(base64Data);
          imageProvider = MemoryImage(bytes);
        } else if (effectivePicture.startsWith('http://') ||
            effectivePicture.startsWith('https://')) {
          // URL
          imageProvider = NetworkImage(effectivePicture);
        }
      } catch (e) {
        debugPrint('[UserAvatar] Error parsing picture: $e');
      }
    }

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: widget.size / 2,
            backgroundColor: imageProvider == null
                ? _getColorForUser(effectiveDisplayName)
                : Colors.transparent,
            backgroundImage: imageProvider,
            child: imageProvider == null
                ? Text(
                    initials,
                    style: TextStyle(
                      color: colorScheme.onPrimary,
                      fontSize: widget.size / 2.5,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : null,
          ),
          // Online status indicator
          if (widget.showOnlineStatus)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: widget.size / 4,
                height: widget.size / 4,
                decoration: BoxDecoration(
                  color: widget.isOnline
                      ? Theme.of(context).colorScheme.success
                      : colorScheme.onSurface.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                  border: Border.all(color: colorScheme.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Get initials from display name (first 1-2 letters)
  String _getInitials(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'U';

    final parts = trimmed.split(' ');
    if (parts.length >= 2) {
      // First letter of first two words
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    } else {
      // First two letters of single word (or first letter if only 1 char)
      return trimmed.length >= 2
          ? trimmed.substring(0, 2).toUpperCase()
          : trimmed[0].toUpperCase();
    }
  }

  /// Generate consistent color for user based on name
  /// Uses theme-compatible pastel colors for better visual harmony
  Color _getColorForUser(String name) {
    return AvatarColors.colorForName(name);
  }
}

/// Small variant for compact lists
class SmallUserAvatar extends StatelessWidget {
  final String? userId;
  final String? displayName;
  final String? pictureData;

  const SmallUserAvatar({
    super.key,
    this.userId,
    this.displayName,
    this.pictureData,
  });

  @override
  Widget build(BuildContext context) {
    return UserAvatar(
      userId: userId,
      displayName: displayName,
      pictureData: pictureData,
      size: 32,
    );
  }
}

/// Large variant for profile pages
class LargeUserAvatar extends StatelessWidget {
  final String? userId;
  final String? displayName;
  final String? pictureData;
  final bool showOnlineStatus;
  final bool isOnline;

  const LargeUserAvatar({
    super.key,
    this.userId,
    this.displayName,
    this.pictureData,
    this.showOnlineStatus = false,
    this.isOnline = false,
  });

  @override
  Widget build(BuildContext context) {
    return UserAvatar(
      userId: userId,
      displayName: displayName,
      pictureData: pictureData,
      size: 80,
      showOnlineStatus: showOnlineStatus,
      isOnline: isOnline,
    );
  }
}

/// Square avatar with rounded corners - for context panels and lists
class SquareUserAvatar extends StatefulWidget {
  final String? userId;
  final String? displayName;
  final String? pictureData;
  final double size;
  final bool showOnlineStatus;
  final bool isOnline;

  const SquareUserAvatar({
    super.key,
    this.userId,
    this.displayName,
    this.pictureData,
    this.size = 40,
    this.showOnlineStatus = false,
    this.isOnline = false,
  });

  @override
  State<SquareUserAvatar> createState() => _SquareUserAvatarState();
}

class _SquareUserAvatarState extends State<SquareUserAvatar> {
  String? _loadedDisplayName;
  String? _loadedPicture;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void didUpdateWidget(SquareUserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.userId != oldWidget.userId) {
      _loadProfile();
    }
  }

  void _loadProfile() {
    final userIdValue = widget.userId;
    if (userIdValue != null && userIdValue.isNotEmpty) {
      final profile = UserProfileService.instance.getProfileOrLoad(
        userIdValue,
        onLoaded: (profile) {
          if (mounted && profile != null) {
            setState(() {
              _loadedDisplayName = profile['displayName'] as String?;
              _loadedPicture = profile['picture'] as String?;
            });
          }
        },
      );

      if (profile != null) {
        _loadedDisplayName = profile['displayName'] as String?;
        _loadedPicture = profile['picture'] as String?;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Use loaded profile data, falling back to widget properties
    String? effectiveDisplayName = widget.displayName ?? _loadedDisplayName;
    String? effectivePicture = widget.pictureData ?? _loadedPicture;

    // Fallback to userId if no displayName
    effectiveDisplayName ??= widget.userId ?? 'U';

    // Get first letter for initials
    final initials = _getInitials(effectiveDisplayName);

    // Parse picture data
    ImageProvider? imageProvider;
    if (effectivePicture != null && effectivePicture.isNotEmpty) {
      try {
        if (effectivePicture.startsWith('data:image/')) {
          // Base64 encoded image
          final base64Data = effectivePicture.split(',').last;
          final bytes = base64Decode(base64Data);
          imageProvider = MemoryImage(bytes);
        } else if (effectivePicture.startsWith('http://') ||
            effectivePicture.startsWith('https://')) {
          // URL
          imageProvider = NetworkImage(effectivePicture);
        }
      } catch (e) {
        debugPrint('[SquareUserAvatar] Error parsing picture: $e');
      }
    }

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: imageProvider == null
                  ? _getColorForUser(effectiveDisplayName)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(
                8,
              ), // Theme's standard rounded corners
              image: imageProvider != null
                  ? DecorationImage(image: imageProvider, fit: BoxFit.cover)
                  : null,
            ),
            child: imageProvider == null
                ? Center(
                    child: Text(
                      initials,
                      style: TextStyle(
                        color: colorScheme.onPrimary,
                        fontSize: widget.size / 2.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : null,
          ),
          // Online status indicator
          if (widget.showOnlineStatus)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: widget.size / 4,
                height: widget.size / 4,
                decoration: BoxDecoration(
                  color: widget.isOnline
                      ? Theme.of(context).colorScheme.success
                      : colorScheme.onSurface.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                  border: Border.all(color: colorScheme.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _getInitials(String name) {
    final parts = name.trim().split(' ');
    if (parts.isEmpty) return 'U';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  /// Generate consistent color for user based on name
  /// Uses theme-compatible pastel colors for better visual harmony
  Color _getColorForUser(String name) {
    return AvatarColors.colorForName(name);
  }
}
