import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/signal_service.dart';

/// Screen displayed during Signal Protocol key generation
/// Shows PeerWave logo, progress bar, and status text
class SignalSetupScreen extends StatefulWidget {
  const SignalSetupScreen({Key? key}) : super(key: key);

  @override
  State<SignalSetupScreen> createState() => _SignalSetupScreenState();
}

class _SignalSetupScreenState extends State<SignalSetupScreen> {
  String _statusText = 'Initializing Signal Protocol...';
  double _progress = 0.0;
  int _currentStep = 0;
  int _totalSteps = 112;
  bool _isComplete = false;

  @override
  void initState() {
    super.initState();
    _startSignalSetup();
  }

  Future<void> _startSignalSetup() async {
    try {
      await SignalService.instance.initWithProgress(
        (String statusText, int current, int total, double percentage) {
          if (mounted) {
            setState(() {
              _statusText = statusText;
              _currentStep = current;
              _totalSteps = total;
              _progress = percentage / 100.0;
            });
          }
        },
      );

      // Setup complete - navigate to app
      if (mounted) {
        setState(() {
          _isComplete = true;
          _statusText = 'Setup complete! Redirecting...';
          _progress = 1.0;
        });

        // Small delay before navigation
        await Future.delayed(const Duration(milliseconds: 500));

        if (mounted) {
          GoRouter.of(context).go('/app');
        }
      }
    } catch (e) {
      debugPrint('[SIGNAL SETUP SCREEN] Error during setup: $e');
      
      // Check if it's an authentication error
      final errorMessage = e.toString();
      if (errorMessage.contains('Device identity not initialized') ||
          errorMessage.contains('Encryption key not found') ||
          errorMessage.contains('Please log in')) {
        // Redirect to login
        if (mounted) {
          debugPrint('[SIGNAL SETUP SCREEN] Authentication required, redirecting to login...');
          GoRouter.of(context).go('/login');
        }
        return;
      }
      
      // Other errors - show retry dialog
      if (mounted) {
        setState(() {
          _statusText = 'Setup failed. Please try again.';
        });

        // Show error dialog
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Setup Failed'),
            content: Text('Failed to initialize Signal Protocol: $e'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  // Retry setup
                  _startSignalSetup();
                },
                child: const Text('Retry'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  // Go to login
                  GoRouter.of(context).go('/login');
                },
                child: const Text('Re-Login'),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(40),
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // PeerWave Logo
              Image.asset(
                'assets/images/peerwave.png',
                width: 200,
                height: 200,
                errorBuilder: (context, error, stackTrace) {
                  // Fallback if image not found
                  return Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Icon(
                      Icons.security,
                      size: 100,
                      color: colorScheme.primary,
                    ),
                  );
                },
              ),
              const SizedBox(height: 60),

              // Progress Bar
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 12,
                  child: LinearProgressIndicator(
                    value: _progress,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Status Text
              Text(
                _statusText,
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),

              // Progress Details
              if (!_isComplete)
                Text(
                  '${(_progress * 100).toInt()}% complete',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),

              // Completion indicator
              if (_isComplete)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle, color: colorScheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Ready!',
                      style: TextStyle(
                        color: colorScheme.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

