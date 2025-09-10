import 'package:flutter/material.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text("👤 Profil Inhalte",
          style: TextStyle(color: Colors.white, fontSize: 20)),
    );
  }
}
