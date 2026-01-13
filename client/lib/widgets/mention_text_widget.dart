import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/user_profile_service.dart';
import 'user_profile_card_overlay.dart';

/// Widget for rendering text with @mention highlighting
///
/// Features:
/// - Highlights @mentions in primary color (#0E8481)
/// - Shows user profile card on hover
/// - Opens direct message on click (if not current user)
class MentionTextWidget extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final String? currentUserId;
  final Map<String, dynamic>?
  senderInfo; // Optional: {uuid, displayName, atName}

  const MentionTextWidget({
    super.key,
    required this.text,
    this.style,
    this.currentUserId,
    this.senderInfo,
  });

  @override
  State<MentionTextWidget> createState() => _MentionTextWidgetState();
}

class _MentionTextWidgetState extends State<MentionTextWidget> {
  OverlayEntry? _profileCardOverlay;
  final Map<String, Map<String, dynamic>> _userCache = {};
  Offset? _lastMousePosition;

  @override
  void dispose() {
    _profileCardOverlay?.remove();
    super.dispose();
  }

  void _showProfileCard(
    BuildContext context,
    String atName,
    Offset mousePosition,
  ) async {
    _profileCardOverlay?.remove();
    _lastMousePosition = mousePosition;

    // Try to find user by atName
    final userInfo = await _findUserInfo(atName);
    if (userInfo == null || !mounted) return;

    final userId = userInfo['uuid'] as String;
    final displayName = userInfo['displayName'] as String;
    final pictureData = userInfo['picture'] as String?;
    final userAtName = userInfo['atName'] as String?;

    _profileCardOverlay = OverlayEntry(
      builder: (context) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          _profileCardOverlay?.remove();
          _profileCardOverlay = null;
        },
        child: Stack(
          children: [
            UserProfileCardOverlay(
              userId: userId,
              displayName: displayName,
              atName: userAtName,
              pictureData: pictureData,
              isOnline: false,
              lastSeen: null,
              mousePosition: _lastMousePosition ?? Offset.zero,
            ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    // ignore: use_build_context_synchronously
    Overlay.of(context).insert(_profileCardOverlay!);
  }

  void _hideProfileCard() {
    _profileCardOverlay?.remove();
    _profileCardOverlay = null;
  }

  /// Find user info by @atName
  /// If senderInfo is provided and matches, use that directly
  Future<Map<String, dynamic>?> _findUserInfo(String atName) async {
    // Check if this mention refers to the sender (optimization)
    if (widget.senderInfo != null) {
      final senderAtName = widget.senderInfo!['atName'] as String?;
      if (senderAtName?.toLowerCase() == atName.toLowerCase()) {
        return widget.senderInfo;
      }
    }

    // Check local cache first
    if (_userCache.containsKey(atName)) {
      return _userCache[atName];
    }

    // Search in UserProfileService cache by atName
    final profile = UserProfileService.instance.getProfileByAtName(atName);
    if (profile != null) {
      _userCache[atName] = profile;
      return profile;
    }

    debugPrint('[MENTION] User not found in cache: @$atName');
    return null;
  }

  void _handleMentionTap(String atName) async {
    final userInfo = await _findUserInfo(atName);
    if (userInfo == null) return;

    final userId = userInfo['uuid'] as String;

    // Don't open DM with yourself
    if (userId == widget.currentUserId) return;

    if (!mounted) return;

    // Navigate to direct messages with this user
    context.go('/app/messages/$userId');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final defaultStyle =
        widget.style ??
        TextStyle(color: theme.colorScheme.onSurface, fontSize: 15);

    // Parse text and find @mentions
    final mentionRegex = RegExp(r'@(\w+)');
    final matches = mentionRegex.allMatches(widget.text);

    if (matches.isEmpty) {
      // No mentions, return plain text
      return Text(widget.text, style: defaultStyle);
    }

    // Build TextSpan with highlighted mentions
    final spans = <InlineSpan>[];
    int lastIndex = 0;

    for (final match in matches) {
      // Add text before mention
      if (match.start > lastIndex) {
        spans.add(
          TextSpan(
            text: widget.text.substring(lastIndex, match.start),
            style: defaultStyle,
          ),
        );
      }

      // Add mention with highlighting
      final atName = match.group(1)!;
      final mentionText = '@$atName';

      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (event) {
              _showProfileCard(context, atName, event.position);
            },
            onExit: (_) {
              _hideProfileCard();
            },
            child: GestureDetector(
              onTap: () => _handleMentionTap(atName),
              child: Text(
                mentionText,
                style: defaultStyle.copyWith(
                  color: primaryColor,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      );

      lastIndex = match.end;
    }

    // Add remaining text
    if (lastIndex < widget.text.length) {
      spans.add(
        TextSpan(text: widget.text.substring(lastIndex), style: defaultStyle),
      );
    }

    return RichText(text: TextSpan(children: spans));
  }
}
