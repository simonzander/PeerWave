import 'package:flutter/material.dart';

class ProfileCard extends StatelessWidget {
  const ProfileCard({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 8,
      color: Colors.grey[900],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundImage: AssetImage('assets/profile.jpg'), // Replace with your asset or network image
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your Name', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    Icon(Icons.circle, color: Colors.green, size: 12),
                    const SizedBox(width: 4),
                    Text('Online', style: TextStyle(color: Colors.green, fontSize: 12)),
                  ],
                ),
              ],
            ),
            const SizedBox(width: 16),
            Icon(Icons.mic, color: Colors.white),
            const SizedBox(width: 8),
            Icon(Icons.headphones, color: Colors.white),
            const SizedBox(width: 8),
            Icon(Icons.settings, color: Colors.white),
          ],
        ),
      ),
    );
  }
}
