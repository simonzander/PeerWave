import 'package:flutter/material.dart';

class BackupCodeListPage extends StatelessWidget {
  const BackupCodeListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Center(
        child: Text(
          'Backup codes are not supported on this platform.',
          style: Theme.of(context).textTheme.headlineMedium,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
