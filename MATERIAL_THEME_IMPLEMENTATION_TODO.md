# Material Design 3 Theme System - Implementation TODO

## 🎨 Ziel
Flexibles Theme-System mit benutzerdefinierten Farbschemas, Spacing, Border Radius und Typography.

---

## 📋 Implementation Plan

### Phase 1: Basis-Struktur erstellen

#### 1.1 Verzeichnisstruktur anlegen
```
lib/
  theme/
    app_theme.dart          # Haupt-Theme Definition
    app_colors.dart         # ColorSchemes
    app_spacing.dart        # Spacing Constants
    app_border_radius.dart  # BorderRadius Constants
    app_text_styles.dart    # Custom TextStyles
    theme_provider.dart     # Theme State Management
```

#### 1.2 Dependencies hinzufügen
In `pubspec.yaml`:
```yaml
dependencies:
  provider: ^6.0.0           # State Management
  shared_preferences: ^2.0.0 # Persistente Speicherung
```

---

### Phase 2: Theme Constants definieren

#### 2.1 Spacing (`app_spacing.dart`)
```dart
class AppSpacing {
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 16.0;
  static const double lg = 24.0;
  static const double xl = 32.0;
  static const double xxl = 48.0;
}
```

#### 2.2 Border Radius (`app_border_radius.dart`)
```dart
class AppBorderRadius {
  static const BorderRadius none = BorderRadius.zero;
  static const BorderRadius small = BorderRadius.all(Radius.circular(4));
  static const BorderRadius medium = BorderRadius.all(Radius.circular(8));
  static const BorderRadius large = BorderRadius.all(Radius.circular(16));
  static const BorderRadius xlarge = BorderRadius.all(Radius.circular(24));
  static const BorderRadius full = BorderRadius.all(Radius.circular(9999));
  
  static BorderRadius circular(double radius) => 
    BorderRadius.all(Radius.circular(radius));
}
```

#### 2.3 Color Schemes (`app_colors.dart`)
```dart
class AppColors {
  // Vordefinierte Farbschemas für Nutzer-Auswahl
  static final Map<String, ColorScheme> lightSchemes = {
    'blue': ColorScheme.fromSeed(
      seedColor: Colors.blue,
      brightness: Brightness.light,
    ),
    'green': ColorScheme.fromSeed(
      seedColor: Colors.green,
      brightness: Brightness.light,
    ),
    'purple': ColorScheme.fromSeed(
      seedColor: Colors.purple,
      brightness: Brightness.light,
    ),
    'ocean': ColorScheme(
      brightness: Brightness.light,
      primary: Color(0xFF006874),
      onPrimary: Colors.white,
      secondary: Color(0xFF4A6267),
      onSecondary: Colors.white,
      error: Color(0xFFBA1A1A),
      onError: Colors.white,
      surface: Color(0xFFFBFDFD),
      onSurface: Color(0xFF191C1D),
    ),
    'sunset': ColorScheme.fromSeed(
      seedColor: Color(0xFFFF6B35),
      brightness: Brightness.light,
    ),
    'forest': ColorScheme.fromSeed(
      seedColor: Color(0xFF2D6A4F),
      brightness: Brightness.light,
    ),
  };
  
  static final Map<String, ColorScheme> darkSchemes = {
    'blue': ColorScheme.fromSeed(
      seedColor: Colors.blue,
      brightness: Brightness.dark,
    ),
    'green': ColorScheme.fromSeed(
      seedColor: Colors.green,
      brightness: Brightness.dark,
    ),
    // ... etc für alle Themes
  };
}
```

#### 2.4 Text Styles (`app_text_styles.dart`)
```dart
class AppTextStyles {
  static const String defaultFontFamily = 'Roboto';
  
  static TextTheme textTheme = TextTheme(
    displayLarge: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 57,
      fontWeight: FontWeight.w400,
      letterSpacing: -0.25,
    ),
    displayMedium: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 45,
      fontWeight: FontWeight.w400,
    ),
    displaySmall: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 36,
      fontWeight: FontWeight.w400,
    ),
    headlineLarge: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 32,
      fontWeight: FontWeight.w400,
    ),
    headlineMedium: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 28,
      fontWeight: FontWeight.w400,
    ),
    headlineSmall: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 24,
      fontWeight: FontWeight.w400,
    ),
    titleLarge: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 22,
      fontWeight: FontWeight.w500,
    ),
    titleMedium: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 16,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.15,
    ),
    titleSmall: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 14,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.1,
    ),
    bodyLarge: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 16,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.5,
    ),
    bodyMedium: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 14,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.25,
    ),
    bodySmall: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 12,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.4,
    ),
    labelLarge: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 14,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.1,
    ),
    labelMedium: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 12,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.5,
    ),
    labelSmall: TextStyle(
      fontFamily: defaultFontFamily,
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.5,
    ),
  );
}
```

