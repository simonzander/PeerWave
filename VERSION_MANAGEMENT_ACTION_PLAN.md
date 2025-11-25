# Version Management & Auto-Update Action Plan

## 📋 Project Overview

**Goal:** Implement centralized version management and semi-automatic update system for PeerWave desktop clients (Windows & macOS).

**Approach:**
- Manual download in Phase 1 (user clicks download link)
- GitHub Repository as single source of truth
- No code signing (SmartScreen warnings acceptable for now)
- Range-based compatibility matching between client and server

---

## 🎯 Implementation Phases

### Phase 1: Foundation - Centralized Version Management ✅ CURRENT
**Timeline:** Day 1-2

#### 1.1 Version Configuration
- [x] Create `version_config.yaml` in project root
- [x] Define semantic versioning schema (MAJOR.MINOR.PATCH)
- [x] Set min/max compatibility ranges for client ↔ server

#### 1.2 Build-Time Version Injection
- [x] Create Dart code generator script: `tools/generate_version.dart`
- [x] Generate `lib/core/version/version_info.dart` from config
- [x] Update `build-and-start.ps1` to run generator before build
- [x] Add version info to server configuration

#### 1.3 Version Display
- [x] Update title bar to show dynamic version from `version_info.dart`
- [x] Add "About" dialog with version details
- [x] Display version in server logs on startup

**Deliverables:**
```
✅ version_config.yaml
✅ tools/generate_version.dart
✅ lib/core/version/version_info.dart (generated)
✅ Updated build-and-start.ps1
✅ Updated custom_window_title_bar.dart
```

---

### Phase 2: Version Compatibility Check
**Timeline:** Day 3-4

#### 2.1 Server Version Endpoint
- [ ] Create `/api/version` endpoint returning:
  ```json
  {
    "version": "1.0.0",
    "min_client_version": "0.9.0",
    "max_client_version": "1.2.x",
    "features": ["e2ee", "group_chat", "file_sharing"]
  }
  ```

#### 2.2 Client Version Manager
- [ ] Create `lib/core/version/version_manager.dart`
- [ ] Implement range matching logic (e.g., "1.0.x" matches "1.0.0" - "1.0.99")
- [ ] Check compatibility on:
  - App startup
  - Reconnection after network loss
  - Server switchover

#### 2.3 Compatibility UI
- [ ] Warning dialog: "Server version X.Y.Z - suboptimal compatibility"
- [ ] Error dialog: "Server requires client version X.Y.Z or higher"
- [ ] Status indicator in UI (green/yellow/red dot)

**Deliverables:**
```
⏳ server/routes/version.go (or equivalent)
⏳ lib/core/version/version_manager.dart
⏳ lib/widgets/version_compatibility_dialog.dart
```

---

### Phase 3: GitHub Actions Build Pipeline
**Timeline:** Day 5-7

#### 3.1 Windows Build Workflow
- [ ] Create `.github/workflows/build-windows.yml`
- [ ] Trigger on Git tags: `v*` (e.g., `v1.0.0`)
- [ ] Build Flutter Windows desktop app
- [ ] Package as `.zip` with installer script
- [ ] Upload to GitHub Releases

#### 3.2 macOS Build Workflow
- [ ] Create `.github/workflows/build-macos.yml`
- [ ] Build Flutter macOS app bundle
- [ ] Create `.dmg` installer (using `create-dmg`)
- [ ] Upload to GitHub Releases

#### 3.3 Release Manifest
- [ ] Auto-generate `latest.json` in each release:
  ```json
  {
    "version": "1.0.0",
    "release_date": "2025-11-24T10:00:00Z",
    "downloads": {
      "windows": "https://github.com/.../PeerWave-1.0.0-windows.zip",
      "macos": "https://github.com/.../PeerWave-1.0.0-macos.dmg"
    },
    "min_server_version": "1.0.0",
    "changelog": "..."
  }
  ```

