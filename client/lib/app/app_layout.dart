import 'package:flutter/material.dart';
import 'dashboard_page.dart';
import 'server_panel.dart';
import '../auth/auth_layout.dart';

class AppLayout extends StatefulWidget {
  const AppLayout({super.key});

  @override
  State<AppLayout> createState() => _AppLayoutState();
}

class _AppLayoutState extends State<AppLayout> {
  Widget currentPage = const DashboardPage();
  bool showLogin = false;

  // Removed unused _setPage method

  void _showLoginPage() {
    setState(() {
      showLogin = true;
    });
  }

  void _hideLoginPage() {
    setState(() {
      showLogin = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              // Discord-like Server Panel
              ServerPanel(
                onAddServer: _showLoginPage,
                serverIcons: [
                  // Example server icons
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: CircleAvatar(
                      radius: 24,
                      backgroundColor: Colors.blue,
                      child: const Text('S1', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: CircleAvatar(
                      radius: 24,
                      backgroundColor: Colors.green,
                      child: const Text('S2', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
              ),
              // Main content
              Expanded(
                child: Container(
                  color: const Color(0xFF36393F),
                  child: currentPage,
                ),
              ),
            ],
          ),
          if (showLogin)
            Container(
              color: Colors.black.withOpacity(0.7),
              child: Center(
                child: SizedBox(
                  width: 350,
                  child: Material(
                    color: Colors.transparent,
                    child: Stack(
                      children: [
                        AuthLayout(),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: IconButton(
                            icon: const Icon(Icons.close, color: Colors.white),
                            onPressed: _hideLoginPage,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
