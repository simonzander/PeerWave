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
      print('[SIGNAL SETUP SCREEN] Error during setup: $e');
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
                  // Go to app anyway (risky but allows recovery)
                  GoRouter.of(context).go('/app');
                },
                child: const Text('Skip'),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2C2F33),
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
                      color: const Color(0xFF40444B),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: const Icon(
                      Icons.security,
                      size: 100,
                      color: Colors.blueAccent,
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
                    backgroundColor: const Color(0xFF40444B),
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Status Text
              Text(
                _statusText,
                style: const TextStyle(
                  color: Colors.white,
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
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),

              // Completion indicator
              if (_isComplete)
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Ready!',
                      style: TextStyle(
                        color: Colors.green,
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
