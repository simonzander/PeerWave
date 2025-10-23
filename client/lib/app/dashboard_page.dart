import 'package:flutter/material.dart';
import 'sidebar_panel.dart';
import 'profile_card.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:go_router/go_router.dart';
import '../services/api_service.dart';
import '../services/signal_service.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

enum DashboardSubPage { chat, people, directMessage }

class _DashboardPageState extends State<DashboardPage> {
  // Track direct messages: list of {displayName, uuid}
  List<Map<String, String>> _directMessages = [];
  String? _activeDirectMessageUuid;
  String? _activeDirectMessageDisplayName;
  DashboardSubPage _currentSubPage = DashboardSubPage.chat;

  void _onSidebarPeopleTap() {
    setState(() {
      _currentSubPage = DashboardSubPage.people;
    });
  }

  void _onDirectMessageTap(String uuid, String displayName) {
    setState(() {
      _activeDirectMessageUuid = uuid;
      _activeDirectMessageDisplayName = displayName;
      _currentSubPage = DashboardSubPage.directMessage;
    });
  }

  void _addDirectMessage(String uuid, String displayName) {
    // Only add if not already present
    if (!_directMessages.any((dm) => dm['uuid'] == uuid)) {
      setState(() {
        _directMessages.insert(0, {'uuid': uuid, 'displayName': displayName});
      });
    }
    _onDirectMessageTap(uuid, displayName);
  }

