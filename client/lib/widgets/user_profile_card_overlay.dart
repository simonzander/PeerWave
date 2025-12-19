import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'user_avatar.dart';
import '../theme/app_theme_constants.dart';

/// User Profile Card Overlay - Shows on hover over avatar/name
/// 
/// Displays like an ID card with:
/// - Left: Square profile picture (same as people_screen cards)
/// - Right: User details (displayName, @atName, online status, last seen)
class UserProfileCardOverlay extends StatelessWidget {
  final String userId;
  final String displayName;
  final String? atName;
  final String? pictureData;
  final bool isOnline;
  final DateTime? lastSeen;
  final Offset mousePosition;

  const UserProfileCardOverlay({
    super.key,
    required this.userId,
    required this.displayName,
    this.atName,
    this.pictureData,
    this.isOnline = false,
    this.lastSeen,
    required this.mousePosition,
  });

  String _formatLastSeen(DateTime lastSeen) {
    final now = DateTime.now();
    final difference = now.difference(lastSeen);
    
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return DateFormat('MMM d, yyyy').format(lastSeen);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: mousePosition.dx + 15, // 15px to the right of cursor
      top: mousePosition.dy - 60, // Centered vertically around cursor
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(12),
        color: AppThemeConstants.contextPanelBackground,
        child: Container(
          width: 320,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppThemeConstants.textSecondary.withValues(alpha: 0.2),
              width: 1,
            ),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppThemeConstants.contextPanelBackground,
                AppThemeConstants.contextPanelBackground.withValues(alpha: 0.95),
              ],
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left side: Square profile picture
              SquareUserAvatar(
                userId: userId,
                displayName: displayName,
                pictureData: pictureData,
                size: 80,
              ),
              
              const SizedBox(width: 16),
              
              // Right side: User details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Display Name
                    Text(
                      displayName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppThemeConstants.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    
                    // @atName
                    if (atName != null && atName!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '@$atName',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppThemeConstants.textSecondary.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                    
                    const SizedBox(height: 12),
                    
                    // Divider
                    Container(
                      height: 1,
                      color: AppThemeConstants.textSecondary.withValues(alpha: 0.2),
                    ),
                    
                    const SizedBox(height: 12),
                    
                    // Online status
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: isOnline ? Colors.green : Colors.grey,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          isOnline ? 'Online' : 'Offline',
                          style: TextStyle(
                            fontSize: 13,
                            color: isOnline 
                                ? Colors.green 
                                : AppThemeConstants.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    
                    // Last seen (if offline)
                    if (!isOnline && lastSeen != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            Icons.access_time,
                            size: 14,
                            color: AppThemeConstants.textSecondary.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Last seen ${_formatLastSeen(lastSeen!)}',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppThemeConstants.textSecondary.withValues(alpha: 0.7),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
