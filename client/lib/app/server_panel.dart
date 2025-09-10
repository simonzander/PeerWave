import 'package:flutter/material.dart';

class ServerPanel extends StatelessWidget {
  final void Function()? onAddServer;
  final List<Widget> serverIcons;

  const ServerPanel({
    super.key,
    required this.onAddServer,
    required this.serverIcons,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      color: const Color(0xFF202225),
      child: Column(
        children: [
          const SizedBox(height: 16),
          ...serverIcons,
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.add_circle, color: Colors.white, size: 36),
            onPressed: onAddServer,
            tooltip: 'Add Server',
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