  @override
  Widget build(BuildContext context) {
    final extra = GoRouterState.of(context).extra;
    String? host;
    IO.Socket? socket;
    if (extra is Map) {
      host = extra['host'] as String?;
      socket = extra['socket'] as IO.Socket?;
    }
    final bool isWeb = MediaQuery.of(context).size.width > 600 || Theme.of(context).platform == TargetPlatform.macOS || Theme.of(context).platform == TargetPlatform.windows;
    final double sidebarWidth = isWeb ? 350 : 300;


    Widget subPageWidget;
    switch (_currentSubPage) {
      case DashboardSubPage.people:
        subPageWidget = PeopleSubPage(
          host: host ?? '',
          onMessageTap: (uuid, displayName) {
            _addDirectMessage(uuid, displayName);
          },
        );
        break;
      case DashboardSubPage.directMessage:
        subPageWidget = DirectMessageSubPage(
          host: host ?? '',
          uuid: _activeDirectMessageUuid ?? '',
          displayName: _activeDirectMessageDisplayName ?? '',
        );
        break;
      case DashboardSubPage.chat:
        subPageWidget = Column(
          children: [
            // ...existing code...
          ],
        );
        break;
    }

    return Material(
      color: Colors.transparent,
      child: SizedBox.expand(
        child: Row(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                double width = sidebarWidth;
                if (constraints.maxWidth < 600) width = 80;
                return SizedBox(
                  width: width,
                  child: SidebarPanel(
                    panelWidth: width,
                    buildProfileCard: () => const ProfileCard(),
                    socket: socket,
                    host: host ?? '',
                    onPeopleTap: _onSidebarPeopleTap,
                    directMessages: _directMessages,
                    onDirectMessageTap: _onDirectMessageTap,
                  ),
                );
              },
            ),
            Expanded(
              child: Container(
                color: const Color(0xFF36393F),
                child: subPageWidget,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PeopleSubPage extends StatefulWidget {
  final String host;
  final void Function(String uuid, String displayName)? onMessageTap;
  const PeopleSubPage({super.key, required this.host, this.onMessageTap});

  @override
  State<PeopleSubPage> createState() => _PeopleSubPageState();
}

class _PeopleSubPageState extends State<PeopleSubPage> {
  List<dynamic> _people = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchPeople();
  }

  Future<void> _fetchPeople() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // TODO: Replace with your actual token and deviceId logic
      ApiService.init();
      final resp = await ApiService.get('${widget.host}/people/list');
      if (resp.statusCode == 200) {
        setState(() {
          _people = resp.data is String ? [resp.data] : (resp.data as List<dynamic>);
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load people: ${resp.statusCode}';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 18)));
    }
    return ListView.builder(
      itemCount: _people.length,
      itemBuilder: (context, index) {
        final person = _people[index];
        final avatarUrl = person['picture'] ?? '';
        final displayName = person['displayName'] ?? 'Unknown';
        final uuid = person['uuid'] ?? '';
        return ListTile(
          leading: avatarUrl.isNotEmpty
              ? CircleAvatar(backgroundImage: NetworkImage(avatarUrl))
              : const CircleAvatar(child: Icon(Icons.person)),
          title: Text(displayName, style: const TextStyle(color: Colors.white)),
          trailing: IconButton(
            icon: const Icon(Icons.message, color: Colors.amber),
            tooltip: 'Message',
            onPressed: () {
              if (widget.onMessageTap != null) {
                widget.onMessageTap!(uuid, displayName);
              }
            },
          ),
        );
      },
    );
  }
}


// DirectMessageSubPage: shows messages between current user and selected person
class DirectMessageSubPage extends StatefulWidget {
  final String host;
  final String uuid;
  final String displayName;
  const DirectMessageSubPage({super.key, required this.host, required this.uuid, required this.displayName});

  @override
  State<DirectMessageSubPage> createState() => _DirectMessageSubPageState();
}

class _DirectMessageSubPageState extends State<DirectMessageSubPage> {
  List<dynamic> _messages = [];
  String? _error;
  bool _loading = true;
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _showFormatting = false;
  OverlayEntry? _emojiOverlay;
  final LayerLink _emojiLayerLink = LayerLink();

  @override
  void initState() {
    super.initState();
    _fetchMessages();
    _setupMessageListener();
    _setupReceiptListeners();
  }
  
  @override
  void dispose() {
    _emojiOverlay?.remove();
    _emojiOverlay = null;
    SignalService.instance.unregisterItemCallback('message', _handleNewMessage);
    SignalService.instance.clearDeliveryCallbacks();
    SignalService.instance.clearReadCallbacks();
    super.dispose();
  }
  
  void _setupReceiptListeners() {
    // Listen for delivery receipts
    SignalService.instance.onDeliveryReceipt((itemId) {
      print('[DASHBOARD] Delivery receipt callback triggered for itemId: $itemId');
      if (!mounted) {
        print('[DASHBOARD] ⚠ Widget not mounted, ignoring delivery receipt');
        return;
      }
      
      // Update status in PermanentSentMessagesStore (always works, even if not in _messages yet)
      SignalService.instance.sentMessagesStore.markAsDelivered(itemId);
      
      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'delivered';
          print('[DASHBOARD] ✓ Updated message status to delivered in UI');
        } else {
          print('[DASHBOARD] ⚠ Message not found in _messages for itemId: $itemId (may not be loaded yet, but updated in storage)');
        }
      });
    });
    
    // Listen for read receipts
    SignalService.instance.onReadReceipt((receiptInfo) {
      final itemId = receiptInfo['itemId'] as String;
      final readByDeviceId = receiptInfo['readByDeviceId'] as int?;
      final readByUserId = receiptInfo['readByUserId'] as String?;
      
      print('[DASHBOARD] Read receipt callback triggered for itemId: $itemId, readByDeviceId: $readByDeviceId, readByUserId: $readByUserId');
      if (!mounted) {
        print('[DASHBOARD] ⚠ Widget not mounted, ignoring read receipt');
        return;
      }
      
      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'read';
          print('[DASHBOARD] ✓ Updated message status to read');
          
          // Delete our sent message from server after it's been read
          // Use the receiver info from the read receipt
          if (readByDeviceId != null && readByUserId != null) {
            _deleteMessageFromServer(itemId, receiverDeviceId: readByDeviceId, receiverUserId: readByUserId);
          } else {
            // Fallback: delete without specific device/user (deletes all versions)
            print('[DASHBOARD] ⚠ Missing receiver info, falling back to delete all versions');
            _deleteMessageFromServer(itemId);
          }
        } else {
          print('[DASHBOARD] ⚠ Message not found in _messages for itemId: $itemId (may not be loaded yet)');
          // Still delete from server even if not in UI
          if (readByDeviceId != null && readByUserId != null) {
            _deleteMessageFromServer(itemId, receiverDeviceId: readByDeviceId, receiverUserId: readByUserId);
          } else {
            print('[DASHBOARD] ⚠ Missing receiver info, skipping server deletion');
          }
        }
      });
    });
  }
  
  void _setupMessageListener() {
    // Listen for incoming messages via SignalService
    SignalService.instance.registerItemCallback('message', _handleNewMessage);
  }
  
  void _handleNewMessage(dynamic item) {
    final itemType = item['type'];
    
    // Handle read_receipt: Update status of referenced message
    if (itemType == 'read_receipt') {
      print('[DASHBOARD] Received read_receipt in real-time');
      try {
        final receiptData = jsonDecode(item['message']);
        final referencedItemId = receiptData['itemId'];
        final readByDeviceId = receiptData['readByDeviceId'] as int?; // Extract which device read it
        final readByUserId = item['sender']; // The user who sent the read receipt (Alice)
        
        setState(() {
          final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == referencedItemId);
          if (msgIndex != -1) {
            _messages[msgIndex]['status'] = 'read';
            print('[DASHBOARD] ✓ Marked message $referencedItemId as read (real-time)');
            
            // Delete only the specific encrypted version for the user+device that read it
            if (readByDeviceId != null && readByUserId != null) {
              _deleteMessageFromServer(
                referencedItemId, 
                receiverDeviceId: readByDeviceId,
                receiverUserId: readByUserId
              );
            } else if (readByDeviceId != null) {
              // Fallback: only deviceId (legacy, might delete wrong message!)
              _deleteMessageFromServer(referencedItemId, receiverDeviceId: readByDeviceId);
            } else {
              // Fallback: delete all versions if deviceId not provided (backward compatibility)
              _deleteMessageFromServer(referencedItemId);
            }
          }
        });
        
        // Delete the read_receipt itself from server
        if (item['itemId'] != null) {
          _deleteMessageFromServer(item['itemId']);
        }
      } catch (e) {
        print('[DASHBOARD] Error processing read_receipt: $e');
      }
      return; // Don't add to messages list
    }
    
    // Only add messages that are relevant to this conversation
    final sender = item['sender'];
    final recipient = item['recipient']; // Falls vom Server gesetzt
    final isFromTarget = sender == widget.uuid;
    final isLocalSent = item['isLocalSent'] == true;
    
    // Check if message is relevant to this conversation:
    // 1. Message FROM the target user (Alice sent to us)
    // 2. Message TO the target user that we sent (local sent)
    // 3. Message we received from server that we sent to target
    final isRelevant = isFromTarget || 
                       (isLocalSent && recipient == widget.uuid) ||
                       (recipient == widget.uuid);
    
    if (isRelevant) {
      setState(() {
        // Check if message already exists (avoid duplicates when loading from storage)
        final itemId = item['itemId'];
        final exists = _messages.any((msg) => msg['itemId'] == itemId);
        if (exists) {
          print('[DASHBOARD] Message $itemId already exists, skipping duplicate');
          return;
        }
        
        // Create a message object compatible with existing UI
        final msg = {
          'itemId': item['itemId'],
          'sender': sender,
          'senderDeviceId': item['senderDeviceId'],
          'senderDisplayName': isLocalSent ? 'You' : widget.displayName,
          'text': item['message'],
          'message': item['message'],
          'payload': item['message'],
          'time': item['timestamp'] ?? DateTime.now().toIso8601String(),
          'isLocalSent': isLocalSent,
          'status': item['status'] ?? 'sending',
        };
        _messages.add(msg);
        
        // Sort messages by time
        _messages.sort((a, b) {
          final timeA = DateTime.tryParse(a['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });
      });
      
      // Send read receipt for received messages (not our own)
      if (!isLocalSent && isFromTarget) {
        _sendReadReceipt(item['itemId'], sender, item['senderDeviceId']);
      }
    }
  }

  /// Send read receipt to sender when message is viewed
  Future<void> _sendReadReceipt(String itemId, String sender, int senderDeviceId) async {
    try {
      print('[DASHBOARD] 📤 Sending read receipt for itemId: $itemId to user: $sender');
      
      // Get our own device ID to include in the read receipt
      final myDeviceId = SignalService.instance.currentDeviceId;
      
      await SignalService.instance.sendItem(
        recipientUserId: sender,
        type: "read_receipt",
        payload: jsonEncode({
          'itemId': itemId,
          'readByDeviceId': myDeviceId, // Include which device read the message
        }),
      );
      print('[DASHBOARD] ✓ Read receipt sent successfully for itemId: $itemId from device: $myDeviceId');
      
      // DON'T delete the original message here - the sender will delete it after receiving our read receipt
      // We only delete our own sent messages after getting a read receipt
    } catch (e) {
      print('[DASHBOARD] ❌ Error sending read receipt: $e');
    }
  }

  /// Delete message from server (cleanup after read)
  /// If receiverDeviceId AND receiverUserId are provided, only delete the specific encrypted version
  /// This ensures we don't accidentally delete the wrong user's device message
  Future<void> _deleteMessageFromServer(String itemId, {int? receiverDeviceId, String? receiverUserId}) async {
    try {
      String url = '${widget.host}/items/$itemId';
      final params = <String>[];
      
      if (receiverDeviceId != null) {
        params.add('deviceId=$receiverDeviceId');
      }
      if (receiverUserId != null) {
        params.add('receiverId=$receiverUserId');
      }
      
      if (params.isNotEmpty) {
        url += '?${params.join('&')}';
      }
      
      final resp = await ApiService.delete(url);
      if (resp.statusCode == 200) {
        if (receiverDeviceId != null && receiverUserId != null) {
          print('[DASHBOARD] Message $itemId for user $receiverUserId device $receiverDeviceId deleted from server');
        } else if (receiverDeviceId != null) {
          print('[DASHBOARD] Message $itemId for device $receiverDeviceId deleted from server');
        } else {
          print('[DASHBOARD] Message $itemId (all devices) deleted from server');
        }
      }
    } catch (e) {
      print('[DASHBOARD] Error deleting message from server: $e');
    }
  }

  /// Build status icon for message (sending/delivered/read)
  Widget _buildMessageStatus(Map<String, dynamic> message) {
    final status = message['status'] ?? 'sending';
    
    switch (status) {
      case 'sending':
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey),
        );
      case 'delivered':
        return const Icon(Icons.check, size: 16, color: Colors.grey); // Grau ✓
      case 'read':
        return const Icon(Icons.done_all, size: 16, color: Colors.green); // Grün ✓✓
      default:
        return const SizedBox.shrink();
    }
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
      // Show weekday name (Monday, Tuesday, etc.)
      return DateFormat('EEEE').format(date);
    } else {
      // Show full date (23.04.2025)
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
  
  /// Insert markdown/formatting at cursor position
  void _insertFormatting(String prefix, String suffix) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.start;
    final end = selection.end;
    
    if (start < 0) {
      // No selection, insert at end
      _controller.text = text + prefix + suffix;
      _controller.selection = TextSelection.collapsed(offset: text.length + prefix.length);
    } else if (start == end) {
      // Cursor position, no selection
      final newText = text.substring(0, start) + prefix + suffix + text.substring(end);
      _controller.text = newText;
      _controller.selection = TextSelection.collapsed(offset: start + prefix.length);
    } else {
      // Text selected
      final selectedText = text.substring(start, end);
      final newText = text.substring(0, start) + prefix + selectedText + suffix + text.substring(end);
      _controller.text = newText;
      _controller.selection = TextSelection(
        baseOffset: start + prefix.length,
        extentOffset: start + prefix.length + selectedText.length,
      );
    }
    
    _focusNode.requestFocus();
  }
  
  /// Insert emoji at cursor position
  void _insertEmoji(String emoji) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.start;
    
    if (start < 0) {
      // No selection, insert at end
      _controller.text = text + emoji;
      _controller.selection = TextSelection.collapsed(offset: text.length + emoji.length);
    } else {
      // Insert at cursor
      final newText = text.substring(0, start) + emoji + text.substring(selection.end);
      _controller.text = newText;
      _controller.selection = TextSelection.collapsed(offset: start + emoji.length);
    }
    
    _focusNode.requestFocus();
  }
  
  /// Show emoji picker overlay
  void _showEmojiPicker(BuildContext context) {
    // Remove existing overlay if present
    _emojiOverlay?.remove();
    
    _emojiOverlay = OverlayEntry(
      builder: (context) => Positioned(
        width: 350,
        height: 400,
        child: CompositedTransformFollower(
          link: _emojiLayerLink,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -10),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            color: Colors.grey[850],
            child: _EmojiPickerWidget(
              onEmojiSelected: (emoji) {
                _insertEmoji(emoji);
                _hideEmojiPicker();
              },
              onClose: _hideEmojiPicker,
            ),
          ),
        ),
      ),
    );
    
    Overlay.of(context).insert(_emojiOverlay!);
  }
  
  /// Hide emoji picker overlay
  void _hideEmojiPicker() {
    _emojiOverlay?.remove();
    _emojiOverlay = null;
  }

  Future<void> _fetchMessages() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      ApiService.init();
      
      // Load sent messages from local storage first
      final sentMessages = await SignalService.instance.loadSentMessages(widget.uuid);
      print('[DASHBOARD] Loaded ${sentMessages.length} sent messages from local storage');
      
      // Load received messages from local decrypted messages store
      final receivedMessages = await SignalService.instance.decryptedMessagesStore.getMessagesFromSender(widget.uuid);
      print('[DASHBOARD] Loaded ${receivedMessages.length} received messages from local storage');
      
      // Then load NEW messages from server (that we haven't seen yet)
      final resp = await ApiService.get('${widget.host}/direct/messages/${widget.uuid}');
      if (resp.statusCode == 200) {
        print('Response data: ${resp.data}');
        
        // Sort messages by timestamp BEFORE decryption to maintain Signal Protocol counter order
        resp.data.sort((a, b) {
          final timeA = DateTime.tryParse(a['timestamp'] ?? a['createdAt'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['timestamp'] ?? b['createdAt'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });
        print('[DASHBOARD] Sorted ${resp.data.length} messages by timestamp for sequential decryption');
        
        // Create a new list for decrypted messages (don't modify resp.data in-place)
        final decryptedMessages = <Map<String, dynamic>>[];
        
        // IMPORTANT: Decrypt messages sequentially to maintain Signal Protocol counter order
        // Using indexed for loop instead of for-in to ensure sequential processing
        for (int i = 0; i < resp.data.length; i++) {
          final msg = resp.data[i];
          final msgType = msg['type'];
          
          // Handle read_receipt: Update status of referenced message
          if (msgType == 'read_receipt') {
            print('[DASHBOARD] Processing read_receipt: ${msg['itemId']}');
            
            try {
              final item = {
                'itemId': msg['itemId'],
                'sender': msg['sender'],
                'senderDeviceId': msg['deviceSender'],
                'payload': msg['payload'],
                'cipherType': msg['cipherType'],
              };
              
              final decrypted = await SignalService.instance.decryptItemFromData(item);
              if (decrypted.isNotEmpty) {
                final receiptData = jsonDecode(decrypted);
                final referencedItemId = receiptData['itemId'];
                final readByDeviceId = receiptData['readByDeviceId'] as int?;
                final readByUserId = msg['sender']; // The user who sent the read receipt
                
                // Find the message this receipt is for and mark it as read
                final msgIndex = _messages.indexWhere((m) => m['itemId'] == referencedItemId);
                if (msgIndex != -1) {
                  _messages[msgIndex]['status'] = 'read';
                  print('[DASHBOARD] ✓ Marked message $referencedItemId as read (from server)');
                  
                  // Update status in localStorage
                  await SignalService.instance.sentMessagesStore.markAsRead(referencedItemId);
                  
                  // Delete only the specific encrypted version for the user+device that read it
                  if (readByDeviceId != null && readByUserId != null) {
                    await _deleteMessageFromServer(
                      referencedItemId, 
                      receiverDeviceId: readByDeviceId,
                      receiverUserId: readByUserId
                    );
                  } else if (readByDeviceId != null) {
                    // Fallback: only deviceId (legacy, might delete wrong message!)
                    await _deleteMessageFromServer(referencedItemId, receiverDeviceId: readByDeviceId);
                  } else {
                    // Fallback: delete all versions if deviceId not provided (backward compatibility)
                    await _deleteMessageFromServer(referencedItemId);
                  }
                }
                
                // Delete the read_receipt from server after processing
                await _deleteMessageFromServer(msg['itemId']);
              }
            } catch (e) {
              print('[DASHBOARD] Error processing read_receipt: $e');
            }
            
            continue; // Don't add to messages list
          }
          
          print('[DASHBOARD] Processing message: itemId=${msg['itemId']}, type=$msgType, cipherType=${msg['cipherType']}');
          
          final item = {
            'itemId': msg['itemId'], // Add itemId for caching
            'sender': msg['sender'],
            'senderDeviceId': msg['deviceSender'],
            'payload': msg['payload'],
            'cipherType': msg['cipherType'],
          };
          
          final decrypted = await SignalService.instance.decryptItemFromData(item);
          
          // Skip messages that failed to decrypt (empty result)
          if (decrypted.isEmpty) {
            print('[DASHBOARD] Skipping message ${msg['itemId']} - decryption returned empty');
            continue;
          }
          
          // Create a new message object with decrypted content
          final decryptedMsg = {
            'itemId': msg['itemId'],
            'sender': msg['sender'],
            'senderDeviceId': msg['deviceSender'],
            'payload': decrypted,
            'text': decrypted,
            'message': decrypted,
            'time': msg['time'] ?? msg['timestamp'] ?? msg['createdAt'] ?? DateTime.now().toIso8601String(),
            'timestamp': msg['timestamp'] ?? msg['createdAt'],
            'createdAt': msg['createdAt'],
            'senderDisplayName': msg['senderDisplayName'] ?? widget.displayName,
            'type': msgType,
            'cipherType': msg['cipherType'],
          };
          
          print('[DASHBOARD] ✓ Successfully decrypted message: ${msg['itemId']}');
          
          // Add to decrypted messages list
          decryptedMessages.add(decryptedMsg);
          
          // Send read receipt for this received message
          if (msg['sender'] == widget.uuid) {
            print('[DASHBOARD] Sending read receipt for message from server: ${msg['itemId']}');
            await _sendReadReceipt(msg['itemId'], msg['sender'], msg['deviceSender']);
          }
        }
        
        // Merge sent messages with received messages from local storage
        final allMessages = <Map<String, dynamic>>[];
        
        // Add sent messages (formatted for UI) with status from storage
        // Filter out read_receipt messages (they start with {"itemId":)
        for (var sentMsg in sentMessages) {
          final message = sentMsg['message'] ?? '';
          
          // Skip read receipts (they are JSON objects, not chat messages)
          if (message.toString().startsWith('{"itemId":')) {
            print('[DASHBOARD] Skipping read_receipt from sentMessages: $message');
            continue;
          }
          
          allMessages.add({
            'itemId': sentMsg['itemId'],
            'sender': sentMsg['recipientUserId'],
            'senderDisplayName': 'You',
            'text': message,
            'message': message,
            'payload': message,
            'time': sentMsg['timestamp'],
            'isLocalSent': true,
            'status': sentMsg['status'] ?? 'sending', // Load status from storage
          });
        }
        
        // Add received messages from local storage (already decrypted)
        for (var receivedMsg in receivedMessages) {
          allMessages.add({
            'itemId': receivedMsg['itemId'],
            'sender': receivedMsg['sender'],
            'senderDisplayName': widget.displayName,
            'text': receivedMsg['message'],
            'message': receivedMsg['message'],
            'payload': receivedMsg['message'],
            'time': receivedMsg['timestamp'] ?? receivedMsg['decryptedAt'],
            'isLocalSent': false,
          });
        }
        
        // Add NEW decrypted messages from server (just fetched)
        // Skip duplicates that are already in local storage
        for (var msg in decryptedMessages) {
          final itemId = msg['itemId'];
          final exists = allMessages.any((m) => m['itemId'] == itemId);
          if (!exists) {
            allMessages.add(msg);
          } else {
            print('[DASHBOARD] Skipping duplicate message from server: $itemId');
          }
        }
        
        print('[DASHBOARD] Merged ${sentMessages.length} sent + ${receivedMessages.length} cached received + ${decryptedMessages.length} new from server = ${allMessages.length} total messages');
        
        // Sort all messages by timestamp
        allMessages.sort((a, b) {
          final timeA = DateTime.tryParse(a['time'] ?? a['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['time'] ?? b['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });
        
        setState(() {
          _messages = allMessages;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load messages: ${resp.statusCode}';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _loading = false;
      });
    }
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    
    // Generate itemId here so we can add message to UI immediately
    final itemId = Uuid().v4();
    final timestamp = DateTime.now().toIso8601String();
    
    // Add message to UI immediately with 'sending' status
    setState(() {
      _messages.add({
        'itemId': itemId,
        'sender': SignalService.instance.currentUserId,
        'senderDeviceId': SignalService.instance.currentDeviceId,
        'senderDisplayName': 'You',
        'text': text,
        'message': text,
        'payload': text,
        'time': timestamp,
        'isLocalSent': true,
        'status': 'sending',
      });
    });
    
    // Clear input immediately for better UX
    _controller.clear();
    
    try {
      // Send encrypted message to all devices
      await SignalService.instance.sendItem(
        recipientUserId: widget.uuid,
        type: "message",
        payload: text,
        itemId: itemId, // Pass the pre-generated itemId
      );
    } catch (e) {
      // Update message status to failed
      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'failed';
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          color: Colors.grey[850],
          child: Row(
            children: [
              Text(widget.displayName, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 18)))
                  : ListView.builder(
                      padding: const EdgeInsets.all(24),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final msg = _messages[index];
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
                          final prevTimeStr = _messages[index - 1]['time'] ?? '';
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
                                    child: Text(sender.isNotEmpty ? sender[0] : '?')
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
                                                color: isLocalSent ? Colors.blue[300] : Colors.white
                                              )
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              _formatTime(msgTime),
                                              style: const TextStyle(color: Colors.white54, fontSize: 13)
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
                    ),
        ),
        // Rich text formatting toolbar
        if (_showFormatting)
          Container(
            color: Colors.grey[900],
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.format_bold, size: 20),
                    color: Colors.white70,
                    tooltip: 'Bold',
                    onPressed: () => _insertFormatting('**', '**'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.format_italic, size: 20),
                    color: Colors.white70,
                    tooltip: 'Italic',
                    onPressed: () => _insertFormatting('_', '_'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.format_strikethrough, size: 20),
                    color: Colors.white70,
                    tooltip: 'Strikethrough',
                    onPressed: () => _insertFormatting('~~', '~~'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.link, size: 20),
                    color: Colors.white70,
                    tooltip: 'Link',
                    onPressed: () => _insertFormatting('[', '](https://example.com)'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.format_list_numbered, size: 20),
                    color: Colors.white70,
                    tooltip: 'Numbered List',
                    onPressed: () => _insertFormatting('1. ', '\n'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.format_list_bulleted, size: 20),
                    color: Colors.white70,
                    tooltip: 'Bullet List',
                    onPressed: () => _insertFormatting('• ', '\n'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.code, size: 20),
                    color: Colors.white70,
                    tooltip: 'Inline Code',
                    onPressed: () => _insertFormatting('`', '`'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.code_off, size: 20),
                    color: Colors.white70,
                    tooltip: 'Code Block',
                    onPressed: () => _insertFormatting('```\n', '\n```'),
                  ),
                ],
              ),
            ),
          ),
        // Input area
        Container(
          color: Colors.grey[850],
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Plus button with context menu
              PopupMenuButton<String>(
                icon: const Icon(Icons.add_circle_outline, color: Colors.white70),
                color: Colors.grey[800],
                tooltip: 'Attach',
                onSelected: (value) {
                  print('[DASHBOARD] Selected attachment type: $value');
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'file', child: Row(children: [Icon(Icons.attach_file, color: Colors.white70), SizedBox(width: 8), Text('File', style: TextStyle(color: Colors.white))])),
                  const PopupMenuItem(value: 'image', child: Row(children: [Icon(Icons.image, color: Colors.white70), SizedBox(width: 8), Text('Image', style: TextStyle(color: Colors.white))])),
                  const PopupMenuItem(value: 'camera', child: Row(children: [Icon(Icons.camera_alt, color: Colors.white70), SizedBox(width: 8), Text('Camera', style: TextStyle(color: Colors.white))])),
                ],
              ),
              const SizedBox(width: 8),
              // Text input
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: 'Type a message...',
                    hintStyle: TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: Colors.grey[800],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  style: const TextStyle(color: Colors.white),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              // Formatting toggle
              IconButton(
                icon: Icon(
                  _showFormatting ? Icons.format_clear : Icons.format_size,
                  color: Colors.white70,
                ),
                tooltip: _showFormatting ? 'Hide Formatting' : 'Show Formatting',
                onPressed: () {
                  setState(() {
                    _showFormatting = !_showFormatting;
                  });
                },
              ),
              // Emoji button
              CompositedTransformTarget(
                link: _emojiLayerLink,
                child: IconButton(
                  icon: const Icon(Icons.emoji_emotions_outlined, color: Colors.white70),
                  tooltip: 'Emoji',
                  onPressed: () {
                    if (_emojiOverlay == null) {
                      _showEmojiPicker(context);
                    } else {
                      _hideEmojiPicker();
                    }
                  },
                ),
              ),
              // Mention button
              IconButton(
                icon: const Icon(Icons.alternate_email, color: Colors.white70),
                tooltip: 'Mention',
                onPressed: () {
                  _insertFormatting('@', '');
                },
              ),
              // Send button
              IconButton(
                icon: const Icon(Icons.send, color: Colors.amber),
                tooltip: 'Send',
                onPressed: _sendMessage,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Emoji Picker Widget
class _EmojiPickerWidget extends StatefulWidget {
  final Function(String) onEmojiSelected;
  final VoidCallback onClose;
  
  const _EmojiPickerWidget({
    required this.onEmojiSelected,
    required this.onClose,
  });

  @override
  State<_EmojiPickerWidget> createState() => _EmojiPickerWidgetState();
}

class _EmojiPickerWidgetState extends State<_EmojiPickerWidget> {
  String _searchQuery = '';
  String _selectedCategory = 'Smileys';
  
  // Emoji categories
  static const Map<String, List<String>> _emojiCategories = {
    'Smileys': ['😀', '😃', '😄', '😁', '😅', '😂', '🤣', '😊', '😇', '🙂', '🙃', '😉', '😌', '😍', '🥰', '😘', '😗', '😙', '😚', '😋', '😛', '😝', '😜', '🤪', '🤨', '🧐', '🤓', '😎', '🤩', '🥳'],
    'Gestures': ['👋', '🤚', '🖐', '✋', '🖖', '👌', '🤌', '🤏', '✌️', '🤞', '🤟', '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️', '👍', '👎', '✊', '👊', '🤛', '🤜', '👏', '🙌', '👐', '🤲'],
    'People': ['👶', '👧', '🧒', '👦', '👩', '🧑', '👨', '👩‍🦱', '🧑‍🦱', '👨‍🦱', '👩‍🦰', '🧑‍🦰', '👨‍🦰', '👱‍♀️', '👱', '👱‍♂️', '👩‍🦳', '🧑‍🦳', '👨‍🦳', '👩‍🦲', '🧑‍🦲', '👨‍🦲', '🧔', '👵', '🧓', '👴', '👲', '👳‍♀️', '👳', '👳‍♂️'],
    'Animals': ['🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🐤', '🦆', '🦅', '🦉', '🦇', '🐺', '🐗', '🐴', '🦄', '🐝', '🐛', '🦋'],
    'Food': ['🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🍈', '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🍆', '🥑', '🥦', '🥬', '🥒', '🌶', '🌽', '🥕', '🧄', '🧅', '🥔', '🍠', '🥐'],
    'Activities': ['⚽', '🏀', '🏈', '⚾', '🥎', '🎾', '🏐', '🏉', '🥏', '🎱', '🏓', '🏸', '🏒', '🏑', '🥍', '🏏', '🥅', '⛳', '🏹', '🎣', '🤿', '🥊', '🥋', '🎽', '🛹', '🛼', '🛷', '⛸', '🥌', '🎿'],
    'Travel': ['🚗', '🚕', '🚙', '🚌', '🚎', '🏎', '🚓', '🚑', '🚒', '🚐', '🛻', '🚚', '🚛', '🚜', '🦯', '🦽', '🦼', '🛴', '🚲', '🛵', '🏍', '🛺', '🚨', '🚔', '🚍', '🚘', '🚖', '🚡', '🚠', '🚟'],
    'Objects': ['⌚', '📱', '📲', '💻', '⌨️', '🖥', '🖨', '🖱', '🖲', '🕹', '🗜', '💾', '💿', '📀', '📼', '📷', '📸', '📹', '🎥', '📽', '🎞', '📞', '☎️', '📟', '📠', '📺', '📻', '🎙', '🎚', '🎛'],
    'Symbols': ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝', '💟', '☮️', '✝️', '☪️', '🕉', '☸️', '✡️', '🔯', '🕎', '☯️', '☦️', '🛐'],
    'Flags': ['🏁', '🚩', '🎌', '🏴', '🏳️', '🏳️‍🌈', '🏳️‍⚧️', '🏴‍☠️', '🇩🇪', '🇺🇸', '🇬🇧', '🇫🇷', '🇪🇸', '🇮🇹', '🇯🇵', '🇨🇳', '🇰🇷', '🇧🇷', '🇨🇦', '🇦🇺', '🇮🇳', '🇷🇺', '🇲🇽', '🇸🇪', '🇳🇴', '🇩🇰', '🇫🇮', '🇳🇱', '🇧🇪', '🇨🇭'],
  };
  
  List<String> get _filteredEmojis {
    final categoryEmojis = _emojiCategories[_selectedCategory] ?? [];
    if (_searchQuery.isEmpty) {
      return categoryEmojis;
    }
    // Simple search - in real app you'd search by emoji name/keywords
    return categoryEmojis;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[700]!, width: 1),
      ),
      child: Column(
        children: [
          // Header with search and close button
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[800],
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search emojis...',
                      hintStyle: TextStyle(color: Colors.grey[500], fontSize: 14),
                      prefixIcon: Icon(Icons.search, color: Colors.grey[500], size: 20),
                      filled: true,
                      fillColor: Colors.grey[900],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  iconSize: 20,
                  onPressed: widget.onClose,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          // Category tabs
          Container(
            height: 40,
            color: Colors.grey[800],
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: _emojiCategories.keys.map((category) {
                final isSelected = category == _selectedCategory;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedCategory = category;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.amber : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      category,
                      style: TextStyle(
                        color: isSelected ? Colors.black : Colors.white70,
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // Emoji grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: _filteredEmojis.length,
              itemBuilder: (context, index) {
                final emoji = _filteredEmojis[index];
                return InkWell(
                  onTap: () {
                    widget.onEmojiSelected(emoji);
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Center(
                      child: Text(
                        emoji,
                        style: const TextStyle(fontSize: 24),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
