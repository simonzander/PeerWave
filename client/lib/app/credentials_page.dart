import 'package:flutter/material.dart';

class CredentialsPage extends StatelessWidget {
  const CredentialsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text('Credentials Settings', style: Theme.of(context).textTheme.headlineMedium),
    );
  }
}

