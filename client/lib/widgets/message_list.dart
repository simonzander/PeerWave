import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'file_message_widget.dart';
import 'user_avatar.dart';
import 'user_profile_card_overlay.dart';
import 'voice_message_player.dart';
import 'mention_text_widget.dart';
import 'emoji_picker_dialog.dart';
import 'reaction_badge.dart';
import '../models/file_message.dart';
import '../services/signal_service.dart';
import '../services/user_profile_service.dart';

/// Reusable widget for displaying a list of messages
/// Works for both Direct Messages and Group Chats
class MessageList extends StatefulWidget {
  final List<Map<String, dynamic>> messages;
  final void Function(FileMessage)? onFileDownload;
  final ScrollController? scrollController;
  final Function(String messageId, String emoji)? onReactionAdd;
  final Function(String messageId, String emoji)? onReactionRemove;
  final String? currentUserId;
  final String? highlightedMessageId; // For highlighting target message

  const MessageList({
    super.key,
    required this.messages,
    this.onFileDownload,
    this.scrollController,
    this.onReactionAdd,
    this.onReactionRemove,
    this.currentUserId,
    this.highlightedMessageId,
  });

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  OverlayEntry? _profileCardOverlay;
  
  @override
  void dispose() {
    _profileCardOverlay?.remove();
    super.dispose();
  }
  
