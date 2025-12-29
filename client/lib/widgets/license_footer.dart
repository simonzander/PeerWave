import 'package:flutter/material.dart';
import '../services/api_service.dart';

/// License Footer Widget - Shows "Private/Non-Commercial Use" for non-commercial licenses
class LicenseFooter extends StatefulWidget {
  const LicenseFooter({super.key});

  @override
  State<LicenseFooter> createState() => _LicenseFooterState();
}

class _LicenseFooterState extends State<LicenseFooter> {
  bool _showNotice = true;
  bool _isLoading = true;
  String _message = 'Private/Non-Commercial Use';
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _loadLicenseInfo();
  }

  Future<void> _loadLicenseInfo() async {
    try {
      ApiService.init();
      final dio = ApiService.dio;
      final resp = await dio.get('/api/license-info');

      if (resp.statusCode == 200) {
        final data = resp.data;
        setState(() {
          _showNotice = data['showNotice'] ?? true;
          _message = data['message'] ?? 'Private/Non-Commercial Use';
          _isError = data['isError'] ?? false;
          _isLoading = false;
        });
      }
    } catch (e) {
      // Default to non-commercial if request fails
      setState(() {
        _showNotice = true;
        _message = 'Private/Non-Commercial Use';
        _isError = false;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading || !_showNotice) {
      // Show empty space while loading or if no notice needed
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(16.0),
      alignment: Alignment.center,
      child: Text(
        _message,
        style: TextStyle(
          color: _isError
              ? theme.colorScheme.error
              : theme.colorScheme.onSurface.withValues(alpha: 0.6),
          fontSize: 11,
          fontWeight: _isError ? FontWeight.w600 : FontWeight.normal,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
