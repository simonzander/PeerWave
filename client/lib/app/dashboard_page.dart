import 'package:flutter/material.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text("📊 Dashboard Inhalte",
          style: TextStyle(color: Colors.white, fontSize: 20)),
    );
  }
}