---

### Phase 3: Theme Provider erstellen

#### 3.1 Theme Provider (`theme_provider.dart`)
```dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_colors.dart';
import 'app_theme.dart';

class ThemeProvider extends ChangeNotifier {
  // Storage Keys
  static const String _themeKey = 'selected_theme';
  static const String _themeModeKey = 'theme_mode';
  
  // State
  String _currentTheme = 'blue';
  ThemeMode _themeMode = ThemeMode.system;
  
  // Getters
  String get currentTheme => _currentTheme;
  ThemeMode get themeMode => _themeMode;
  
  ThemeData get lightTheme => AppTheme.light(
    AppColors.lightSchemes[_currentTheme]!,
  );
  
  ThemeData get darkTheme => AppTheme.dark(
    AppColors.darkSchemes[_currentTheme]!,
  );
  
  // Available themes for UI picker
  List<String> get availableThemes => AppColors.lightSchemes.keys.toList();
  
  // Load from storage
  Future<void> loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _currentTheme = prefs.getString(_themeKey) ?? 'blue';
    final modeIndex = prefs.getInt(_themeModeKey) ?? 0;
    _themeMode = ThemeMode.values[modeIndex];
    notifyListeners();
  }
  
  // Change theme
  Future<void> setTheme(String themeName) async {
    if (!AppColors.lightSchemes.containsKey(themeName)) {
      throw Exception('Theme "$themeName" not found');
    }
    
    _currentTheme = themeName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, themeName);
    notifyListeners();
  }
  
  // Change theme mode (light/dark/system)
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_themeModeKey, mode.index);
    notifyListeners();
  }
}
```

---

### Phase 4: Haupt-Theme Definition

#### 4.1 AppTheme (`app_theme.dart`)
```dart
import 'package:flutter/material.dart';
import 'app_spacing.dart';
import 'app_border_radius.dart';
import 'app_text_styles.dart';

class AppTheme {
  static ThemeData light(ColorScheme colorScheme) => _buildTheme(
    colorScheme: colorScheme,
    brightness: Brightness.light,
  );
  
  static ThemeData dark(ColorScheme colorScheme) => _buildTheme(
    colorScheme: colorScheme,
    brightness: Brightness.dark,
  );
  
  static ThemeData _buildTheme({
    required ColorScheme colorScheme,
    required Brightness brightness,
  }) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: brightness,
      
      // Visual Density
      visualDensity: VisualDensity.adaptivePlatformDensity,
      
      // Typography
      fontFamily: AppTextStyles.defaultFontFamily,
      textTheme: AppTextStyles.textTheme,
      
      // Card Theme
      cardTheme: CardTheme(
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: AppBorderRadius.large,
        ),
        margin: EdgeInsets.all(AppSpacing.sm),
      ),
      
      // Input Decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: AppBorderRadius.medium,
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
      ),
      
      // Button Themes
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: AppBorderRadius.medium,
          ),
          elevation: 2,
        ),
      ),
      
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: AppBorderRadius.small,
          ),
        ),
      ),
      
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: AppBorderRadius.medium,
          ),
        ),
      ),
      
      // Dialog Theme
      dialogTheme: DialogTheme(
        shape: RoundedRectangleBorder(
          borderRadius: AppBorderRadius.large,
        ),
        elevation: 8,
      ),
      
      // Bottom Sheet Theme
      bottomSheetTheme: BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.large.topLeft.x),
          ),
        ),
        elevation: 8,
      ),
      
      // App Bar Theme
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: false,
        titleTextStyle: AppTextStyles.textTheme.titleLarge?.copyWith(
          color: colorScheme.onSurface,
        ),
      ),
      
      // Floating Action Button
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: AppBorderRadius.large,
        ),
      ),
      
      // Chip Theme
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: AppBorderRadius.medium,
        ),
      ),
      
      // List Tile Theme
      listTileTheme: ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
      ),
    );
  }
}
```

---

### Phase 5: Integration in main.dart

#### 5.1 Main App Setup
```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'theme/theme_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize theme provider
  final themeProvider = ThemeProvider();
  await themeProvider.loadTheme();
  
  runApp(
    ChangeNotifierProvider.value(
      value: themeProvider,
      child: MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, _) {
        return MaterialApp(
          title: 'PeerWave',
          theme: themeProvider.lightTheme,
          darkTheme: themeProvider.darkTheme,
          themeMode: themeProvider.themeMode,
          home: HomeScreen(),
        );
      },
    );
  }
}
```

