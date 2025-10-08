import 'package:flutter/material.dart';
import 'sidebar_panel.dart';
import 'profile_card.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:go_router/go_router.dart';
import '../services/socket_service.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

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
                  child: SidebarPanel(panelWidth: width, buildProfileCard: () => const ProfileCard(), socket: socket, host: host ?? ''),
                );
              },
            ),
            Expanded(
              child: Container(
                color: const Color(0xFF36393F),
                child: Column(
                  children: [
                    // Titlebar
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                      color: Colors.grey[850],
                      child: Row(
                        children: [
                          // Channel title (left)
                          const Text(
                            '# general',
                            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          // Icon bar (right)
                          IconButton(
                            icon: const Icon(Icons.push_pin, color: Colors.white),
                            tooltip: 'Pin Channel',
                            onPressed: () {},
                          ),
                          IconButton(
                            icon: const Icon(Icons.video_call, color: Colors.white),
                            tooltip: 'Instant Meeting',
                            onPressed: () {},
                          ),
                          IconButton(
                            icon: const Icon(Icons.settings, color: Colors.white),
                            tooltip: 'Channel Settings',
                            onPressed: () {},
                          ),
                          Container(
                            width: 180,
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            child: TextField(
                              decoration: InputDecoration(
                                hintText: 'Search...',
                                hintStyle: TextStyle(color: Colors.white54),
                                filled: true,
                                fillColor: Colors.grey[800],
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                              ),
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.group, color: Colors.white),
                            tooltip: 'Members',
                            onPressed: () {},
                          ),
                        ],
                      ),
                    ),
                    // Chat content
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(24),
                        children: [
                          _ChatMessage(
                            avatar: 'https://randomuser.me/api/portraits/women/1.jpg',
                            name: 'Tina Chen',
                            time: '12:47 AM',
                            text: 'I must decline for secret reasons.',
                            reactions: [],
                          ),
                          _ChatMessage(
                            avatar: 'https://randomuser.me/api/portraits/women/2.jpg',
                            name: 'Lane Collins',
                            time: '11:50 AM',
                            text: 'Really need to give some kudos to @julie for helping out with the new influx of tweets yesterday. People are really, really excited about yesterday’s announcements.',
                            reactions: [
                              _Reaction(icon: Icons.favorite, count: 1, color: Colors.red),
                              _Reaction(icon: Icons.emoji_emotions, count: 2, color: Colors.yellow),
                              _Reaction(icon: Icons.back_hand, count: 1, color: Colors.amber),
                            ],
                          ),
                          _ChatMessage(
                            avatar: 'https://randomuser.me/api/portraits/men/3.jpg',
                            name: 'Kiné Camara',
                            time: '12:55 PM',
                            text: 'No! It was my pleasure! People are very excited.',
                            reactions: [],
                          ),
                          _ChatMessage(
                            avatar: 'https://randomuser.me/api/portraits/men/4.jpg',
                            name: 'Jason Stewart',
                            time: '2:14 PM',
                            text: 'What are our policies in regards to pets in the office? I’m assuming it’s a no-go, but thought I would ask here just to make sure what was the case.',
                            reactions: [],
                          ),
                          _ChatMessage(
                            avatar: 'https://randomuser.me/api/portraits/men/5.jpg',
                            name: 'Johnny Rodgers',
                            time: '2:18 PM',
                            text: 'Johnny Rodgers | GSuite presentation',
                            reactions: [],
                            filePreview: _FilePreview(
                              title: 'Building Policies & Procedures',
                              subtitle: 'Presentation from Google Drive',
                              icon: Icons.insert_drive_file,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Chat input
                    Container(
                      color: Colors.grey[850],
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
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
                            ),
                          ),
                          const SizedBox(width: 12),
                          IconButton(
                            icon: const Icon(Icons.send, color: Colors.white),
                            onPressed: () {},
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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
