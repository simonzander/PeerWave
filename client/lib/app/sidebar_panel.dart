import 'package:flutter/material.dart';

class SidebarPanel extends StatelessWidget {
  final double panelWidth;
  final Widget Function() buildProfileCard;
  const SidebarPanel({Key? key, required this.panelWidth, required this.buildProfileCard}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height,
      width: panelWidth,
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
              Row(
                children: [
                  const Icon(Icons.people, color: Colors.white),
                  const SizedBox(width: 8),
                  const Text('People', style: TextStyle(color: Colors.white)),
                ],
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

              // Upcoming Meetings dropdown
              const _UpcomingMeetingsDropdown(),
              const Divider(color: Colors.white24),
              const _ChannelsDropdown(),
              const Divider(color: Colors.white24),
              const _DirectMessagesDropdown(),
              const Spacer(),
              buildProfileCard(),
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
  const _ChannelsDropdown({Key? key}) : super(key: key);

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
              onPressed: () {},
            ),
          ],
        ),
        AnimatedCrossFade(
          firstChild: Container(),
          secondChild: Padding(
            padding: const EdgeInsets.only(left: 32.0, top: 4.0, bottom: 4.0),
            child: Text('No channels', style: TextStyle(color: Colors.white70)),
          ),
          crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}

class _DirectMessagesDropdown extends StatefulWidget {
  const _DirectMessagesDropdown({Key? key}) : super(key: key);

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
            child: Text('No messages', style: TextStyle(color: Colors.white70)),
          ),
          crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}
