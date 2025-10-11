
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import '../services/api_service.dart';
import 'dart:convert';


class SidebarPanel extends StatefulWidget {
  final double panelWidth;
  final Widget Function() buildProfileCard;
  final IO.Socket? socket;
  final String host;
  final VoidCallback? onPeopleTap;
  final List<Map<String, String>>? directMessages;
  final void Function(String uuid, String displayName)? onDirectMessageTap;
  const SidebarPanel({Key? key, required this.panelWidth, required this.buildProfileCard, this.socket, required this.host, this.onPeopleTap, this.directMessages, this.onDirectMessageTap}) : super(key: key);

  @override
  State<SidebarPanel> createState() => _SidebarPanelState();
}

class _SidebarPanelState extends State<SidebarPanel> {
  List<String> generalMessages = [];
  List<String> channelNames = [];

  @override
  void initState() {
    super.initState();
    _fetchChannels();
  }

  Future<void> _fetchChannels() async {
  try {
    ApiService.init();
    final dio = ApiService.dio;
    final resp = await dio.get('${widget.host}/client/channels');
    if (resp.statusCode == 201) {
      final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
      if (data is List) {
        setState(() {
          channelNames = data.map<String>((c) => c['name']?.toString() ?? '').where((n) => n.isNotEmpty).toList();
        });
      }
    }
  } catch (e) {
    // Handle error or timeout
    print('Error fetching channels: $e');
  }
}

  @override
  void dispose() {
    //widget.socket?.off('general');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height,
      width: widget.panelWidth,
      margin: EdgeInsets.only(bottom: 0, top: 0, left: 0, right: 0),
      child: Material(
        color: Colors.grey[900],
        elevation: 8,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 0.0, horizontal: 0.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // People entry
              InkWell(
                onTap: widget.onPeopleTap,
                child: Row(
                  children: [
                    const Icon(Icons.people, color: Colors.white),
                    const SizedBox(width: 8),
                    const Text('People', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // Files entry
              Row(
                children: [
                  const Icon(Icons.insert_drive_file, color: Colors.white),
                  const SizedBox(width: 8),
                  const Text('Files', style: TextStyle(color: Colors.white)),
                ],
              ),
              const SizedBox(height: 8),
              // Divider
              const Divider(color: Colors.white24),

              // Example: Show general channel messages
              if (generalMessages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('General Channel:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ...generalMessages.map((msg) => Text(msg, style: const TextStyle(color: Colors.white70))),
                    ],
                  ),
                ),

              // Upcoming Meetings dropdown
              const _UpcomingMeetingsDropdown(),
              const Divider(color: Colors.white24),
              _ChannelsDropdown(channelNames: channelNames, host: widget.host),
              const Divider(color: Colors.white24),
              _DirectMessagesDropdown(
                directMessages: widget.directMessages ?? [],
                onDirectMessageTap: widget.onDirectMessageTap,
              ),
              const Spacer(),
              widget.buildProfileCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpcomingMeetingsDropdown extends StatefulWidget {
  const _UpcomingMeetingsDropdown({Key? key}) : super(key: key);

  @override
  State<_UpcomingMeetingsDropdown> createState() => _UpcomingMeetingsDropdownState();
}

class _UpcomingMeetingsDropdownState extends State<_UpcomingMeetingsDropdown> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, color: Colors.white),
              onPressed: () => setState(() => expanded = !expanded),
            ),
            const Text('Upcoming Meetings', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.add, color: Colors.white),
              onPressed: () {},
            ),
          ],
        ),
        AnimatedCrossFade(
          firstChild: Container(),
          secondChild: Padding(
            padding: const EdgeInsets.only(left: 32.0, top: 4.0, bottom: 4.0),
            child: Text('No meetings', style: TextStyle(color: Colors.white70)),
          ),
          crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}

class _ChannelsDropdown extends StatefulWidget {
  final List<String> channelNames;
  final String host;
  const _ChannelsDropdown({Key? key, required this.channelNames, required this.host}) : super(key: key);