**Deliverables:**
```
⏳ .github/workflows/build-windows.yml
⏳ .github/workflows/build-macos.yml
⏳ .github/workflows/generate-manifest.yml
```

---

### Phase 4: Update Notification System
**Timeline:** Day 8-10

#### 4.1 Update Checker Service
- [ ] Create `lib/core/update/update_checker.dart`
- [ ] Poll GitHub Releases API:
  ```
  GET https://api.github.com/repos/simonzander/PeerWave/releases/latest
  ```
- [ ] Parse `latest.json` from release assets
- [ ] Compare local version with remote version
- [ ] Check frequency: Daily on app start + manual button

#### 4.2 Update Notification UI
- [ ] In-app banner: "New version X.Y.Z available"
- [ ] Action button: "Download Update"
- [ ] Opens browser to GitHub Release page
- [ ] Settings option: "Check for updates on startup" (toggle)

#### 4.3 Changelog Display
- [ ] Fetch release notes from GitHub API
- [ ] Display in dialog with Markdown rendering
- [ ] Show what's new, bug fixes, breaking changes

**Deliverables:**
```
⏳ lib/core/update/update_checker.dart
⏳ lib/widgets/update_notification_banner.dart
⏳ lib/screens/settings/update_settings.dart
```

---

### Phase 5: Enhanced Update Experience (Future)
**Timeline:** Post-MVP

#### 5.1 In-App Downloader
- [ ] Download release artifact directly in app
- [ ] Progress bar with download speed
- [ ] Verify SHA256 checksum
- [ ] Save to temp directory

#### 5.2 Semi-Automatic Installation
- [ ] **Windows:** Extract ZIP → Run installer script → Restart app
- [ ] **macOS:** Mount DMG → Copy to /Applications → Restart app
- [ ] Backup old version before replacement
- [ ] Rollback mechanism if installation fails

#### 5.3 Delta Updates
- [ ] Calculate binary diff between versions
- [ ] Download only changed files (~10-50% of full size)
- [ ] Requires custom build infrastructure

---

## 🔧 Technical Specifications

### Version Numbering

**Semantic Versioning:** `MAJOR.MINOR.PATCH+BUILD`
- **MAJOR:** Breaking API changes, incompatible with older versions
- **MINOR:** New features, backward-compatible
- **PATCH:** Bug fixes, no API changes
- **BUILD:** Auto-incremented build number (optional)

**Examples:**
- `1.0.0` - Initial release
- `1.1.0` - Added group video calls
- `1.1.1` - Fixed E2EE crash on Windows
- `2.0.0` - New authentication system (breaking)

### Compatibility Matching

**Range Notation:**
- `1.0.0` - Exact match
- `1.0.x` - Any patch version (1.0.0 - 1.0.99)
- `1.x.x` - Any minor version (1.0.0 - 1.99.99)
- `>=1.0.0 <2.0.0` - Range notation

**Matching Logic:**
```dart
bool isCompatible(String clientVersion, String minVersion, String maxVersion) {
  return Version.parse(clientVersion) >= Version.parse(minVersion) &&
         Version.parse(clientVersion) < Version.parse(maxVersion);
}
```

**Example Scenarios:**
| Client | Min Server | Max Server | Result |
|--------|------------|------------|--------|
| 1.0.0  | 0.9.0      | 1.2.0      | ✅ Compatible |
| 1.5.0  | 0.9.0      | 1.2.0      | ⚠️ Warning (newer client) |
| 0.8.0  | 0.9.0      | 1.2.0      | ❌ Blocked (too old) |
| 2.0.0  | 0.9.0      | 1.2.0      | ❌ Blocked (major mismatch) |

### GitHub as Source of Truth

**Why GitHub Repository:**
1. **Transparency:** Public releases visible to all users
2. **Audit Trail:** Git history tracks every version change
3. **Free Hosting:** Unlimited bandwidth for open-source
4. **API Access:** REST API for automated checks
5. **Security:** HTTPS + GitHub's infrastructure

