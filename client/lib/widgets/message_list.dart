import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';

/// Reusable widget for displaying a list of messages
/// Works for both Direct Messages and Group Chats
class MessageList extends StatelessWidget {
  final List<Map<String, dynamic>> messages;

  const MessageList({
    super.key,
    required this.messages,
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
      padding: const EdgeInsets.all(24),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        final sender = msg['senderDisplayName'] ?? msg['sender'] ?? 'Unknown';
        final text = msg['payload'] ?? msg['text'] ?? msg['message'] ?? '';
        final timeStr = msg['time'] ?? '';
        final isLocalSent = msg['isLocalSent'] == true;

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
                  CircleAvatar(
                    backgroundColor: isLocalSent ? Colors.blue : Colors.grey,
                    child: Text(sender.isNotEmpty ? sender[0] : '?'),
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
                                color: isLocalSent ? Colors.blue[300] : Colors.white,
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
                        // Markdown rendering for formatted text
                        MarkdownBody(
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
                        ),
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
}
