import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dashboard_page.dart';
import 'profile_card.dart';
// import 'sidebar_panel.dart';
import 'server_panel.dart';
import '../auth/auth_layout_web.dart' if (dart.library.io) '../auth/auth_layout_native.dart';
import 'package:go_router/go_router.dart';

class AppLayout extends StatelessWidget {
  final Widget? child;
  const AppLayout({super.key, this.child});

  @override
  Widget build(BuildContext context) {
    final bool isWeb = kIsWeb;
  final double sidebarWidth = isWeb ? 350 : 300;
    final double serverPanelWidth = isWeb ? 0 : 80;

    if (isWeb) {
      return Scaffold(
        body: child ?? const DashboardPage(),
      );
    } else {
      // Global Scaffold for native
      return Scaffold(
        body: Row(
          children: [
            if (serverPanelWidth > 0)
              Container(
                width: serverPanelWidth,
                color: Colors.black,
                child: ServerPanel(
                  onAddServer: () => GoRouter.of(context).go('/app/login'),
                  scaffoldContextProvider: () => context,
                ),
              ),
            Expanded(
              child: child ?? const DashboardPage(),
            ),
          ],
        ),
      );
    }
  }
}