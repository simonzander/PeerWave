// Example integration of RoleProvider in main.dart
// This is a reference implementation - adapt to your existing main.dart structure

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/role_provider.dart';
import 'services/role_api_service.dart';
import 'web_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Load server URL from config (web platform)
  String? serverUrl = await loadWebApiServer();
  serverUrl ??= 'http://localhost:3000'; // Fallback for non-web platforms
  
  runApp(MyApp(serverUrl: serverUrl));
}

class MyApp extends StatelessWidget {
  final String serverUrl;

  const MyApp({Key? key, required this.serverUrl}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Add your existing providers here
        // Example:
        // ChangeNotifierProvider(create: (context) => AuthProvider()),
        // ChangeNotifierProvider(create: (context) => ChatProvider()),
        
        // Add RoleProvider
        ChangeNotifierProvider(
          create: (context) => RoleProvider(
            apiService: RoleApiService(baseUrl: serverUrl),
          ),
        ),
      ],
      child: MaterialApp(
        title: 'PeerWave',
        theme: ThemeData(
          primarySwatch: Colors.blue,
          useMaterial3: true,
        ),
        home: const HomePage(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    _loadUserRoles();
  }

  Future<void> _loadUserRoles() async {
    // Load roles after successful login
    // You might want to check if user is logged in first
    try {
      final roleProvider = Provider.of<RoleProvider>(context, listen: false);
      await roleProvider.loadUserRoles();
    } catch (e) {
      // User might not be logged in yet, that's okay
      debugPrint('Could not load user roles: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PeerWave'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Welcome to PeerWave'),
            const SizedBox(height: 20),
            
            // Example: Show admin panel button only to admins
            Consumer<RoleProvider>(
              builder: (context, roleProvider, child) {
                if (roleProvider.isAdmin) {
                  return ElevatedButton(
                    onPressed: () {
                      // Navigate to role management screen
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const AdminPanelExample(),
                        ),
                      );
                    },
                    child: const Text('Admin Panel'),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ],
        ),
      ),
    );
  }
}

// Example Admin Panel
class AdminPanelExample extends StatelessWidget {
  const AdminPanelExample({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Panel'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('Role Management'),
            subtitle: const Text('Manage user roles and permissions'),
            onTap: () {
              // Navigate to RoleManagementScreen
              // Navigator.push(...);
            },
          ),
          ListTile(
            leading: const Icon(Icons.people),
            title: const Text('User Management'),
            subtitle: const Text('Manage users'),
            onTap: () {
              // Navigate to user management
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Server Settings'),
            subtitle: const Text('Configure server settings'),
            onTap: () {
              // Navigate to settings
            },
          ),
        ],
      ),
    );
  }
}

// Example: Login page - call loadUserRoles after successful authentication
class LoginPageExample extends StatelessWidget {
  const LoginPageExample({Key? key}) : super(key: key);

  Future<void> _handleLogin(BuildContext context) async {
    // Your login logic here
    // ...

    // After successful login, load user roles
    final roleProvider = Provider.of<RoleProvider>(context, listen: false);
    await roleProvider.loadUserRoles();

    // Navigate to home page
    if (context.mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const HomePage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => _handleLogin(context),
          child: const Text('Login'),
        ),
      ),
    );
  }
}

// Example: Logout - clear roles
class LogoutExample {
  static Future<void> logout(BuildContext context) async {
    // Clear user roles
    final roleProvider = Provider.of<RoleProvider>(context, listen: false);
    roleProvider.clearRoles();

    // Your other logout logic
    // ...

    // Navigate to login page
    if (context.mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const LoginPageExample()),
        (route) => false,
      );
    }
  }
}
