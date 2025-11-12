import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'file_message_widget.dart';
import 'user_avatar.dart';
import 'voice_message_player.dart';
import '../models/file_message.dart';
import 'dart:convert';

/// Reusable widget for displaying a list of messages
/// Works for both Direct Messages and Group Chats
class MessageList extends StatelessWidget {
  final List<Map<String, dynamic>> messages;
  final void Function(FileMessage)? onFileDownload;
  final ScrollController? scrollController;

  const MessageList({
    super.key,
    required this.messages,
    this.onFileDownload,
    this.scrollController,
  });

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
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.done_all, size: 16, color: Colors.green),
            const SizedBox(width: 4),
            Text(
              'Read by all',
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
          ],
        );
      } else if (readCount != null && readCount > 0) {
        // Some read - grey double check with count
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.done_all, size: 16, color: Colors.grey),
            const SizedBox(width: 4),
            Text(
              'Read by $readCount of $totalCount',
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
          ],
        );
      } else if (deliveredCount != null && deliveredCount == totalCount) {
        // All delivered but not read
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.done_all, size: 16, color: Colors.grey),
            const SizedBox(width: 4),
            Text(
              'Delivered to all',
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
          ],
        );
      } else if (deliveredCount != null && deliveredCount > 0) {
        // Some delivered
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check, size: 16, color: Colors.grey),
            const SizedBox(width: 4),
            Text(
              'Delivered to $deliveredCount of $totalCount',
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
          ],
        );
      } else if (status == 'delivered') {
        // Delivered to server, waiting for reads
        return const Icon(Icons.check, size: 16, color: Colors.grey);
      }
    }

    // Standard 1:1 message status
    switch (status) {
      case 'sending':
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey),
        );
      case 'sent':
        // Sent to server, waiting for delivery confirmation
        return const Icon(Icons.check, size: 16, color: Colors.grey);
      case 'delivered':
        return const Icon(Icons.check, size: 16, color: Colors.grey);
      case 'read':
        return const Icon(Icons.done_all, size: 16, color: Colors.green);
      case 'failed':
        return const Icon(Icons.error_outline, size: 16, color: Colors.red);
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text(
              'No messages yet',
              style: TextStyle(color: Colors.grey[600], fontSize: 18),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(24),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        final sender = msg['senderDisplayName'] ?? msg['sender'] ?? 'Unknown';
        final text = msg['payload'] ?? msg['text'] ?? msg['message'] ?? '';
        final timeStr = msg['time'] ?? '';
        final isLocalSent = msg['isLocalSent'] == true;
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
          final prevTimeStr = messages[index - 1]['time'] ?? '';
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
                    Expanded(child: Divider(color: Colors.grey[700], thickness: 1)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        _getDateDividerText(msgTime),
                        style: TextStyle(
                          color: Colors.grey[500],
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Expanded(child: Divider(color: Colors.grey[700], thickness: 1)),
                  ],
                ),
              ),
            // Message
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UserAvatar(
                    userId: msg['sender'],
                    displayName: sender,
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              sender,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isLocalSent ? theme.colorScheme.primary : Colors.white,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatTime(msgTime),
                              style: const TextStyle(color: Colors.white54, fontSize: 13),
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
            Container(
              constraints: const BoxConstraints(maxWidth: 300, maxHeight: 400),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[700]!, width: 1),
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
                        Icon(Icons.broken_image, size: 48, color: Colors.grey[600]),
                        const SizedBox(height: 8),
                        Text(
                          'Failed to load image',
                          style: TextStyle(color: Colors.grey[500]),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (metadata != null && metadata['size'] != null) ...[
              const SizedBox(height: 4),
              Text(
                '${(metadata['size'] / 1024).toStringAsFixed(1)} KB',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
            ],
          ],
        );
      } catch (e) {
        debugPrint('[MESSAGE_LIST] Failed to render image: $e');
        return Text(
          'Image (failed to load)',
          style: TextStyle(color: Colors.red[300], fontStyle: FontStyle.italic),
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
          return Text(
            'Voice message (no audio data)',
            style: TextStyle(color: Colors.red[300], fontStyle: FontStyle.italic),
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
        return Text(
          'Voice message (failed to load)',
          style: TextStyle(color: Colors.red[300], fontStyle: FontStyle.italic),
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
          onDownloadWithMessage: onFileDownload ?? (fileMsg) {
            debugPrint('[MESSAGE_LIST] Download requested for: ${fileMsg.fileId} (no handler provided)');
          },
        );
      } catch (e) {
        debugPrint('[MESSAGE_LIST] Failed to parse file message: $e');
        // Fallback to text rendering
        return Text(
          'File message (failed to load)',
          style: TextStyle(color: Colors.red[300], fontStyle: FontStyle.italic),
        );
      }
    }
    
    // Default: Render as markdown text
    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(color: Colors.white, fontSize: 15),
        strong: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        em: const TextStyle(color: Colors.white, fontStyle: FontStyle.italic),
        del: const TextStyle(color: Colors.white, decoration: TextDecoration.lineThrough),
        code: TextStyle(
          backgroundColor: Colors.grey[800],
          color: Colors.amber[300],
          fontFamily: 'monospace',
        ),
        codeblockDecoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey[700]!),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        blockquote: TextStyle(color: Colors.grey[400], fontStyle: FontStyle.italic),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: Colors.grey[600]!, width: 4)),
        ),
        listBullet: const TextStyle(color: Colors.white),
        a: const TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
        h1: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
        h2: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
        h3: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
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


