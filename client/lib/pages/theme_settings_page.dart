import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/theme_provider.dart';
import '../theme/color_schemes.dart';
import '../widgets/theme_selector_dialog.dart';

/// Theme Settings Page
///
/// A dedicated page for theme customization that can be added to your settings.
/// Shows current theme, quick theme mode toggle, and button to open full selector.
class ThemeSettingsPage extends StatelessWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final currentScheme = themeProvider.currentScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Theme Einstellungen')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Current Theme Preview Card
          _buildCurrentThemeCard(
            context,
            themeProvider,
            currentScheme,
            colorScheme,
          ),

          const SizedBox(height: 24),

          // Quick Theme Mode Toggle
          _buildThemeModeCard(context, themeProvider, colorScheme),

          const SizedBox(height: 24),

          // Open Full Selector Button
          _buildSelectorButton(context, colorScheme),

          const SizedBox(height: 24),

          // Info Card
          _buildInfoCard(context, colorScheme),
        ],
      ),
    );
  }

  Widget _buildCurrentThemeCard(
    BuildContext context,
    ThemeProvider themeProvider,
    ColorSchemeOption currentScheme,
    ColorScheme colorScheme,
  ) {
    return Card(
      elevation: 0,
      color: colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  currentScheme.icon,
                  size: 28,
                  color: colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Aktuelles Theme',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Color Preview Strip
            Row(
              children: [
                _buildColorCircle(colorScheme.primary, 'Primary'),
                const SizedBox(width: 8),
                _buildColorCircle(colorScheme.secondary, 'Secondary'),
                const SizedBox(width: 8),
                _buildColorCircle(colorScheme.tertiary, 'Tertiary'),
                const SizedBox(width: 8),
                _buildColorCircle(colorScheme.error, 'Error'),
              ],
            ),

            const SizedBox(height: 16),

            Text(
              currentScheme.name,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              currentScheme.description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildColorCircle(Color color, String label) {
    return Tooltip(
      message: label,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThemeModeCard(
    BuildContext context,
    ThemeProvider themeProvider,
    ColorScheme colorScheme,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Theme Modus',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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
            ),

            const SizedBox(height: 12),

            Text(
              _getThemeModeDescription(themeProvider.themeMode),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectorButton(BuildContext context, ColorScheme colorScheme) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: () => ThemeSelectorDialog.show(context),
        icon: const Icon(Icons.palette_outlined),
        label: const Text('Farbschema auswählen'),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context, ColorScheme colorScheme) {
    return Card(
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Deine Theme-Einstellungen werden automatisch gespeichert und beim nächsten Start wiederhergestellt.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getThemeModeDescription(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'App verwendet immer den hellen Modus';
      case ThemeMode.dark:
        return 'App verwendet immer den dunklen Modus';
      case ThemeMode.system:
        return 'App folgt den Systemeinstellungen';
    }
  }
}
