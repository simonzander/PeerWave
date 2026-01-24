import 'package:go_router/go_router.dart';

// File transfer screens
import '../../screens/file_transfer/file_upload_screen.dart';
import '../../screens/file_transfer/file_manager_screen.dart';
import '../../screens/file_transfer/file_browser_screen.dart';
import '../../screens/file_transfer/downloads_screen.dart';
import '../../screens/file_transfer/file_transfer_hub.dart';
import '../../widgets/socket_aware_widget.dart';

/// Returns the file transfer routes
/// These routes handle P2P file transfer functionality including upload, download, and management
List<GoRoute> getFileRoutes() {
  return [
    GoRoute(
      path: '/file-transfer',
      builder: (context, state) => const SocketAwareWidget(
        featureName: 'File Transfer Hub',
        child: FileTransferHub(),
      ),
    ),
    GoRoute(
      path: '/file-upload',
      builder: (context, state) => const SocketAwareWidget(
        featureName: 'File Upload',
        child: FileUploadScreen(),
      ),
    ),
    GoRoute(
      path: '/file-manager',
      builder: (context, state) => const SocketAwareWidget(
        featureName: 'File Manager',
        child: FileManagerScreen(),
      ),
    ),
    GoRoute(
      path: '/file-browser',
      builder: (context, state) => const SocketAwareWidget(
        featureName: 'File Browser',
        child: FileBrowserScreen(),
      ),
    ),
    GoRoute(
      path: '/downloads',
      builder: (context, state) => const DownloadsScreen(),
    ),
  ];
}
