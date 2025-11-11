import 'package:flutter/material.dart';
import 'base_view.dart';
import '../../widgets/context_panel.dart';

/// Files View Page
/// 
/// Shows all files shared across channels and direct messages
/// No context panel - files view is self-contained
/// TODO: Implement FilesView widget (currently placeholder)
class FilesViewPage extends BaseView {
  const FilesViewPage({
    super.key,
    required super.host,
  });

  @override
  State<FilesViewPage> createState() => _FilesViewPageState();
}

class _FilesViewPageState extends BaseViewState<FilesViewPage> {
  @override
  bool get shouldShowContextPanel => false; // No context panel for files
  
  @override
  ContextPanelType get contextPanelType => ContextPanelType.none;
  
  @override
  Widget buildContextPanel() {
    // Not used - shouldShowContextPanel is false
    return const SizedBox.shrink();
  }
  
  @override
  Widget buildMainContent() {
    // Placeholder - FilesView needs to be implemented
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.insert_drive_file_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            'Files View',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'File management view - to be implemented',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
