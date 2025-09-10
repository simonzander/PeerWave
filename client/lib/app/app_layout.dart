import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/auth_service.dart';
import 'dashboard_page.dart';
import 'profile_page.dart';

class AppLayout extends StatefulWidget {
  const AppLayout({super.key});

  @override
  State<AppLayout> createState() => _AppLayoutState();
}

class _AppLayoutState extends State<AppLayout> {
  Widget currentPage = const DashboardPage();

  void _setPage(Widget page) {
    setState(() {
      currentPage = page;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // Sidebar
          Container(
            width: 200,
            color: const Color(0xFF2F3136),
            child: Column(
              children: [
                const SizedBox(height: 40),
                ListTile(
                  title: const Text("Dashboard"),
                  onTap: () => _setPage(const DashboardPage()),
                ),
                ListTile(
                  title: const Text("Profil"),
                  onTap: () => _setPage(const ProfilePage()),
                ),
                const Spacer(),
                ListTile(
                  title: const Text("Logout"),
                  onTap: () {
                    AuthService.logout();
                    context.go("/login");
                  },
                ),
              ],
            ),
          ),
          // Content
          Expanded(
            child: Container(
              color: const Color(0xFF36393F),
              child: currentPage,
            ),
          ),
        ],
      ),
    );
  }
}
