import 'package:flutter/material.dart';
import 'dart:convert';
import '../services/user_profile_service.dart';

/// Widget to display user avatar with picture or initials
class UserAvatar extends StatelessWidget {
  final String? userId;
  final String? displayName;
  final String? pictureData; // base64 or URL
  final double size;
  final bool showOnlineStatus;
  final bool isOnline;

  const UserAvatar({
    Key? key,
    this.userId,
    this.displayName,
    this.pictureData,
    this.size = 40,
    this.showOnlineStatus = false,
    this.isOnline = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    // Try to get profile from service if userId is provided
    String? effectiveDisplayName = displayName;
    String? effectivePicture = pictureData;
    
    final userIdValue = userId;
    if (userIdValue != null && userIdValue.isNotEmpty) {
      final profile = UserProfileService.instance.getProfile(userIdValue);
      if (profile != null) {
        effectiveDisplayName ??= profile['displayName'];
        effectivePicture ??= profile['picture'];
      }
    }
    
    // Fallback to userId if no displayName
    effectiveDisplayName ??= userId ?? 'U';
    
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
        } else if (effectivePicture.startsWith('http://') || effectivePicture.startsWith('https://')) {
          // URL
          imageProvider = NetworkImage(effectivePicture);
        }
      } catch (e) {
        print('[UserAvatar] Error parsing picture: $e');
      }
    }
    
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: size / 2,
            backgroundColor: imageProvider == null 
                ? _getColorForUser(effectiveDisplayName)
                : Colors.transparent,
            backgroundImage: imageProvider,
            child: imageProvider == null
                ? Text(
                    initials,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: size / 2.5,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : null,
          ),
          // Online status indicator
          if (showOnlineStatus)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: size / 4,
                height: size / 4,
                decoration: BoxDecoration(
                  color: isOnline ? Colors.green : Colors.grey,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colorScheme.surface,
                    width: 2,
                  ),
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
  Color _getColorForUser(String name) {
    final hash = name.hashCode;
    final colors = [
      const Color(0xFF5865F2), // Blurple
      const Color(0xFFEB459E), // Pink
      const Color(0xFFED4245), // Red
      const Color(0xFFFEE75C), // Yellow
      const Color(0xFF57F287), // Green
      const Color(0xFF00D9FF), // Cyan
      const Color(0xFFFF6B6B), // Coral
      const Color(0xFF9B59B6), // Purple
      const Color(0xFF3498DB), // Blue
      const Color(0xFFE67E22), // Orange
    ];
    return colors[hash.abs() % colors.length];
  }
}

/// Small variant for compact lists
class SmallUserAvatar extends StatelessWidget {
  final String? userId;
  final String? displayName;
  final String? pictureData;

  const SmallUserAvatar({
    Key? key,
    this.userId,
    this.displayName,
    this.pictureData,
  }) : super(key: key);

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
    Key? key,
    this.userId,
    this.displayName,
    this.pictureData,
    this.showOnlineStatus = false,
    this.isOnline = false,
  }) : super(key: key);

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