**No Code Signing Implications:**
- **Windows:** SmartScreen warning on first run ("Unknown publisher")
  - Users must click "More info" → "Run anyway"
  - After ~100 downloads, SmartScreen learns and stops warning
- **macOS:** Gatekeeper blocks unsigned apps
  - Users must right-click → "Open" on first run
  - Or disable Gatekeeper: `xattr -cr PeerWave.app`

**Mitigation:**
- Clear installation instructions in README
- Screenshot tutorial for bypassing security warnings
- Future: Consider EV code signing certificate (~€400/year)

---

## 📦 File Structure

```
PeerWave/
├── version_config.yaml                    # ✅ Single source of truth
├── tools/
│   ├── generate_version.dart              # ✅ Build-time code generator
│   └── pubspec.yaml                       # ✅ Tool dependencies
├── client/
│   ├── lib/
│   │   ├── core/
│   │   │   ├── version/
│   │   │   │   ├── version_info.dart      # ✅ Generated file (gitignored)
│   │   │   └── update/
│   │   │       └── update_checker.dart    # ✅ GitHub API integration
│   │   └── widgets/
│   │       ├── update_notification_banner.dart  # ✅ Update UI
│   │       └── about_dialog.dart          # ✅ Version info dialog
│   └── pubspec.yaml                       # ✅ Updated with yaml package
├── server/
│   ├── routes/
│   │   └── client.js                      # ✅ /client/meta with version info
│   └── package.json                       # ✅ Updated with js-yaml
├── .github/
│   └── workflows/
│       ├── build-windows.yml              # ✅ Windows CI/CD
│       ├── build-macos.yml                # ✅ macOS CI/CD
│       └── release-manifest.yml           # ✅ Release metadata
└── build-and-start.ps1                    # ✅ Updated with version gen
```

---

## 🚀 Implementation Status

### Phase 1: Foundation - Centralized Version Management ✅ **COMPLETE**

✅ Created `version_config.yaml` with semantic versioning schema  
✅ Built `tools/generate_version.dart` code generator  
✅ Generated `lib/core/version/version_info.dart` from config  
✅ Updated `build-and-start.ps1` to run generator before build  
✅ Updated title bar with dynamic version display  
✅ Created "About" dialog with full version details  
✅ Added generated files to `.gitignore`

### Phase 2: Version Compatibility Check ✅ **COMPLETE**

✅ Enhanced `/client/meta` endpoint with version info  
✅ Added compatibility ranges (min/max versions)  
✅ Included feature flags (e2ee, groupCalls, fileSharing)  
✅ Loaded version from `version_config.yaml` on server startup  

### Phase 3: GitHub Actions Build Pipeline ✅ **COMPLETE**

✅ Created `.github/workflows/build-windows.yml` - Flutter Windows build + ZIP  
✅ Created `.github/workflows/build-macos.yml` - Flutter macOS build + DMG  
✅ Created `.github/workflows/release-manifest.yml` - Auto-generate `latest.json`  
✅ Workflows trigger on Git tags (`v*`)  
✅ Automatic artifact upload to GitHub Releases  

### Phase 4: Update Notification System ✅ **COMPLETE**

✅ Created `update_checker.dart` - GitHub Releases API polling  
✅ Version comparison logic with semantic versioning  
✅ Automatic update checks (daily) + manual trigger  
✅ Created `update_notification_banner.dart` - In-app banner UI  
✅ Update details dialog with changelog display  
✅ Platform-specific download links (Windows/macOS)  
✅ Dismiss/snooze update notifications  

### Phase 5: Enhanced Update Experience ⏳ **FUTURE**

⏳ In-app downloader with progress bar  
⏳ Semi-automatic installation (extract + restart)  
⏳ SHA256 checksum verification  
⏳ Rollback mechanism if installation fails  
⏳ Delta updates (bandwidth optimization)  

---

## 📖 Usage Guide

### How to Release a New Version

1. **Update version_config.yaml:**
   ```yaml
   client:
     version: "1.1.0"  # Change this
     build_number: 2   # Increment this
   ```

