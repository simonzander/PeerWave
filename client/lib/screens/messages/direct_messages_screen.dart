import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../../widgets/message_list.dart';
import '../../widgets/message_input.dart';
import '../../services/signal_service.dart';
import '../../services/socket_service.dart';
import '../../services/offline_message_queue.dart';
import '../../services/api_service.dart';
import '../../services/file_transfer/p2p_coordinator.dart';
import '../../services/file_transfer/socket_file_client.dart';
import '../../models/file_message.dart';

/// Screen for Direct Messages (1:1 Signal chats)
class DirectMessagesScreen extends StatefulWidget {
  final String host;
  final String recipientUuid;
  final String recipientDisplayName;

  const DirectMessagesScreen({
    super.key,
    required this.host,
    required this.recipientUuid,
    required this.recipientDisplayName,
  });

  @override
  State<DirectMessagesScreen> createState() => _DirectMessagesScreenState();
}

class _DirectMessagesScreenState extends State<DirectMessagesScreen> {
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  /// Initialize the direct messages screen: verify Signal Protocol, then load messages
  Future<void> _initialize() async {
    // Verify own identity keys are available
    try {
      await SignalService.instance.identityStore.getIdentityKeyPair();
      print('[DIRECT_MESSAGES] Identity key pair verified');
    } catch (e) {
      print('[DIRECT_MESSAGES] Identity key pair check failed: $e');
      
      // Attempt to regenerate if missing
      print('[DIRECT_MESSAGES] Attempting to regenerate Signal Protocol...');
      try {
        await SignalService.instance.init();
        print('[DIRECT_MESSAGES] Signal Protocol regenerated successfully');
      } catch (regenerateError) {
        print('[DIRECT_MESSAGES] Failed to regenerate Signal Protocol: $regenerateError');
        
        // Show warning and set error state
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Signal Protocol initialization incomplete. Cannot send messages.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 5),
            ),
          );
        }
        
        setState(() {
          _error = 'Signal Protocol not initialized';
        });
        // Continue loading messages (can still receive)
      }
    }
    
    await _loadMessages();
    _setupMessageListener();
    _setupReceiptListeners();
  }

  @override
  void dispose() {
    SignalService.instance.unregisterItemCallback('message', _handleNewMessage);
    SignalService.instance.clearDeliveryCallbacks();
    SignalService.instance.clearReadCallbacks();
    super.dispose();
  }

  void _setupReceiptListeners() {
    // Listen for delivery receipts
    SignalService.instance.onDeliveryReceipt((itemId) {
      if (!mounted) return;
      
      SignalService.instance.sentMessagesStore.markAsDelivered(itemId);
      
      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'delivered';
        }
      });
    });

    // Listen for read receipts
    SignalService.instance.onReadReceipt((receiptInfo) {
      final itemId = receiptInfo['itemId'] as String;
      final readByDeviceId = receiptInfo['readByDeviceId'] as int?;
      final readByUserId = receiptInfo['readByUserId'] as String?;

      if (!mounted) return;

      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'read';

          if (readByDeviceId != null && readByUserId != null) {
            _deleteMessageFromServer(itemId, receiverDeviceId: readByDeviceId, receiverUserId: readByUserId);
          } else {
            _deleteMessageFromServer(itemId);
          }
        }
      });
    });
  }

  void _setupMessageListener() {
    SignalService.instance.registerItemCallback('message', _handleNewMessage);
  }

  void _handleNewMessage(dynamic item) {
    final itemType = item['type'];

    // Filter out system messages that should not be displayed in chat
    if (itemType == 'read_receipt' || 
        itemType == 'senderKeyDistribution' || 
        itemType == 'senderKeyRequest' ||
        itemType == 'fileKeyRequest' ||
        itemType == 'fileKeyResponse') {
      // Handle read_receipt
      if (itemType == 'read_receipt') {
        try {
          final receiptData = jsonDecode(item['message']);
          final referencedItemId = receiptData['itemId'];
          final readByDeviceId = receiptData['readByDeviceId'] as int?;
          final readByUserId = item['sender'];

          setState(() {
            final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == referencedItemId);
            if (msgIndex != -1) {
              _messages[msgIndex]['status'] = 'read';

              if (readByDeviceId != null && readByUserId != null) {
                _deleteMessageFromServer(
                  referencedItemId,
                  receiverDeviceId: readByDeviceId,
                  receiverUserId: readByUserId
                );
              } else {
                _deleteMessageFromServer(referencedItemId);
              }
            }
          });

          if (item['itemId'] != null) {
            _deleteMessageFromServer(item['itemId']);
          }
        } catch (e) {
          print('[DM_SCREEN] Error processing read_receipt: $e');
        }
      }
      // Don't display system messages in UI
      return;
    }

    // Only handle actual chat messages (type: 'message' or 'file')
    if (itemType != 'message' && itemType != 'file') {
      return;
    }

    // Check if message is relevant to this conversation
    final sender = item['sender'];
    final recipient = item['recipient'];
    final isFromTarget = sender == widget.recipientUuid;
    final isLocalSent = item['isLocalSent'] == true;

    final isRelevant = isFromTarget ||
                       (isLocalSent && recipient == widget.recipientUuid) ||
                       (recipient == widget.recipientUuid);

    if (isRelevant) {
      setState(() {
        final itemId = item['itemId'];
        final exists = _messages.any((msg) => msg['itemId'] == itemId);
        if (exists) return;

        final msg = {
          'itemId': item['itemId'],
          'sender': sender,
          'senderDeviceId': item['senderDeviceId'],
          'senderDisplayName': isLocalSent ? 'You' : widget.recipientDisplayName,
          'text': item['message'],
          'message': item['message'],
          'payload': item['payload'] ?? item['message'], // Add payload field for file messages
          'time': item['timestamp'] ?? DateTime.now().toIso8601String(),
          'isLocalSent': isLocalSent,
          'status': item['status'] ?? 'sending',
          'type': itemType, // Preserve message type (message or file)
        };
        _messages.add(msg);

        _messages.sort((a, b) {
          final timeA = DateTime.tryParse(a['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });
      });

      if (!isLocalSent && isFromTarget) {
        // Parse senderDeviceId as int (might be String from storage/socket)
        final senderDeviceId = item['senderDeviceId'] is int
            ? item['senderDeviceId'] as int
            : int.parse(item['senderDeviceId'].toString());
        _sendReadReceipt(item['itemId'], sender, senderDeviceId);
      }
    }
  }

  Future<void> _sendReadReceipt(String itemId, String sender, int senderDeviceId) async {
    try {
      final myDeviceId = SignalService.instance.currentDeviceId;

      await SignalService.instance.sendItem(
        recipientUserId: sender,
        type: "read_receipt",
        payload: jsonEncode({
          'itemId': itemId,
          'readByDeviceId': myDeviceId,
        }),
      );
    } catch (e) {
      print('[DM_SCREEN] Error sending read receipt: $e');
    }
  }

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

      await ApiService.delete(url);
    } catch (e) {
      print('[DM_SCREEN] Error deleting message from server: $e');
    }
  }

  Future<void> _loadMessages() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      ApiService.init();

      // Load sent messages from local storage
      final sentMessages = await SignalService.instance.loadSentMessages(widget.recipientUuid);

      // Load received messages from local storage (1:1 direct messages only)
      final receivedMessages = await SignalService.instance.decryptedMessagesStore.getMessagesFromSender(widget.recipientUuid);

      // Load new messages from server
      final resp = await ApiService.get('${widget.host}/direct/messages/${widget.recipientUuid}');
      
      if (resp.statusCode == 200) {
        resp.data.sort((a, b) {
          final timeA = DateTime.tryParse(a['timestamp'] ?? a['createdAt'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['timestamp'] ?? b['createdAt'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });

        final decryptedMessages = <Map<String, dynamic>>[];

        for (int i = 0; i < resp.data.length; i++) {
          final msg = resp.data[i];
          final msgType = msg['type'];

          // Skip system messages (senderKeyDistribution, senderKeyRequest)
          if (msgType == 'senderKeyDistribution' || msgType == 'senderKeyRequest') {
            print('[DM_SCREEN] Skipping system message type: $msgType');
            continue;
          }

          if (msgType == 'read_receipt') {
            try {
              // Parse deviceSender as int (server returns String from SQLite INTEGER)
              final deviceSender = msg['deviceSender'] is int
                  ? msg['deviceSender'] as int
                  : int.parse(msg['deviceSender'].toString());
              
              final item = {
                'itemId': msg['itemId'],
                'sender': msg['sender'],
                'senderDeviceId': deviceSender,
                'payload': msg['payload'],
                'cipherType': msg['cipherType'],
              };

              final decrypted = await SignalService.instance.decryptItemFromData(item);
              if (decrypted.isNotEmpty) {
                final receiptData = jsonDecode(decrypted);
                final referencedItemId = receiptData['itemId'];
                final readByDeviceId = receiptData['readByDeviceId'] as int?;
                final readByUserId = msg['sender'];

                final msgIndex = _messages.indexWhere((m) => m['itemId'] == referencedItemId);
                if (msgIndex != -1) {
                  _messages[msgIndex]['status'] = 'read';
                  await SignalService.instance.sentMessagesStore.markAsRead(referencedItemId);

                  if (readByDeviceId != null && readByUserId != null) {
                    await _deleteMessageFromServer(
                      referencedItemId,
                      receiverDeviceId: readByDeviceId,
                      receiverUserId: readByUserId
                    );
                  }
                }

                await _deleteMessageFromServer(msg['itemId']);
              }
            } catch (e) {
              print('[DM_SCREEN] Error processing read_receipt: $e');
            }
            continue;
          }

          // Parse deviceSender as int (server returns String from SQLite INTEGER)
          final deviceSender = msg['deviceSender'] is int
              ? msg['deviceSender'] as int
              : int.parse(msg['deviceSender'].toString());

          final item = {
            'itemId': msg['itemId'],
            'sender': msg['sender'],
            'senderDeviceId': deviceSender,
            'payload': msg['payload'],
            'cipherType': msg['cipherType'],
          };

          final decrypted = await SignalService.instance.decryptItemFromData(item);

          if (decrypted.isEmpty) continue;

          final decryptedMsg = {
            'itemId': msg['itemId'],
            'sender': msg['sender'],
            'senderDeviceId': deviceSender,
            'text': decrypted,
            'message': decrypted,
            'payload': decrypted, // Add payload field for file messages
            'time': msg['time'] ?? msg['timestamp'] ?? msg['createdAt'] ?? DateTime.now().toIso8601String(),
            'senderDisplayName': widget.recipientDisplayName,
            'type': msgType, // Preserve message type (message or file)
          };

          decryptedMessages.add(decryptedMsg);

          if (msg['sender'] == widget.recipientUuid) {
            // Parse deviceSender as int (IndexedDB might return String)
            final deviceSender = msg['deviceSender'] is int
                ? msg['deviceSender'] as int
                : int.parse(msg['deviceSender'].toString());
            await _sendReadReceipt(msg['itemId'], msg['sender'], deviceSender);
          }
        }

        // Merge all messages
        final allMessages = <Map<String, dynamic>>[];

        for (var sentMsg in sentMessages) {
          final message = sentMsg['message'] ?? '';
          if (message.toString().startsWith('{"itemId":')) continue;

          // Filter out system messages (only 'message' and 'file' types allowed)
          final msgType = sentMsg['type'] ?? 'message';
          if (msgType != 'message' && msgType != 'file') {
            print('[DM_SCREEN] Skipping sent system message type: $msgType');
            continue;
          }

          allMessages.add({
            'itemId': sentMsg['itemId'],
            'sender': sentMsg['recipientUserId'],
            'senderDisplayName': 'You',
            'text': message,
            'message': message,
            'payload': message, // Add payload field for file messages
            'time': sentMsg['timestamp'],
            'isLocalSent': true,
            'status': sentMsg['status'] ?? 'sending',
            'type': msgType, // Preserve message type (message or file)
          });
        }

        for (var receivedMsg in receivedMessages) {
          allMessages.add({
            'itemId': receivedMsg['itemId'],
            'sender': receivedMsg['sender'],
            'senderDisplayName': widget.recipientDisplayName,
            'text': receivedMsg['message'],
            'message': receivedMsg['message'],
            'payload': receivedMsg['message'], // Add payload field for file messages
            'time': receivedMsg['timestamp'] ?? receivedMsg['decryptedAt'],
            'isLocalSent': false,
            'type': receivedMsg['type'] ?? 'message', // Preserve message type
          });
        }

        for (var msg in decryptedMessages) {
          final itemId = msg['itemId'];
          final exists = allMessages.any((m) => m['itemId'] == itemId);
          if (!exists) {
            allMessages.add(msg);
          }
        }

        allMessages.sort((a, b) {
          final timeA = DateTime.tryParse(a['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
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

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    // CRITICAL: Check if Signal Protocol is initialized before sending
    if (_error != null && _error!.contains('Signal Protocol not initialized')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot send message: Signal Protocol not initialized. Please refresh the page.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 5),
          ),
        );
      }
      return; // ❌ BLOCK - Critical initialization error
    }

    // STEP 2: Check if recipient has available PreKeys BEFORE sending
    try {
      final hasPreKeys = await SignalService.instance.hasPreKeysForRecipient(
        widget.recipientUuid
      );
      
      if (hasPreKeys == null) {
        // API error - show warning but allow sending (failsafe)
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not verify recipient keys. Attempting to send anyway...'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        }
        // Continue with sending
      } else if (!hasPreKeys) {
        // BLOCK: Recipient has no available PreKeys
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Cannot send message: ${widget.recipientDisplayName} has no PreKeys available. '
                'Please ask them to register or refresh their device.'
              ),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return; // ❌ BLOCK - Do not send message
      }
    } catch (e) {
      // On check error: still try to send (failsafe approach)
      print('[DIRECT MESSAGES] PreKey check failed, attempting to send anyway: $e');
    }

    final itemId = Uuid().v4();
    final timestamp = DateTime.now().toIso8601String();

    setState(() {
      _messages.add({
        'itemId': itemId,
        'sender': SignalService.instance.currentUserId,
        'senderDeviceId': SignalService.instance.currentDeviceId,
        'senderDisplayName': 'You',
        'text': text,
        'message': text,
        'time': timestamp,
        'isLocalSent': true,
        'status': 'sending',
      });
    });

    // CRITICAL: Check socket connection before sending
    if (!SocketService().isConnected) {
      // Add to offline queue
      await OfflineMessageQueue.instance.enqueue(
        QueuedMessage(
          itemId: itemId,
          type: 'direct',
          text: text,
          timestamp: timestamp,
          metadata: {
            'recipientId': widget.recipientUuid,
            'recipientName': widget.recipientDisplayName,
          },
        ),
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not connected. Message queued and will be sent when reconnected.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 5),
          ),
        );
      }
      
      // Update message status to pending
      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'pending';
        }
      });
      return; // Exit but message stays in queue
    }

    try {
      await SignalService.instance.sendItem(
        recipientUserId: widget.recipientUuid,
        type: "message",
        payload: text,
        itemId: itemId,
      );
    } catch (e) {
      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'failed';
        }
      });
      
      // STEP 4: Better error messages based on error type
      String errorMessage = 'Failed to send message';
      Color errorColor = Colors.red;
      
      if (e.toString().contains('PreKeyBundle') || e.toString().contains('PreKey')) {
        errorMessage = 'Recipient has no PreKeys. Please ask them to register or refresh.';
        errorColor = Colors.red;
      } else if (e.toString().contains('Failed to load PreKeyBundle')) {
        errorMessage = 'Server error loading recipient keys. Please try again later.';
        errorColor = Colors.orange;
      } else if (e.toString().contains('Identity key') || e.toString().contains('identity')) {
        errorMessage = 'Encryption keys missing. Please refresh the page.';
        errorColor = Colors.red;
      } else if (e.toString().contains('User not authenticated')) {
        errorMessage = 'Session expired. Please refresh the page.';
        errorColor = Colors.red;
      } else if (e.toString().contains('Session') || e.toString().contains('session')) {
        errorMessage = 'Encryption session error. Message may arrive after retry.';
        errorColor = Colors.orange;
      } else if (e.toString().contains('decode') || e.toString().contains('Decode') || e.toString().contains('Invalid')) {
        errorMessage = 'Recipient has corrupted encryption keys. Ask them to re-register.';
        errorColor = Colors.red;
      } else if (e.toString().contains('network') || e.toString().contains('connection')) {
        errorMessage = 'Network error. Please check your connection and retry.';
        errorColor = Colors.orange;
      } else {
        errorMessage = 'Failed to send message: ${e.toString()}';
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: errorColor,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.recipientDisplayName),
        backgroundColor: Colors.grey[850],
      ),
      backgroundColor: const Color(0xFF36393F),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(_error!, style: const TextStyle(color: Colors.red)),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loadMessages,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : MessageList(
                        messages: _messages,
                        onFileDownload: _handleFileDownload,
                      ),
          ),
          MessageInput(onSendMessage: _sendMessage),
        ],
      ),
    );
  }

  /// Handle file download request from FileMessageWidget
  Future<void> _handleFileDownload(dynamic fileMessageDynamic) async {
    try {
      // Cast to FileMessage
      final FileMessage fileMessage = fileMessageDynamic as FileMessage;
      
      print('[DIRECT_MSG] ================================================');
      print('[DIRECT_MSG] File download requested');
      print('[DIRECT_MSG] File ID: ${fileMessage.fileId}');
      print('[DIRECT_MSG] File Name: ${fileMessage.fileName}');
      print('[DIRECT_MSG] File Size: ${fileMessage.fileSizeFormatted}');
      print('[DIRECT_MSG] ================================================');
      
      // Show loading feedback
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Starting download: ${fileMessage.fileName}...'),
            backgroundColor: Colors.blue,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      
      // Get P2P Coordinator
      final p2pCoordinator = Provider.of<P2PCoordinator?>(context, listen: false);
      if (p2pCoordinator == null) {
        throw Exception('P2P Coordinator not initialized');
      }
      
      // Get Socket File Client
      final socketService = SocketService();
      if (socketService.socket == null) {
        throw Exception('Socket not connected');
      }
      final socketClient = SocketFileClient(socket: socketService.socket!);
      
      // 1. Fetch file info and seeder chunks from server
      print('[DIRECT_MSG] Fetching file info and seeders...');
      // Fetch file info for validation and to get sharedWith list
      final fileInfo = await socketClient.getFileInfo(fileMessage.fileId);
      final seederChunks = await socketClient.getAvailableChunks(fileMessage.fileId);
      
      if (seederChunks.isEmpty) {
        throw Exception('No seeders available for this file');
      }
      
      print('[DIRECT_MSG] Found ${seederChunks.length} seeders');
      
      // Register as leecher
      await socketClient.registerLeecher(fileMessage.fileId);
      
      // 2. Decode the encrypted file key (base64 → Uint8List)
      print('[DIRECT_MSG] Decoding file encryption key...');
      final Uint8List fileKey = base64Decode(fileMessage.encryptedFileKey);
      print('[DIRECT_MSG] File key decoded: ${fileKey.length} bytes');
      
      // 3. Start P2P download with the file key
      print('[DIRECT_MSG] Starting P2P download...');
      await p2pCoordinator.startDownload(
        fileId: fileMessage.fileId,
        fileName: fileMessage.fileName,
        mimeType: fileMessage.mimeType,
        fileSize: fileMessage.fileSize,
        checksum: fileMessage.checksum,
        chunkCount: fileMessage.chunkCount,
        fileKey: fileKey,
        seederChunks: seederChunks,
        sharedWith: (fileInfo['sharedWith'] as List?)?.cast<String>(), // ✅ NEW: Pass sharedWith from fileInfo
      );
      
      print('[DIRECT_MSG] Download started successfully!');
      
      // Show success feedback
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download started: ${fileMessage.fileName}'),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: 'View',
              textColor: Colors.white,
              onPressed: () {
                // TODO: Navigate to downloads screen
                print('[DIRECT_MSG] Navigate to downloads screen');
              },
            ),
          ),
        );
      }
      
    } catch (e, stackTrace) {
      print('[DIRECT_MSG] ❌ Download failed: $e');
      print('[DIRECT_MSG] Stack trace: $stackTrace');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }
}
