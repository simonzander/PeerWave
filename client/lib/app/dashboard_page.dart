import 'package:flutter/material.dart';
import 'sidebar_panel.dart';
import 'profile_card.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:go_router/go_router.dart';
import '../services/api_service.dart';
import '../services/signal_service.dart';
import '../services/socket_service.dart';

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
      default:
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

  @override
  void initState() {
    super.initState();
    _fetchMessages();
    _setupMessageListener();
  }
  
  @override
  void dispose() {
    SignalService.instance.unregisterItemCallback('message', _handleNewMessage);
    super.dispose();
  }
  
  void _setupMessageListener() {
    // Listen for incoming messages via SignalService
    SignalService.instance.registerItemCallback('message', _handleNewMessage);
  }
  
  void _handleNewMessage(dynamic item) {
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
        };
        _messages.add(msg);
        
        // Sort messages by time
        _messages.sort((a, b) {
          final timeA = DateTime.tryParse(a['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });
      });
    }
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
      
      // Then load received messages from server
      final resp = await ApiService.get('${widget.host}/direct/messages/${widget.uuid}');
      if (resp.statusCode == 200) {
        print('Response data: ${resp.data}');
        
        // Decrypt all messages in the array
        for (var msg in resp.data) {
          print('[DASHBOARD] Processing message: itemId=${msg['itemId']}, cipherType=${msg['cipherType']}');
          
          final item = {
            'itemId': msg['itemId'], // Add itemId for caching
            'sender': msg['sender'],
            'senderDeviceId': msg['deviceSender'],
            'payload': msg['payload'],
            'cipherType': msg['cipherType'],
          };
          
          try {
            final decrypted = await SignalService.instance.decryptItemFromData(item);
            msg['payload'] = decrypted;
            msg['text'] = decrypted;
            msg['message'] = decrypted;
            print('[DASHBOARD] Successfully decrypted message: ${msg['itemId']} - content: "$decrypted"');
          } catch (e) {
            print('[DASHBOARD] Failed to decrypt message ${msg['itemId']}: $e');
            msg['payload'] = '[Decryption failed]';
            msg['text'] = '[Decryption failed]';
            msg['message'] = '[Decryption failed]';
          }
          
          // Add timestamp if missing (use current time or extract from DB if available)
          if (msg['time'] == null && msg['timestamp'] == null) {
            msg['time'] = msg['createdAt'] ?? DateTime.now().toIso8601String();
          }
          
          // Add senderDisplayName for UI
          if (msg['senderDisplayName'] == null) {
            msg['senderDisplayName'] = widget.displayName;
          }
        }
        
        // Merge sent messages with received messages
        final allMessages = <Map<String, dynamic>>[];
        
        // Add sent messages (formatted for UI)
        for (var sentMsg in sentMessages) {
          allMessages.add({
            'itemId': sentMsg['itemId'],
            'sender': sentMsg['recipientUserId'],
            'senderDisplayName': 'You',
            'text': sentMsg['message'],
            'message': sentMsg['message'],
            'payload': sentMsg['message'],
            'time': sentMsg['timestamp'],
            'isLocalSent': true,
          });
        }
        
        // Add received messages
        allMessages.addAll(resp.data);
        
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
    try {
      // Send encrypted message to all devices
      await SignalService.instance.sendItem(
        recipientUserId: widget.uuid,
        type: "message",
        payload: text,
      );
      // Clear input after sending (local callback will add message to UI)
      _controller.clear();
    } catch (e) {
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
                        final time = msg['time'] ?? '';
                        final isLocalSent = msg['isLocalSent'] == true;
                        return Container(
                          margin: const EdgeInsets.symmetric(vertical: 8),
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
                                        Text(time, style: const TextStyle(color: Colors.white54, fontSize: 13)),
                                        if (isLocalSent) ...[
                                          const SizedBox(width: 8),
                                          const Icon(Icons.check, color: Colors.green, size: 16),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    SelectableText(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
        ),
        Container(
          color: Colors.grey[850],
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    hintText: 'Type a message...',
                    hintStyle: TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: Colors.grey[800],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                  ),
                  style: const TextStyle(color: Colors.white),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: const Icon(Icons.send, color: Colors.white),
                onPressed: _sendMessage,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChatMessage extends StatelessWidget {
  final String avatar;
  final String name;
  final String time;
  final String text;
  final List<_Reaction> reactions;
  final _FilePreview? filePreview;
  const _ChatMessage({
    required this.avatar,
    required this.name,
    required this.time,
    required this.text,
    this.reactions = const [],
    this.filePreview,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 20,
            backgroundImage: NetworkImage(avatar),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(width: 8),
                    Text(time, style: const TextStyle(color: Colors.white54, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 2),
                SelectableText(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
                if (filePreview != null) ...[
                  const SizedBox(height: 8),
                  filePreview!,
                ],
                if (reactions.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: reactions.map((r) => r).toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Reaction extends StatelessWidget {
  final IconData icon;
  final int count;
  final Color color;
  const _Reaction({required this.icon, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 4),
          Text('$count', style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}

class _FilePreview extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  const _FilePreview({required this.title, required this.subtitle, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber, width: 2),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(icon, color: Colors.amber, size: 32),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              SelectableText(subtitle, style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ],
      ),
    );
  }
}