  void _showProfileCard(BuildContext context, Map<String, dynamic> msg, Offset mousePosition) {
    _profileCardOverlay?.remove();
    
    final sender = msg['senderDisplayName'] as String? ?? 'Unknown';
    final userId = msg['sender'] as String? ?? '';
    
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
              displayName: sender,
              atName: null, // TODO: Load from UserProfileService if needed
              pictureData: null, // TODO: Load from UserProfileService if needed
              isOnline: false, // TODO: Load online status
              lastSeen: null, // TODO: Load last seen
              mousePosition: mousePosition,
            ),
          ],
        ),
      ),
    );
    
    Overlay.of(context).insert(_profileCardOverlay!);
  }
  
  void _hideProfileCard() {
    _profileCardOverlay?.remove();
    _profileCardOverlay = null;
  }

  /// Format timestamp for display
  String _formatTime(DateTime time) {
    return DateFormat('HH:mm').format(time);
  }

  /// Get date divider text (Today / Yesterday / Weekday / Full Date)
  String _getDateDividerText(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(date.year, date.month, date.day);

    final daysDifference = today.difference(messageDate).inDays;

    if (messageDate == today) {
      return 'Today';
    } else if (messageDate == yesterday) {
      return 'Yesterday';
    } else if (daysDifference <= 7) {
      return DateFormat('EEEE').format(date);
    } else {
      return DateFormat('dd.MM.yyyy').format(date);
    }
  }

  /// Check if we need a date divider between two messages
  bool _needsDateDivider(DateTime? previousDate, DateTime currentDate) {
    if (previousDate == null) return true;

    final prevDay = DateTime(previousDate.year, previousDate.month, previousDate.day);
    final currDay = DateTime(currentDate.year, currentDate.month, currentDate.day);

    return prevDay != currDay;
  }

  /// Build status icon for message (sending/delivered/read)
  Widget _buildMessageStatus(Map<String, dynamic> message) {
    final status = message['status'] ?? 'sending';
    final readCount = message['readCount'] as int?;
    final deliveredCount = message['deliveredCount'] as int?;
    final totalCount = message['totalCount'] as int?;
    final isGroupMessage = totalCount != null && totalCount > 0;

    // For group messages, show counts
    if (isGroupMessage) {
      if (status == 'read' || (readCount != null && readCount == totalCount)) {
        // All read - green double check
        final theme = Theme.of(context);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.done_all, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
            Text(
              'Read by all',
              style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.5)),
            ),
          ],
        );
      } else if (readCount != null && readCount > 0) {
        // Some read - grey double check with count
        final theme = Theme.of(context);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.done_all, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.5)),
            const SizedBox(width: 4),
            Text(
              'Read by $readCount of $totalCount',
              style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.5)),
            ),
          ],
        );
      } else if (deliveredCount != null && deliveredCount == totalCount) {
        // All delivered but not read
        final theme = Theme.of(context);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.done_all, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.5)),
            const SizedBox(width: 4),
            Text(
              'Delivered to all',
              style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.5)),
            ),
          ],
        );
      } else if (deliveredCount != null && deliveredCount > 0) {
        // Some delivered
        final theme = Theme.of(context);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.5)),
            const SizedBox(width: 4),
            Text(
              'Delivered to $deliveredCount of $totalCount',
              style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.5)),
            ),
          ],
        );
      } else if (status == 'delivered') {
        // Delivered to server, waiting for reads
        final theme = Theme.of(context);
        return Icon(Icons.check, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.5));
      }
    }

    // Standard 1:1 message status
    final theme = Theme.of(context);
    switch (status) {
      case 'sending':
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.onSurface.withOpacity(0.5)),
        );
      case 'sent':
        // Sent to server, waiting for delivery confirmation
        return Icon(Icons.check, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.5));
      case 'delivered':
        return Icon(Icons.check, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.5));
      case 'read':
        return Icon(Icons.done_all, size: 16, color: theme.colorScheme.primary);
      case 'failed':
        return Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error);
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 64, color: theme.colorScheme.onSurface.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text(
              'No messages yet',
              style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 18),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(24),
      itemCount: widget.messages.length,
      itemBuilder: (context, index) {
        final msg = widget.messages[index];
        final sender = msg['senderDisplayName'] ?? msg['sender'] ?? 'Unknown';
        final text = msg['payload'] ?? msg['text'] ?? msg['message'] ?? '';
        final timeStr = msg['time'] ?? '';
        final isLocalSent = msg['isLocalSent'] == true;
        final itemId = msg['itemId'] as String?;
        final isHighlighted = widget.highlightedMessageId != null && 
                              itemId == widget.highlightedMessageId;
        final theme = Theme.of(context);

        // Parse timestamp
        DateTime? msgTime;
        try {
          msgTime = DateTime.parse(timeStr);
        } catch (e) {
          msgTime = DateTime.now();
        }

        // Check if we need date divider
        DateTime? previousMsgTime;
        if (index > 0) {
          final prevTimeStr = widget.messages[index - 1]['time'] ?? '';
          try {
            previousMsgTime = DateTime.parse(prevTimeStr);
          } catch (e) {
            // ignore
          }
        }

        final showDivider = _needsDateDivider(previousMsgTime, msgTime);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Date divider
            if (showDivider)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  children: [
                    Expanded(child: Divider(color: theme.colorScheme.onSurface.withOpacity(0.2), thickness: 1)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        _getDateDividerText(msgTime),
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withOpacity(0.5),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Expanded(child: Divider(color: theme.colorScheme.onSurface.withOpacity(0.2), thickness: 1)),
                  ],
                ),
              ),
            // Message
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              decoration: isHighlighted ? BoxDecoration(
                color: theme.colorScheme.primaryContainer.withOpacity(0.3),
                border: Border.all(
                  color: theme.colorScheme.primary,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(12),
              ) : null,
              padding: isHighlighted ? const EdgeInsets.all(4) : null,
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Avatar with hover
                  MouseRegion(
                    onEnter: (event) => _showProfileCard(context, msg, event.position),
                    onExit: (_) => _hideProfileCard(),
                    cursor: SystemMouseCursors.click,
                    child: SquareUserAvatar(
                      userId: msg['sender'],
                      displayName: sender,
                      size: 40,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            // Username with hover
                            MouseRegion(
                              onEnter: (event) => _showProfileCard(context, msg, event.position),
                              onExit: (_) => _hideProfileCard(),
                              cursor: SystemMouseCursors.click,
                              child: Text(
                                sender,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: isLocalSent ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatTime(msgTime),
                              style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13),
                            ),
                            if (isLocalSent) ...[
                              const SizedBox(width: 8),
                              _buildMessageStatus(msg),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        // Check if this is a file message
                        _buildMessageContent(msg, text),
                        // Emoji reactions
                        const SizedBox(height: 6),
                        _buildReactions(msg),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Build emoji reactions row for a message
  Widget _buildReactions(Map<String, dynamic> msg) {
    final messageId = msg['itemId'] as String?;
    if (messageId == null) return const SizedBox.shrink();
    
    // Get reactions from message data
    final reactionsData = msg['reactions'];
    Map<String, dynamic> reactions = {};
    
    debugPrint('[MESSAGE_LIST] Building reactions for $messageId: reactionsData=$reactionsData (type: ${reactionsData.runtimeType})');
    
    if (reactionsData is String && reactionsData.isNotEmpty && reactionsData != '{}') {
      try {
        reactions = jsonDecode(reactionsData) as Map<String, dynamic>;
        debugPrint('[MESSAGE_LIST] Parsed reactions: $reactions (${reactions.length} emojis)');
      } catch (e) {
        debugPrint('[MESSAGE_LIST] Failed to parse reactions: $e');
      }
    } else if (reactionsData is Map) {
      reactions = Map<String, dynamic>.from(reactionsData);
      debugPrint('[MESSAGE_LIST] Using Map reactions: $reactions (${reactions.length} emojis)');
    }
    
    if (reactions.isEmpty) {
      debugPrint('[MESSAGE_LIST] No reactions for message $messageId');
    }
    
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        // Emoji add button (+)
        InkWell(
          onTap: () => _showEmojiPicker(messageId),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.add_reaction_outlined,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.add,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        
        // Existing reaction badges
        ...reactions.entries.map((entry) {
          final emoji = entry.key;
          final usersList = entry.value;
          final users = usersList is List ? usersList.cast<String>() : <String>[];
          final count = users.length;
          final isActive = widget.currentUserId != null && users.contains(widget.currentUserId);
          
          return ReactionBadge(
            emoji: emoji,
            count: count,
            isActive: isActive,
            onTap: () => _toggleReaction(messageId, emoji, isActive),
          );
        }),
      ],
    );
  }

  /// Show emoji picker to add a reaction
  void _showEmojiPicker(String messageId) {
    EmojiPickerDialog.show(
      context,
      (emoji) {
        if (widget.onReactionAdd != null) {
          widget.onReactionAdd!(messageId, emoji);
        }
      },
    );
  }

  /// Toggle a reaction (add if not present, remove if already reacted)
  void _toggleReaction(String messageId, String emoji, bool isActive) {
    if (isActive) {
      // Remove reaction
      if (widget.onReactionRemove != null) {
        widget.onReactionRemove!(messageId, emoji);
      }
    } else {
      // Add reaction
      if (widget.onReactionAdd != null) {
        widget.onReactionAdd!(messageId, emoji);
      }
    }
  }

  /// Build warning for identity key changes
  Widget _buildIdentityChangeWarning(Map<String, dynamic> msg) {
    final sender = msg['senderDisplayName'] ?? msg['sender'] ?? 'Unknown';
    final theme = Theme.of(context);
    final warningColor = theme.brightness == Brightness.dark 
        ? const Color(0xFFFFA726) // Amber 400
        : const Color(0xFFFF8F00); // Amber 900
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: warningColor.withOpacity(0.15),
        border: Border.all(color: warningColor.withOpacity(0.5), width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.security,
            color: warningColor,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Security code changed',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$sender\'s security code changed. This happens when they reinstall the app or switch devices. Messages are still secure.',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface.withOpacity(0.8),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build message content based on type (text, image, voice, or file)
  Widget _buildMessageContent(Map<String, dynamic> msg, String text) {
    final type = msg['type'] as String?;
    final metadata = msg['metadata'];
    
    // Image message - display base64 image
    if (type == 'image') {
      try {
        final base64Image = text;
        final imageBytes = base64Decode(base64Image);
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () {
                // Show fullscreen image viewer
                showDialog(
                  context: context,
                  barrierColor: Colors.black87,
                  builder: (context) => _FullscreenImageViewer(
                    imageBytes: imageBytes,
                    metadata: metadata,
                  ),
                );
              },
              child: Container(
                constraints: const BoxConstraints(maxWidth: 300, maxHeight: 400),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.5), width: 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.memory(
                  imageBytes,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Icon(Icons.broken_image, size: 48, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4)),
                          const SizedBox(height: 8),
                          Text(
                            'Failed to load image',
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            if (metadata != null && metadata['size'] != null) ...[
              const SizedBox(height: 4),
              Text(
                '${(metadata['size'] / 1024).toStringAsFixed(1)} KB',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5), fontSize: 12),
              ),
            ],
          ],
        );
      } catch (e) {
        debugPrint('[MESSAGE_LIST] Failed to render image: $e');
        final errorTheme = Theme.of(context);
        return Text(
          'Image (failed to load)',
          style: TextStyle(color: errorTheme.colorScheme.error, fontStyle: FontStyle.italic),
        );
      }
    }
    
    // Voice message - display audio player with waveform
    if (type == 'voice') {
      try {
        final base64Audio = msg['message'] ?? '';
        final duration = metadata?['duration'] ?? 0;
        final size = metadata?['size'];
        final isOwnMessage = msg['isLocalSent'] == true;
        
        if (base64Audio.isEmpty) {
          final errorTheme = Theme.of(context);
          return Text(
            'Voice message (no audio data)',
            style: TextStyle(color: errorTheme.colorScheme.error, fontStyle: FontStyle.italic),
          );
        }
        
        return VoiceMessagePlayer(
          base64Audio: base64Audio,
          durationSeconds: duration,
          sizeBytes: size,
          isOwnMessage: isOwnMessage,
        );
      } catch (e) {
        debugPrint('[MESSAGE_LIST] Failed to render voice message: $e');
        final errorTheme = Theme.of(context);
        return Text(
          'Voice message (failed to load)',
          style: TextStyle(color: errorTheme.colorScheme.error, fontStyle: FontStyle.italic),
        );
      }
    }
    
    // File message (P2P)
    if (type == 'file') {
      try {
        // Parse the file message payload
        final payloadJson = msg['payload'] ?? msg['message'] ?? text;
        final fileData = payloadJson is String ? jsonDecode(payloadJson) : payloadJson;
        final fileMessage = FileMessage.fromJson(fileData);
        
        final isOwnMessage = msg['isLocalSent'] == true;
        debugPrint('[MESSAGE_LIST] Rendering file message: isLocalSent=${msg['isLocalSent']}, isOwnMessage=$isOwnMessage');
        
        return FileMessageWidget(
          fileMessage: fileMessage,
          isOwnMessage: isOwnMessage,
          onDownloadWithMessage: widget.onFileDownload ?? (fileMsg) {
            debugPrint('[MESSAGE_LIST] Download requested for: ${fileMsg.fileId} (no handler provided)');
          },
        );
      } catch (e) {
        debugPrint('[MESSAGE_LIST] Failed to parse file message: $e');
        // Fallback to text rendering
        final errorTheme = Theme.of(context);
        return Text(
          'File message (failed to load)',
          style: TextStyle(color: errorTheme.colorScheme.error, fontStyle: FontStyle.italic),
        );
      }
    }
    
    // System message: Identity Key Changed
    if (type == 'system:identityKeyChanged') {
      return _buildIdentityChangeWarning(msg);
    }
    
    // Check if text contains @mentions and no markdown formatting
    final hasMentions = text.contains(RegExp(r'@\w+'));
    final hasMarkdown = text.contains(RegExp(r'[*_`\[\]#]'));
    
    // If text has mentions but no markdown, use MentionTextWidget for highlighting
    if (hasMentions && !hasMarkdown) {
      // Get sender profile for optimization (sender info already loaded for message display)
      final sender = msg['sender'] as String?;
      final senderProfile = sender != null 
        ? UserProfileService.instance.getProfile(sender) 
        : null;
      final mentionTheme = Theme.of(context);
      
      return MentionTextWidget(
        text: text,
        style: TextStyle(color: mentionTheme.colorScheme.onSurface, fontSize: 15),
        currentUserId: SignalService.instance.currentUserId,
        senderInfo: senderProfile,
      );
    }
    
    // Default: Render as markdown text
    final markdownTheme = Theme.of(context);
    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(color: markdownTheme.colorScheme.onSurface, fontSize: 15),
        strong: TextStyle(color: markdownTheme.colorScheme.onSurface, fontWeight: FontWeight.bold),
        em: TextStyle(color: markdownTheme.colorScheme.onSurface, fontStyle: FontStyle.italic),
        del: TextStyle(color: markdownTheme.colorScheme.onSurface, decoration: TextDecoration.lineThrough),
        code: TextStyle(
          backgroundColor: markdownTheme.colorScheme.surfaceVariant,
          color: markdownTheme.colorScheme.primary,
          fontFamily: 'monospace',
        ),
        codeblockDecoration: BoxDecoration(
          color: markdownTheme.colorScheme.surfaceVariant.withOpacity(0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: markdownTheme.colorScheme.outline),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        blockquote: TextStyle(color: markdownTheme.colorScheme.onSurface.withOpacity(0.6), fontStyle: FontStyle.italic),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: markdownTheme.colorScheme.outline, width: 4)),
        ),
        listBullet: TextStyle(color: markdownTheme.colorScheme.onSurface),
        a: TextStyle(color: markdownTheme.colorScheme.primary, decoration: TextDecoration.underline),
        h1: TextStyle(color: markdownTheme.colorScheme.onSurface, fontSize: 24, fontWeight: FontWeight.bold),
        h2: TextStyle(color: markdownTheme.colorScheme.onSurface, fontSize: 20, fontWeight: FontWeight.bold),
        h3: TextStyle(color: markdownTheme.colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.bold),
      ),
      onTapLink: (text, href, title) async {
        if (href != null) {
          final uri = Uri.parse(href);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        }
      },
    );
  }
}

/// Fullscreen image viewer with close button
class _FullscreenImageViewer extends StatelessWidget {
  final Uint8List imageBytes;
  final dynamic metadata;

  const _FullscreenImageViewer({
    required this.imageBytes,
    this.metadata,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background tap to close
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(color: Colors.transparent),
          ),
          
          // Image in center
          Center(
            child: GestureDetector(
              onTap: () {}, // Prevent closing when tapping image
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.memory(
                  imageBytes,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          
          // Close button in top-right corner
          Positioned(
            top: 40,
            right: 20,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 32),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withOpacity(0.5),
                padding: const EdgeInsets.all(8),
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          
          // Image info at bottom (if available)
          if (metadata != null)
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                margin: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (metadata['filename'] != null)
                      Text(
                        metadata['filename'] as String,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                    if (metadata['originalSize'] != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Size: ${(metadata['originalSize'] / 1024).toStringAsFixed(1)} KB',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7), fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