  @override
  State<_ChannelsDropdown> createState() => _ChannelsDropdownState();
}

class _ChannelsDropdownState extends State<_ChannelsDropdown> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, color: Colors.white),
              onPressed: () => setState(() => expanded = !expanded),
            ),
            const Text('Channels', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.add, color: Colors.white),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) {
                    String channelName = '';
                    String channelDescription = '';
                    // Use a StatefulBuilder to manage dialog state
                    bool isPrivate = false;
                    String selectedPermission = 'Contributor';
                    return StatefulBuilder(
                      builder: (dialogContext, setDialogState) {
                        return AlertDialog(
                          title: const Text('Add Channel'),
                          content: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextField(
                                  decoration: const InputDecoration(labelText: 'Channel Name'),
                                  onChanged: (value) => channelName = value,
                                ),
                                TextField(
                                  decoration: const InputDecoration(labelText: 'Description'),
                                  maxLines: 3,
                                  onChanged: (value) => channelDescription = value,
                                ),
                                Row(
                                  children: [
                                    Checkbox(
                                      value: isPrivate,
                                      onChanged: (value) {
                                        setDialogState(() {
                                          isPrivate = value ?? false;
                                        });
                                      },
                                    ),
                                    const Text('Private'),
                                  ],
                                ),
                                Row(
                                  children: [
                                    const Text('Default Member Permissions:'),
                                    const SizedBox(width: 8),
                                    DropdownButton<String>(
                                      value: selectedPermission,
                                      items: const [
                                        DropdownMenuItem(
                                          value: 'Read',
                                          child: Text('Read'),
                                        ),
                                        DropdownMenuItem(
                                          value: 'Read&Write',
                                          child: Text('Read&Write'),
                                        ),
                                        DropdownMenuItem(
                                          value: 'Contributor',
                                          child: Text('Contributor'),
                                        ),
                                        DropdownMenuItem(
                                          value: 'Admin',
                                          child: Text('Admin'),
                                        ),
                                      ],
                                      onChanged: (value) {
                                        setDialogState(() {
                                          selectedPermission = value ?? 'Contributor';
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(dialogContext).pop(),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed: () async {
                                try {
                                  ApiService.init();
                                  final dio = ApiService.dio;
                                  final resp = await dio.post(
                                    '${widget.host}/client/channels',
                                    data: {
                                      'name': channelName,
                                      'description': channelDescription,
                                      'private': isPrivate,
                                      'defaultPermissions': selectedPermission,
                                    },
                                    options: Options(contentType: 'application/json'),
                                  );
                                  if (resp.statusCode == 201) {
                                    setState(() {
                                      widget.channelNames.add(channelName);
                                    });
                                  }
                                } catch (e) {
                                  // Handle error
                                  print('Error creating channel: $e');
                                }
                                Navigator.of(dialogContext).pop();
                              },
                              child: const Text('Add'),
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            ),
          ],
        ),
        AnimatedCrossFade(
          firstChild: Container(),
          secondChild: Padding(
            padding: const EdgeInsets.only(left: 32.0, top: 4.0, bottom: 4.0),
            child: widget.channelNames.isEmpty
                ? Text('No channels', style: TextStyle(color: Colors.white70))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: widget.channelNames
                        .map((name) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2.0),
                              child: Text(name, style: TextStyle(color: Colors.white)),
                            ))
                        .toList(),
                  ),
          ),
          crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}


class _DirectMessagesDropdown extends StatefulWidget {
  final List<Map<String, String>> directMessages;
  final void Function(String uuid, String displayName)? onDirectMessageTap;
  const _DirectMessagesDropdown({Key? key, required this.directMessages, this.onDirectMessageTap}) : super(key: key);

  @override
  State<_DirectMessagesDropdown> createState() => _DirectMessagesDropdownState();
}

class _DirectMessagesDropdownState extends State<_DirectMessagesDropdown> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, color: Colors.white),
              onPressed: () => setState(() => expanded = !expanded),
            ),
            const Text('Direct Messages', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.add, color: Colors.white),
              onPressed: () {},
            ),
          ],
        ),
        AnimatedCrossFade(
          firstChild: Container(),
          secondChild: Padding(
            padding: const EdgeInsets.only(left: 32.0, top: 4.0, bottom: 4.0),
            child: widget.directMessages.isEmpty
                ? Text('No messages', style: TextStyle(color: Colors.white70))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: widget.directMessages.map((dm) {
                      final displayName = dm['displayName'] ?? 'Unknown';
                      final uuid = dm['uuid'] ?? '';
                      return InkWell(
                        onTap: () {
                          if (widget.onDirectMessageTap != null) {
                            widget.onDirectMessageTap!(uuid, displayName);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Row(
                            children: [
                              const Icon(Icons.person, color: Colors.white70, size: 18),
                              const SizedBox(width: 6),
                              Text(displayName, style: const TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
          ),
          crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}
