import 'dart:io';
import 'package:yaml/yaml.dart';

/// PeerWave Version Manager
/// 
/// Manages semantic versioning in version_config.yaml
/// 
/// Usage:
///   dart run tools/version_manager.dart patch     # 1.0.0 -> 1.0.1
///   dart run tools/version_manager.dart minor     # 1.0.5 -> 1.1.0
///   dart run tools/version_manager.dart major     # 1.5.3 -> 2.0.0
///   dart run tools/version_manager.dart current   # Show current version
///   dart run tools/version_manager.dart add-changelog "1.0.1" "Bug fixes"

void main(List<String> args) {
  if (args.isEmpty) {
    printUsage();
    exit(1);
  }

  final command = args[0];
  
  switch (command) {
    case 'patch':
      bumpVersion('patch');
      break;
    case 'minor':
      bumpVersion('minor');
      break;
    case 'major':
      bumpVersion('major');
      break;
    case 'current':
      showCurrentVersion();
      break;
    case 'add-changelog':
      if (args.length < 3) {
        print('Error: add-changelog requires version and changelog entry');
        print('Usage: dart run tools/version_manager.dart add-changelog "1.0.1" "Change description"');
        exit(1);
      }
      addChangelog(args[1], args[2]);
      break;
    default:
      print('Unknown command: $command');
      printUsage();
      exit(1);
  }
}

void printUsage() {
  print('''
PeerWave Version Manager

Usage:
  dart run tools/version_manager.dart <command> [args]

Commands:
  patch              Bump patch version (1.0.0 -> 1.0.1)
  minor              Bump minor version (1.0.5 -> 1.1.0)
  major              Bump major version (1.5.3 -> 2.0.0)
  current            Show current version
  add-changelog      Add changelog entry for a version
  
Examples:
  dart run tools/version_manager.dart patch
  dart run tools/version_manager.dart add-changelog "1.0.1" "Security fixes"
''');
}

void showCurrentVersion() {
  final config = loadConfig();
  final version = config['client']['version'] as String;
  final buildNumber = config['client']['build_number'] as int;
  
  print('Current Version: $version');
  print('Build Number: $buildNumber');
}

void bumpVersion(String type) {
  final configFile = File('version_config.yaml');
  if (!configFile.existsSync()) {
    print('Error: version_config.yaml not found');
    exit(1);
  }

  final config = loadConfig();
  final currentVersion = config['client']['version'] as String;
  final currentBuildNumber = config['client']['build_number'] as int;
  
  final version = parseVersion(currentVersion);
  
  // Bump version based on type
  switch (type) {
    case 'patch':
      version[2]++;
      break;
    case 'minor':
      version[1]++;
      version[2] = 0;
      break;
    case 'major':
      version[0]++;
      version[1] = 0;
      version[2] = 0;
      break;
  }
  
  final newVersion = '${version[0]}.${version[1]}.${version[2]}';
  final newBuildNumber = currentBuildNumber + 1;
  
  // Read original file content
  final content = configFile.readAsStringSync();
  
  // Replace client version and build number
  var newContent = content.replaceFirst(
    RegExp(r'  version: "[^"]+"', multiLine: true),
    '  version: "$newVersion"',
  );
  
  newContent = newContent.replaceFirst(
    RegExp(r'  build_number: \d+', multiLine: true),
    '  build_number: $newBuildNumber',
  );
  
  // Also update server version to match client
  newContent = newContent.replaceFirst(
    RegExp(r'server:\n  # Semantic versioning: MAJOR\.MINOR\.PATCH\n  version: "[^"]+"', multiLine: true),
    'server:\n  # Semantic versioning: MAJOR.MINOR.PATCH\n  version: "$newVersion"',
  );
  
  // Write back
  configFile.writeAsStringSync(newContent);
  
  print('✅ Version bumped: $currentVersion -> $newVersion');
  print('✅ Build number: $currentBuildNumber -> $newBuildNumber');
  print('📝 Tag: v$newVersion');
}

void addChangelog(String version, String changeEntry) {
  final configFile = File('version_config.yaml');
  if (!configFile.existsSync()) {
    print('Error: version_config.yaml not found');
    exit(1);
  }

  final content = configFile.readAsStringSync();
  final now = DateTime.now();
  final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  
  // Check if version entry already exists
  if (content.contains('version: "$version"')) {
    print('⚠️  Changelog entry for version $version already exists');
    print('📝 Manually edit version_config.yaml to update changelog');
    return;
  }
  
  // Create new changelog entry
  final changelogEntry = '''
  - version: "$version"
    date: "$date"
    changes:
      - "$changeEntry"
''';
  
  // Insert after "changelog:" line
  final newContent = content.replaceFirst(
    'changelog:\n',
    'changelog:\n$changelogEntry',
  );
  
  configFile.writeAsStringSync(newContent);
  
  print('✅ Added changelog entry for version $version');
  print('📅 Date: $date');
  print('📝 Change: $changeEntry');
}

Map<String, dynamic> loadConfig() {
  final configFile = File('version_config.yaml');
  final yamlString = configFile.readAsStringSync();
  final yamlMap = loadYaml(yamlString) as YamlMap;
  
  return {
    'client': {
      'version': yamlMap['client']['version'],
      'build_number': yamlMap['client']['build_number'],
    },
    'server': {
      'version': yamlMap['server']['version'],
    },
  };
}

List<int> parseVersion(String version) {
  final parts = version.split('.');
  if (parts.length != 3) {
    print('Error: Invalid version format: $version');
    exit(1);
  }
  
  return parts.map((p) => int.parse(p)).toList();
}