2. **Commit and tag:**
   ```bash
   git add version_config.yaml
   git commit -m "Release v1.1.0"
   git tag v1.1.0
   git push origin main --tags
   ```

3. **GitHub Actions automatically:**
   - Builds Windows app (ZIP)
   - Builds macOS app (DMG)
   - Creates GitHub Release with artifacts
   - Generates `latest.json` manifest

4. **Clients auto-detect update:**
   - Update banner appears in app
   - Users click "Details" → Download
   - Manual installation for now

### How to Integrate Update Checker

Add to your main app:

```dart
import 'package:peerwave_client/core/update/update_checker.dart';
import 'package:peerwave_client/widgets/update_notification_banner.dart';

class MyApp extends StatefulWidget {
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final updateChecker = UpdateChecker();
  
  @override
  void initState() {
    super.initState();
    updateChecker.initialize().then((_) {
      updateChecker.checkForUpdates();
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            UpdateNotificationBanner(updateChecker: updateChecker),
            Expanded(child: YourMainContent()),
          ],
        ),
      ),
    );
  }
}
```

### Manual Update Check

Add button anywhere:

```dart
ElevatedButton(
  onPressed: () async {
    await updateChecker.clearDismissed();
    await updateChecker.checkForUpdates(force: true);
  },
  child: Text('Nach Updates suchen'),
)
```

---

## 🎯 Success Metrics

- ✅ Single command updates version everywhere (`version_config.yaml`)
- ✅ Server provides version info via `/client/meta`
- ✅ Automatic builds on Git tags
- ✅ Users notified of updates within 24 hours
- ⏳ Smooth update process (<5 clicks to new version)

---

### Step 1: Create Version Config
```yaml
# version_config.yaml
project:
  name: "PeerWave"
  description: "Decentralized peer-to-peer communication platform"

client:
  version: "1.0.0"
  build_number: 1
  min_server_version: "1.0.0"
  max_server_version: "1.x.x"

server:
  version: "1.0.0"
  min_client_version: "0.9.0"
  max_client_version: "1.x.x"
```

### Step 2: Generate Version Code
```dart
// tools/generate_version.dart
// Reads version_config.yaml → Generates version_info.dart
```

### Step 3: Update Build Script
```powershell
# build-and-start.ps1
dart run tools/generate_version.dart
flutter build windows --release
docker-compose up -d
```

### Step 4: Display Version in UI
```dart
// custom_window_title_bar.dart
Text(VersionInfo.version) // Instead of hardcoded "v1.0.0"
```

---

## 📊 Success Metrics

- [x] Single command updates version everywhere (`version_config.yaml`)
- [ ] Server rejects incompatible clients gracefully
- [ ] Users notified of updates within 24 hours
- [ ] Smooth update process (<5 clicks to new version)
- [ ] Zero downtime during server updates

---

## 🔮 Future Enhancements

1. **Auto-Install:** Background downloads + one-click installation
2. **Beta Channel:** Opt-in to pre-release versions
3. **Rollback System:** Revert to previous version if issues occur
4. **Code Signing:** Windows/macOS certificates for better UX
5. **Delta Updates:** Bandwidth-efficient incremental updates
6. **Mobile Updates:** iOS TestFlight + Google Play integration
7. **Release Notes:** In-app changelog with rich formatting
8. **Update Statistics:** Track update adoption rates

---

## 📅 Timeline Summary

| Phase | Duration | Status |
|-------|----------|--------|
| Phase 1: Foundation | 2 days | 🚧 In Progress |
| Phase 2: Compatibility | 2 days | ⏳ Planned |
| Phase 3: CI/CD | 3 days | ⏳ Planned |
| Phase 4: Notifications | 3 days | ⏳ Planned |
| Phase 5: Auto-Install | 5 days | 💡 Future |

**Total MVP Time:** ~10 days
**Full Auto-Update:** ~15 days

---

*Last Updated: November 24, 2025*