---

### Phase 6: Theme Picker UI erstellen

#### 6.1 Theme Settings Screen
```dart
class ThemeSettingsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    
    return Scaffold(
      appBar: AppBar(
        title: Text('Theme Settings'),
      ),
      body: ListView(
        padding: EdgeInsets.all(AppSpacing.md),
        children: [
          // Theme Mode Selection (Light/Dark/System)
          Card(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Theme Mode',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SizedBox(height: AppSpacing.sm),
                  SegmentedButton<ThemeMode>(
                    segments: [
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode),
                        label: Text('Light'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode),
                        label: Text('Dark'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.auto_mode),
                        label: Text('Auto'),
                      ),
                    ],
                    selected: {themeProvider.themeMode},
                    onSelectionChanged: (Set<ThemeMode> modes) {
                      themeProvider.setThemeMode(modes.first);
                    },
                  ),
                ],
              ),
            ),
          ),
          
          SizedBox(height: AppSpacing.md),
          
          // Color Scheme Selection
          Card(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Color Scheme',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SizedBox(height: AppSpacing.md),
                  ...themeProvider.availableThemes.map((themeName) {
                    final colorScheme = AppColors.lightSchemes[themeName]!;
                    final isSelected = themeProvider.currentTheme == themeName;
                    
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: colorScheme.primary,
                        child: isSelected
                            ? Icon(Icons.check, color: colorScheme.onPrimary)
                            : null,
                      ),
                      title: Text(
                        themeName.toUpperCase(),
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Row(
                        children: [
                          _ColorDot(color: colorScheme.primary),
                          SizedBox(width: AppSpacing.xs),
                          _ColorDot(color: colorScheme.secondary),
                          SizedBox(width: AppSpacing.xs),
                          _ColorDot(color: colorScheme.tertiary),
                        ],
                      ),
                      selected: isSelected,
                      onTap: () => themeProvider.setTheme(themeName),
                    );
                  }).toList(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  
  const _ColorDot({required this.color});
  
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.outline,
          width: 1,
        ),
      ),
    );
  }
}
```

---

### Phase 7: Custom Fonts (Optional)

#### 7.1 Fonts hinzufügen
1. Fonts in `client/assets/fonts/` ablegen
2. In `pubspec.yaml` registrieren:
```yaml
flutter:
  fonts:
    - family: Roboto
      fonts:
        - asset: assets/fonts/Roboto-Regular.ttf
        - asset: assets/fonts/Roboto-Medium.ttf
          weight: 500
        - asset: assets/fonts/Roboto-Bold.ttf
          weight: 700
    - family: Poppins
      fonts:
        - asset: assets/fonts/Poppins-Regular.ttf
        - asset: assets/fonts/Poppins-SemiBold.ttf
          weight: 600
```

3. In `app_text_styles.dart` verwenden

---

## 🧪 Testing Checklist

- [ ] Theme wechselt sofort (ohne App-Neustart)
- [ ] Theme wird beim App-Neustart korrekt geladen (persistent)
- [ ] Light/Dark Mode funktioniert für alle Themes
- [ ] System-Theme (Auto) folgt OS-Einstellung
- [ ] Alle UI-Komponenten verwenden Theme-Farben
- [ ] Spacing ist konsistent in allen Screens
- [ ] Border Radius ist einheitlich
- [ ] Fonts werden korrekt angezeigt

---

## 📦 Migration Existing Screens

Nach Implementation müssen bestehende Screens migriert werden:

### Vorher (Hardcoded):
```dart
Container(
  padding: EdgeInsets.all(16),
  decoration: BoxDecoration(
    color: Colors.blue,
    borderRadius: BorderRadius.circular(8),
  ),
)
```

### Nachher (Theme-basiert):
```dart
Container(
  padding: EdgeInsets.all(AppSpacing.md),
  decoration: BoxDecoration(
    color: Theme.of(context).colorScheme.primary,
    borderRadius: AppBorderRadius.medium,
  ),
)
```

---

## 🎯 Priority

1. **HIGH**: Phase 1-4 (Basis-System)
2. **MEDIUM**: Phase 5-6 (Integration + UI)
3. **LOW**: Phase 7 (Custom Fonts)

---

## 📚 Resources

- [Material Design 3](https://m3.material.io/)
- [Flutter ThemeData](https://api.flutter.dev/flutter/material/ThemeData-class.html)
- [ColorScheme](https://api.flutter.dev/flutter/material/ColorScheme-class.html)
- [Material Theme Builder](https://m3.material.io/theme-builder)
