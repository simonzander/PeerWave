import 'package:flutter/material.dart';

/// Progress bar widget for the registration flow
/// Shows 4 steps: OTP → Backup Codes → Security Key → Profile
class RegistrationProgressBar extends StatelessWidget {
  final int currentStep;

  const RegistrationProgressBar({super.key, required this.currentStep});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outline,
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          // Step indicators
          Row(
            children: [
              _buildStepIndicator(context, 1, 'OTP', currentStep >= 1),
              _buildConnector(context, currentStep >= 2),
              _buildStepIndicator(context, 2, 'Backup Codes', currentStep >= 2),
              _buildConnector(context, currentStep >= 3),
              _buildStepIndicator(context, 3, 'Security Key', currentStep >= 3),
              _buildConnector(context, currentStep >= 4),
              _buildStepIndicator(context, 4, 'Profile', currentStep >= 4),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(
    BuildContext context,
    int step,
    String label,
    bool isActive,
  ) {
    return Expanded(
      child: Column(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: isActive
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
              border: Border.all(
                color: isActive
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outline,
                width: 2,
              ),
            ),
            child: Center(
              child: isActive
                  ? (currentStep == step
                        ? Text(
                            step.toString(),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          )
                        : Icon(
                            Icons.check,
                            color: Theme.of(context).colorScheme.onPrimary,
                            size: 24,
                          ))
                  : Text(
                      step.toString(),
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.5),
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              color: isActive
                  ? Theme.of(context).colorScheme.onSurface
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
              fontSize: 12,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildConnector(BuildContext context, bool isActive) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 30),
        color: isActive
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
      ),
    );
  }
}
