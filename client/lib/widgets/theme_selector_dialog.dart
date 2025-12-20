import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/theme_provider.dart';
import '../theme/color_schemes.dart';

/// Theme Selector Dialog
/// 
/// A Material 3 dialog that allows users to:
/// - Switch between 8 color schemes
/// - Toggle between Light, Dark, and System theme modes
/// - Preview colors before applying
/// - See current selection highlighted
class ThemeSelectorDialog extends StatelessWidget {
  const ThemeSelectorDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    return Dialog(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            _buildHeader(context, colorScheme),
            
            const Divider(height: 1),
            
            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Theme Mode Section
                    _buildThemeModeSection(context, themeProvider, colorScheme),
                    
                    const SizedBox(height: 32),
                    
                    // Color Scheme Section
                    _buildColorSchemeSection(context, themeProvider, colorScheme),
                  ],
                ),
              ),
            ),
            
            const Divider(height: 1),
            
            // Actions
            _buildActions(context, themeProvider, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          Icon(
            Icons.palette_outlined,
            size: 28,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Theme Einstellungen',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Wähle dein bevorzugtes Farbschema',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThemeModeSection(
    BuildContext context,
    ThemeProvider themeProvider,
    ColorScheme colorScheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Modus',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(height: 16),
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment<ThemeMode>(
              value: ThemeMode.light,
              label: Text('Hell'),
              icon: Icon(Icons.light_mode_outlined),
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.dark,
              label: Text('Dunkel'),
              icon: Icon(Icons.dark_mode_outlined),
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.system,
              label: Text('System'),
              icon: Icon(Icons.brightness_auto_outlined),
            ),
          ],
          selected: {themeProvider.themeMode},
          onSelectionChanged: (Set<ThemeMode> newSelection) {
            themeProvider.setThemeMode(newSelection.first);
          },
          style: ButtonStyle(
            visualDensity: VisualDensity.comfortable,
          ),
        ),
      ],
    );
  }

  Widget _buildColorSchemeSection(
    BuildContext context,
    ThemeProvider themeProvider,
    ColorScheme colorScheme,
  ) {
    final allSchemes = ColorSchemeOptions.all;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Farbschema',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(height: 16),
        
        // Color Scheme Grid
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 2.5,
          ),
          itemCount: allSchemes.length,
          itemBuilder: (context, index) {
            final scheme = allSchemes[index];
            final isSelected = scheme.id == themeProvider.colorSchemeId;
            
            return _buildColorSchemeCard(
              context,
              scheme,
              isSelected,
              () => themeProvider.setColorScheme(scheme.id),
            );
          },
        ),
      ],
    );
  }

  Widget _buildColorSchemeCard(
    BuildContext context,
    ColorSchemeOption scheme,
    bool isSelected,
    VoidCallback onTap,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Material(
      color: isSelected 
        ? colorScheme.primaryContainer 
        : colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected 
                ? colorScheme.primary 
                : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              // Color Preview
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.previewColor,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: isSelected
                  ? Icon(
                      Icons.check,
                      color: _getContrastColor(scheme.previewColor),
                      size: 20,
                    )
                  : null,
              ),
              
              const SizedBox(width: 12),
              
              // Name and Icon
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Icon(
                          scheme.icon,
                          size: 16,
                          color: isSelected 
                            ? colorScheme.onPrimaryContainer 
                            : colorScheme.onSurface,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            scheme.name,
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: isSelected 
                                ? colorScheme.onPrimaryContainer 
                                : colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      scheme.description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isSelected 
                          ? colorScheme.onPrimaryContainer.withValues(alpha: 0.7)
                          : colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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

  Widget _buildActions(
    BuildContext context,
    ThemeProvider themeProvider,
    ColorScheme colorScheme,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Reset Button
          TextButton.icon(
            onPressed: () {
              themeProvider.resetToDefaults();
            },
            icon: const Icon(Icons.restart_alt),
            label: const Text('Zurücksetzen'),
          ),
          
          // Close Button
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.check),
            label: const Text('Fertig'),
          ),
        ],
      ),
    );
  }

  /// Helper to determine contrast color for check icon
  Color _getContrastColor(Color background) {
    // Calculate relative luminance
    final luminance = (0.299 * (background.r * 255.0).round().clamp(0, 255) + 
                      0.587 * (background.g * 255.0).round().clamp(0, 255) + 
                      0.114 * (background.b * 255.0).round().clamp(0, 255)) / 255;
    
    return luminance > 0.5 ? Colors.black87 : Colors.white;
  }

  /// Static method to show the dialog
  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (context) => const ThemeSelectorDialog(),
    );
  }
}

