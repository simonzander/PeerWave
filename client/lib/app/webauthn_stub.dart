import 'package:flutter/material.dart';

Future<bool> webauthnRegister(String serverUrl, String email) async {
  // Fallback: always return false
  return false;
}

class WebauthnPage extends StatelessWidget {
  const WebauthnPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Center(
        child: Text(
          'WebAuthn is not supported on this platform.',
          style: Theme.of(context).textTheme.headlineMedium,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

