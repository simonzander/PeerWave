import 'package:flutter/material.dart';
import 'base_view.dart';
import '../../widgets/context_panel.dart';
import '../../screens/file_transfer/file_manager_screen.dart';

/// Files View Page
///
/// Shows file manager with local files and sharing capabilities
///
/// Structure:
/// - Desktop: Context Panel (FilesContextPanel) + Main Content (FileManagerScreen)
/// - Tablet: Main Content only (FileManagerScreen)
/// - Mobile: Main Content only (FileManagerScreen)
///
/// Features:
/// - File upload and management
/// - P2P file sharing
/// - Seeding status
/// - File filtering
class FilesViewPage extends BaseView {
  const FilesViewPage({super.key, required super.host});

  @override
  State<FilesViewPage> createState() => _FilesViewPageState();
}

class _FilesViewPageState extends BaseViewState<FilesViewPage> {
  @override
  ContextPanelType get contextPanelType => ContextPanelType.files;

  @override
  Widget buildContextPanel() {
    return ContextPanel(type: ContextPanelType.files);
  }

  @override
  Widget buildMainContent() {
    return const FileManagerScreen();
  }
}
