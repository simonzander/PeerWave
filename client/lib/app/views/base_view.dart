import 'package:flutter/material.dart';
import '../../widgets/context_panel.dart';
import '../../config/layout_config.dart';

/// Base class for all main app views (Activities, Messages, Channels, People, Files)
///
/// Provides common structure: Context Panel (optional) + Main Content
/// Each view can customize its layout by implementing abstract methods
abstract class BaseView extends StatefulWidget {
  final String host;

  const BaseView({super.key, required this.host});
}

/// Base state for all views
///
/// Handles common functionality:
/// - Loading states
/// - Error handling
/// - Context Panel + Main Content layout
/// - Responsive behavior
abstract class BaseViewState<T extends BaseView> extends State<T> {
  // Common state
  bool _isLoading = false;
  String? _error;

  /// Whether to show context panel (left sidebar on desktop)
  bool get shouldShowContextPanel => true;

  /// Type of context panel to display
  ContextPanelType get contextPanelType;

  /// Build the context panel widget
  /// Only called if shouldShowContextPanel is true
  Widget buildContextPanel();

  /// Build the main content area
  Widget buildMainContent();

  /// Access loading state
  bool get isLoading => _isLoading;

  /// Access error state
  String? get error => _error;

  /// Set loading state
  void setLoading(bool loading) {
    if (mounted) {
      setState(() {
        _isLoading = loading;
      });
    }
  }

  /// Set error state
  void setError(String? error) {
    if (mounted) {
      setState(() {
        _error = error;
      });
    }
  }

  /// Clear error
  void clearError() {
    setError(null);
  }

  @override
  Widget build(BuildContext context) {
    // Error state
    if (_error != null) {
      return _buildErrorState();
    }

    // Check layout type
    final width = MediaQuery.of(context).size.width;
    final layoutType = LayoutConfig.getLayoutType(width);

    // Only show context panel on desktop (not on tablet or mobile)
    final showContextPanel =
        shouldShowContextPanel && layoutType == LayoutType.desktop;

    // Layout: Context Panel (optional) + Main Content
    return Row(
      children: [
        // Context Panel (left sidebar, ~280px) - only on desktop
        if (showContextPanel) buildContextPanel(),

        // Main Content (takes remaining space)
        Expanded(child: buildMainContent()),
      ],
    );
  }

  /// Build error state widget
  Widget _buildErrorState() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: colorScheme.error),
            const SizedBox(height: 16),
            Text(
              _error!,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.error,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                clearError();
                // Subclass should override to implement retry logic
                onRetry();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  /// Called when user taps retry button
  /// Subclasses should override to implement retry logic
  void onRetry() {
    // Default: just clear error
    clearError();
  }
}
