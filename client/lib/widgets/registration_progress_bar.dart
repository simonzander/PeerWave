import 'package:flutter/material.dart';

/// Progress bar widget for the registration flow
/// Shows 4 steps: OTP → Backup Codes → Security Key → Profile
class RegistrationProgressBar extends StatelessWidget {
  final int currentStep;
  
  const RegistrationProgressBar({
    Key? key,
    required this.currentStep,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      decoration: const BoxDecoration(
        color: Color(0xFF23272A),
        border: Border(
          bottom: BorderSide(
            color: Color(0xFF40444B),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          // Step indicators
          Row(
            children: [
              _buildStepIndicator(1, 'OTP', currentStep >= 1),
              _buildConnector(currentStep >= 2),
              _buildStepIndicator(2, 'Backup Codes', currentStep >= 2),
              _buildConnector(currentStep >= 3),
              _buildStepIndicator(3, 'Security Key', currentStep >= 3),
              _buildConnector(currentStep >= 4),
              _buildStepIndicator(4, 'Profile', currentStep >= 4),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(int step, String label, bool isActive) {
    return Expanded(
      child: Column(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: isActive ? Colors.blueAccent : const Color(0xFF40444B),
              shape: BoxShape.circle,
              border: Border.all(
                color: isActive ? Colors.blueAccent : const Color(0xFF40444B),
                width: 2,
              ),
            ),
            child: Center(
              child: isActive
                  ? (currentStep == step
                      ? Text(
                          step.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        )
                      : const Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 24,
                        ))
                  : Text(
                      step.toString(),
                      style: const TextStyle(
                        color: Colors.white54,
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
              color: isActive ? Colors.white : Colors.white54,
              fontSize: 12,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildConnector(bool isActive) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 30),
        color: isActive ? Colors.blueAccent : const Color(0xFF40444B),
      ),
    );
  }
}

