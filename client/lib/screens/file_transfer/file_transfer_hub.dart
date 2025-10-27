import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// File Transfer Hub - Central navigation for P2P file sharing features
class FileTransferHub extends StatelessWidget {
  const FileTransferHub({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('P2P File Sharing'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 600),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Header
              Icon(
                Icons.share,
                size: 80,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                'P2P File Sharing',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Secure peer-to-peer file transfer with encryption',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              
              // Navigation Cards
              _buildNavigationCard(
                context,
                title: 'Upload File',
                subtitle: 'Share a file with the network',
                icon: Icons.cloud_upload,
                color: Colors.blue,
                onTap: () => context.go('/file-upload'),
              ),
              const SizedBox(height: 16),
              _buildNavigationCard(
                context,
                title: 'Browse Files',
                subtitle: 'Discover and download available files',
                icon: Icons.folder_open,
                color: Colors.green,
                onTap: () => context.go('/file-browser'),
              ),
              const SizedBox(height: 16),
              _buildNavigationCard(
                context,
                title: 'Downloads',
                subtitle: 'Monitor active and completed downloads',
                icon: Icons.download,
                color: Colors.orange,
                onTap: () => context.go('/downloads'),
              ),
              
              const SizedBox(height: 48),
              
              // Info Box
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue[700]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Files are encrypted and transferred directly between peers using WebRTC.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.blue[900],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavigationCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 32, color: color),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios, size: 20, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}
