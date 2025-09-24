import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dashboard_page.dart';
import 'profile_card.dart';
import 'sidebar_panel.dart';
import 'server_panel.dart';
import '../auth/auth_layout_web.dart' if (dart.library.io) '../auth/auth_layout_native.dart';

class AppLayout extends StatefulWidget {
  const AppLayout({super.key});

  @override
  State<AppLayout> createState() => _AppLayoutState();
}

class _AppLayoutState extends State<AppLayout> {
  Widget currentPage = const DashboardPage();
  bool showLogin = false;

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
    final bool isWeb = kIsWeb;
    final double sidebarWidth = isWeb ? 350 : 300;
    final double serverPanelWidth = isWeb ? 0 : 80;

    return Scaffold(
      body: Row(
        children: [
          // ServerPanel (native only)
          if (!isWeb)
            Container(
              width: serverPanelWidth,
              color: Colors.black,
              child: ServerPanel(
                onAddServer: _showLoginPage,
              ),
            ),
          // SidebarPanel (responsive)
          LayoutBuilder(
            builder: (context, constraints) {
              double width = sidebarWidth;
              if (constraints.maxWidth < 600) {
                width = 80; // Collapse sidebar for small screens
              }
              return SizedBox(
                width: width,
                child: SidebarPanel(panelWidth: width, buildProfileCard: () => const ProfileCard()),
              );
            },
          ),
          // Main content (dashboard)
          Expanded(
            child: Container(
              color: const Color(0xFF36393F),
              child: currentPage,
            ),
          ),
        ],
      ),
      // Overlay login for web
      extendBody: true,
      extendBodyBehindAppBar: true,
      // Show login overlay if needed
      floatingActionButton: (showLogin && isWeb)
          ? Container(
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
            )
          : null,
    );
  }
}