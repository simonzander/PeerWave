# Mobile WebAuthn Implementation

## Overview
Native biometric authentication for iOS and Android using Face ID, Touch ID, and fingerprint scanning. This eliminates the need for magic key authentication on mobile devices.

## Features
- **Biometric Authentication**: Face ID (iOS), Touch ID (iOS), Fingerprint (Android), Face Recognition (Android)
- **Secure Storage**: Credentials stored in iOS Keychain and Android KeyStore
- **WebAuthn Compatible**: Works with existing server endpoints
- **Fallback Option**: Magic key authentication still available if needed

## Architecture

### Components

1. **MobileWebAuthnService** (`lib/services/webauthn_service_mobile.dart`)
   - Simulates WebAuthn API using device biometric hardware
   - Methods:
     - `isBiometricAvailable()` - Check if biometrics are supported
     - `getAvailableBiometrics()` - Get list of available biometric types
     - `register(serverUrl, email)` - Register new credential with biometric
     - `authenticate(serverUrl, email)` - Login with stored credential
     - `hasCredential(serverUrl, email)` - Check if credential exists
     - `deleteCredential(serverUrl, email)` - Remove stored credential
   
2. **MobileWebAuthnLoginScreen** (`lib/screens/mobile_webauthn_login_screen.dart`)
   - Mobile-optimized authentication UI
   - Server URL input with auto-https
   - Email validation
   - Biometric status display
   - Platform-specific icons (Face ID, Touch ID, fingerprint)
   - Login and register flows
   - Fallback to magic key option

### Flow

#### Registration Flow
1. User enters server URL and email
2. App checks biometric availability
3. User taps "Register This Device"
4. App requests registration challenge from server
5. Biometric prompt shown (Face ID/Touch ID/Fingerprint)
6. On successful biometric authentication:
   - Generate credential ID from server URL + email (SHA256)
   - Create attestation object (WebAuthn format)
   - Send to server for registration
   - Store credential securely in Keychain/KeyStore
7. Navigate to app

#### Authentication Flow
1. User enters server URL and email
2. App checks for existing credential
3. User taps "Sign In"
4. App requests authentication challenge from server
5. Biometric prompt shown
6. On successful biometric authentication:
   - Retrieve stored credential
   - Generate assertion (WebAuthn format)
   - Send to server for verification
7. Navigate to app

## Server Endpoints

Uses existing WebAuthn endpoints:
- `POST /webauthn/register-challenge` - Get registration challenge
- `POST /webauthn/register` - Complete registration
- `POST /webauthn/authenticate-challenge` - Get authentication challenge
- `POST /webauthn/authenticate` - Complete authentication

## Dependencies

```yaml
local_auth: ^2.3.0  # Biometric authentication
flutter_secure_storage: ^9.0.0  # Secure credential storage
crypto: ^3.0.3  # SHA256 hashing
http: ^1.1.0  # Server communication
```

## Platform Configuration

### iOS (Required)
Add to `ios/Runner/Info.plist`:
```xml
<key>NSFaceIDUsageDescription</key>
<string>PeerWave uses Face ID to securely authenticate you</string>
<key>NSBiometricAuthenticationUsageDescription</key>
<string>PeerWave uses biometric authentication for secure login</string>
```

### Android (Already Configured)
Permissions already added in `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.USE_BIOMETRIC"/>
<uses-permission android:name="android.permission.USE_FINGERPRINT"/>
```

## Testing

### Android Testing
1. **Start Android Emulator**:
   ```bash
   # List available emulators
   flutter emulators
   
   # Launch specific emulator
   flutter emulators --launch <emulator_id>
   
   # Or use VS Code: Ctrl+Shift+P → "Flutter: Launch Emulator"
   ```

2. **Run App**:
   ```bash
   cd client
   flutter run
   ```

3. **Test Registration**:
   - Enter server URL (e.g., `https://yourserver.com`)
   - Enter email address
   - Tap "Register This Device"
   - Complete biometric prompt
   - Verify successful navigation to app

4. **Test Login**:
   - Close and restart app
   - Enter same server URL and email
   - Tap "Sign In"
   - Complete biometric prompt
   - Verify successful login

### iOS Testing
1. **Physical Device Required** (Face ID/Touch ID not fully supported in simulator)
   - Connect iPhone/iPad via USB
   - Select device in VS Code
   - Run: `flutter run`

2. **Update Info.plist** (if not already done):
   ```bash
   # Edit ios/Runner/Info.plist
   # Add NSFaceIDUsageDescription and NSBiometricAuthenticationUsageDescription
   ```

3. **Test** same as Android steps above

## Security Considerations

1. **Credential Storage**: 
   - iOS: Stored in Keychain with biometric protection
   - Android: Stored in KeyStore with hardware-backed security

2. **Credential ID Generation**:
   - Deterministic: SHA256(serverUrl + email)
   - Same credential ID across app reinstalls
   - Allows multiple server/email combinations

3. **Authentication Signature**:
   - Generated from challenge + timestamp + email
   - Includes client data JSON (WebAuthn format)
   - Base64URL encoded

4. **Biometric Requirements**:
   - deviceCredential: false (biometric only, no PIN fallback)
   - stickyAuth: true (doesn't cancel on app switch)
   - sensitiveTransaction: true (requires fresh biometric)

## Known Limitations

1. **Session Verification**: Currently auto-accepts after WebAuthn (TODO: Implement proper session verification)
2. **Server Configuration**: Temporarily uses active server only (TODO: Proper multi-server integration)
3. **iOS Permissions**: Must be added manually to Info.plist before iOS testing
4. **Simulator Testing**: Biometric prompts may not work fully in simulators

## Troubleshooting

### "Biometric not available"
- Check device has enrolled Face ID/Touch ID/Fingerprint
- Android: Settings → Security → Fingerprint/Face Recognition
- iOS: Settings → Face ID & Passcode or Touch ID & Passcode

### "No credential found"
- User must register first before logging in
- Check server URL and email match exactly
- Try registering again

### "Authentication failed"
- Biometric didn't match
- Try again or use "Sign in with Magic Key" fallback

### "Connection error"
- Check server URL is correct (auto-adds https://)
- Verify server is running and accessible
- Check network connectivity

## Future Enhancements

1. Multi-server credential management
2. Credential synchronization across devices (via server)
3. Biometric re-enrollment flow
4. Advanced security options (PIN fallback, timeout settings)
5. Credential backup/recovery options

## Status

✅ Implementation complete (Phases 1-5)
⏳ Testing on devices (Phase 6-7)
⏳ Documentation and rollout (Phase 8)

Last updated: Current build
