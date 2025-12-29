import 'package:flutter/material.dart';
import 'dart:convert';
import '../utils/image_color_extractor.dart';
import '../theme/avatar_colors.dart';

/// Widget that displays a participant's profile picture with a colored background
/// when their camera is deactivated
class ParticipantProfileDisplay extends StatefulWidget {
  final String profilePictureBase64;
  final String displayName;
  final double size;

  const ParticipantProfileDisplay({
    super.key,
    required this.profilePictureBase64,
    required this.displayName,
    this.size = 150,
  });

  @override
  State<ParticipantProfileDisplay> createState() =>
      _ParticipantProfileDisplayState();
}

class _ParticipantProfileDisplayState extends State<ParticipantProfileDisplay> {
  Color? _backgroundColor;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _extractBackgroundColor();
  }

  @override
  void didUpdateWidget(ParticipantProfileDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only re-extract if the actual content changed (not just reference)
    // Compare actual string content to prevent unnecessary updates
    if (oldWidget.profilePictureBase64 != widget.profilePictureBase64) {
      // Reset state before re-extracting
      _isLoading = true;
      _extractBackgroundColor();
    }
  }

  Future<void> _extractBackgroundColor() async {
    if (widget.profilePictureBase64.isEmpty) {
      setState(() {
        _backgroundColor = AvatarColors.defaultProfile;
        _isLoading = false;
      });
      return;
    }

    try {
      final color = await ImageColorExtractor.extractDominantColor(
        widget.profilePictureBase64,
      );
      if (mounted) {
        setState(() {
          _backgroundColor = color;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[ParticipantProfileDisplay] Error extracting color: $e');
      if (mounted) {
        setState(() {
          _backgroundColor = AvatarColors.defaultProfile;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        color: Theme.of(context).colorScheme.surface,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    return Container(
      decoration: BoxDecoration(
        gradient: _backgroundColor != null
            ? ImageColorExtractor.createGradientFromColor(_backgroundColor!)
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AvatarColors.defaultProfile.withValues(alpha: 0.6),
                  AvatarColors.defaultProfile.withValues(alpha: 0.3),
                ],
              ),
      ),
      child: Center(child: _buildProfileContent()),
    );
  }

  Widget _buildProfileContent() {
    if (widget.profilePictureBase64.isEmpty) {
      return _buildFallbackAvatar();
    }

    try {
      // Remove data URL prefix if present
      String cleanBase64 = widget.profilePictureBase64;
      if (cleanBase64.contains(',')) {
        cleanBase64 = cleanBase64.split(',')[1];
      }

      final bytes = base64Decode(cleanBase64);

      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.shadow.withValues(alpha: 0.3),
              blurRadius: 20,
              spreadRadius: 5,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(
            bytes,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              debugPrint(
                '[ParticipantProfileDisplay] Error loading image: $error',
              );
              return _buildFallbackAvatar();
            },
          ),
        ),
      );
    } catch (e) {
      debugPrint('[ParticipantProfileDisplay] Error decoding base64: $e');
      return _buildFallbackAvatar();
    }
  }

  Widget _buildFallbackAvatar() {
    final initial = widget.displayName.isNotEmpty
        ? widget.displayName[0].toUpperCase()
        : '?';

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.3),
            blurRadius: 20,
            spreadRadius: 5,
          ),
        ],
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: widget.size * 0.4,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
