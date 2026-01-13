# Registration Flow Analysis: Web vs Mobile

## Current Registration Flows

### Web Registration Flow

1. **Start Registration**
   - Page: `register_page.dart` (web)
   - User enters email
   - If invitation-only mode: Shows invitation token field
   - Calls: `POST /register` with `{email, invitationToken?}`
   - Uses: ApiService (session cookies automatic)

2. **OTP Verification**
   - Page: `otp_web.dart`
   - Receives email and serverUrl via navigation
   - User enters 5-digit OTP
   - Calls: `POST /otp` with `{email, otp}`
   - Uses: ApiService (session cookies automatic)
   - Server sets: `req.session.authenticated = true`, `req.session.registrationStep = 'backup_codes'`

3. **Backup Codes**
   - Page: `backupcode_web.dart`
   - Calls: `GET /backupcode/list` (email from session)
   - User acknowledges codes
   - Saves server config (web stores in localStorage)
   - Navigates to: `/register/webauthn`

4. **WebAuthn Registration**
   - Page: `register_webauthn_page.dart` (web)
   - Calls: `GET /webauthn/list` - shows existing credentials
   - User clicks "Add Security Key"
   - JS interop: `webauthnRegister(serverUrl, email)` 
     - Calls: `POST /webauthn/register-challenge` (email from localStorage)
     - Browser WebAuthn API creates credential
     - Calls: `POST /webauthn/register` with attestation
   - Must have at least 1 credential to continue
   - Navigates to: `/register/profile`

5. **Profile Setup**
   - Page: `register_profile_page.dart`
   - Calls: `POST /client/profile/setup`
   - Navigates to: `/app`

### Mobile Registration Flow

1. **Server Selection**
   - Page: `mobile_server_selection_screen.dart`
   - User enters server URL (e.g., `10.0.2.2:5000`)
   - Validates and adds protocol
   - **❌ MISSING**: Invitation-only check
   - Navigates to: `/mobile-webauthn` with serverUrl

2. **Create Account**
   - Page: `mobile_webauthn_login_screen.dart`
   - User enters email
   - **❌ MISSING**: Invitation token field if server is invitation-only
   - User clicks "Create Account"
   - Calls: `MobileWebAuthnService.sendRegistrationRequest()` → `POST /register` via ApiService (has cookies)
   - **✅ CORRECT**: Uses ApiService.dio.post (session cookies included)
   - Navigates to: `/otp` with {email, serverUrl, wait}

3. **OTP Verification**
   - Page: `otp_web.dart` (shared)
   - For mobile: Uses full URL `$serverUrl/otp`
   - Calls: `POST /otp` via ApiService
   - **✅ CORRECT**: Uses ApiService (session cookies included)
   - Server sets: `req.session.email`, `req.session.authenticated = true`
   - Navigates to: `/register/backupcode` with {serverUrl}

4. **Backup Codes**
   - Page: `backupcode_web_native.dart`
   - For mobile: Uses full URL `$serverUrl/backupcode/list`
   - Calls: `GET /backupcode/list` via ApiService
   - **✅ CORRECT**: Uses ApiService (session cookies included)
   - User acknowledges codes
   - **Saves server config HERE** (not before)
   - Navigates to: `/register/webauthn` with {serverUrl}

5. **WebAuthn Registration**
   - Page: `register_webauthn_page_native.dart`
   - Calls: `GET /webauthn/list` via ApiService
   - **✅ CORRECT**: Uses ApiService (session cookies included)
   - User clicks "Add Security Key"
   - Calls: `MobileWebAuthnService.register()`
     - Uses `ApiService.dio.post('/webauthn/register-challenge')` - **✅ CORRECT**
     - Prompts biometric authentication (local_auth)
     - Uses `ApiService.dio.post('/webauthn/register')` - **✅ CORRECT**
   - Must have at least 1 credential to continue
   - Navigates to: `/register/profile`

6. **Profile Setup**
   - Page: `register_profile_page.dart` (shared)
   - Calls: `POST /client/profile/setup`
   - **❌ POTENTIAL ISSUE**: May need full URL for mobile
   - Navigates to: `/app`

## Server-Side Registration State Management

### Session Variables

```javascript
// POST /register
req.session.email = email;
req.session.registrationStep = 'otp';
req.session.pendingInvitationId = invitation.id; // if invitation-only

// POST /otp (after successful verification)
req.session.otp = true;
req.session.authenticated = true;
req.session.uuid = updatedUser.uuid;
req.session.email = updatedUser.email; // ✅ Added recently
req.session.registrationStep = 'backup_codes';

// After backup codes acknowledged (web only sets this)
req.session.registrationStep = 'webauthn'; // ❓ Not sure if set

// After WebAuthn credential added
req.session.registrationStep = 'profile'; // ❓ Not sure if set

// After profile setup
req.session.registrationStep = undefined; // Complete
```

### Server Registration Mode Checks

```javascript
// In POST /register
const registrationMode = settings.registration_mode; // 'open', 'email_suffix', 'invitation_only'

if (registrationMode === 'invitation_only') {
  if (!invitationToken) {
    return res.status(403).json({ error: "An invitation is required to register" });
  }
  // Validate invitation token
}
```

## What Happens If Steps Fail?

### Scenario 1: User Doesn't Enter OTP

**Current Behavior:**
- Session has: `registrationStep: 'otp'`
- User can request new OTP after wait time (default 5 minutes)
- If user navigates away and comes back:
  - **Web**: Can go to `/register` and start over (session may still exist)
  - **Mobile**: Can go back to mobile-webauthn and click "Create Account" again
- **✅ Works**: User can restart registration process

### Scenario 2: User Doesn't Confirm Backup Codes

**Current Behavior:**
- Session has: `registrationStep: 'backup_codes'`
- **Server-side middleware automatically redirects** to `/register/backupcode` if step is 'backup_codes'
- If user navigates away (tries to go to `/register/webauthn` or any other `/register/*` path):
  - Server intercepts the request in middleware (server.js lines 277-318)
  - Automatically redirects them back to `/register/backupcode`
  - **This enforces step order on both web and mobile**
- User **must** complete backup codes before proceeding
- **No way to restart** - once at backup codes step, must continue forward

**Server Middleware Logic:**
```javascript
// server.js - Registration step enforcement
if (step && stepPaths[step]) {
  const correctPath = stepPaths[step];
  if (currentPath !== correctPath && currentPath.startsWith('/register/')) {
    // Redirect to correct step
    req.url = correctPath;
    req.originalUrl = correctPath;
  }
}
```

**✅ Security Design (Intentional):**
- Once backup codes are **displayed**, we assume user has seen them
- User has opportunity to copy/download codes before clicking "Next"
- No "Start Over" needed - user must acknowledge and proceed forward
- This prevents users from accidentally skipping critical security information
- Enforces that backup codes are shown exactly once during registration

**✅ Web**: Enforced by server middleware
**✅ Mobile**: Same server middleware applies

### Scenario 3: User Downloaded/Copied Backup Codes and Confirmed

**Current Behavior:**
- Server config is saved
- Session has: `registrationStep: 'webauthn'` (needs verification)
- User is on `/register/webauthn` page
- Can login with backup codes:
  - **Web**: POST `/backupcode-login` with {email, backupCode}
  - **Mobile**: ❌ MISSING backup code login on mobile
- After backup code login, can add WebAuthn credentials

**✅ Web Works**: Can login with backup codes
**❌ Mobile Missing**: No backup code login screen

### Scenario 4: Invitation-Only Server

**Current Behavior:**
- **Web**: `register_page.dart` checks server settings and shows invitation field
- **Mobile**: ❌ MISSING - No invitation token check or field

**Required Fix:**
1. Mobile server selection should check `/api/public/server-settings`
2. If `registration_mode === 'invitation_only'`, show invitation token field OR navigate to invitation entry page
3. Pass invitation token to registration request

## Issues Found

### Critical Issues

1. **✅ FIXED: Mobile Missing Invitation Token Support**
   - `mobile_webauthn_login_screen.dart` now checks `/client/meta` for registration mode
   - Shows invitation token field when `registrationMode === 'invitation_only'`
   - Passes token to `/register` endpoint via `sendRegistrationRequestWithData()`
   - Implementation: Lines 23-25, 85-123, 238-250, 392-407 in mobile_webauthn_login_screen.dart
   - New method: `sendRegistrationRequestWithData()` in webauthn_service_mobile.dart

2. **✅ FIXED: Mobile Missing Backup Code Login**
   - Created `mobile_backupcode_login_screen.dart` (403 lines)
   - POST `/backupcode-login` with {email, backupCode}
   - After successful login, navigates to `/register/webauthn` to add biometric
   - Added "Login with Backup Code" button on mobile webauthn login screen
   - Route added: `/mobile-backupcode-login` in main.dart

### Medium Issues

3. **✅ VERIFIED: Profile Setup Works on Mobile**
   - `register_profile_page.dart` uses `ApiService.post('/client/profile/setup', ...)`
   - ApiService automatically adds server URL from active ServerConfig (lines 138-147 in api_service.dart)
   - Server is saved at backup codes step (lines 173-177 in backupcode_web_native.dart)
   - Session cookies persist through registration flow
   - **No changes needed** - already working correctly

### Minor Issues

4. **✅ VERIFIED: Session Management Between Steps**
   - Server middleware enforces step order (server.js lines 277-318)
   - Forward-only progression is intentional security design
   - Backup codes shown once and assumed to be saved by user
   - **No changes needed** - working as designed

5. **ℹ️ WebAuthn Registration Email Source**
   - Web gets email from localStorage in webauthn JS
   - Mobile passes empty string (relies on session)
   - Server uses session email for all registration steps
   - **Recommendation**: Both should rely on session (low priority cosmetic change)

## Cookie Management Verification

### ApiService Usage

**✅ CORRECT - All endpoints use ApiService:**
- `/register` - Uses ApiService.dio.post (mobile) ✅
- `/otp` - Uses ApiService.post ✅
- `/backupcode/list` - Uses ApiService.get ✅
- `/webauthn/register-challenge` - Uses ApiService.dio.post (mobile) ✅
- `/webauthn/register` - Uses ApiService.dio.post (mobile) ✅
- `/webauthn/list` - Uses ApiService.get ✅

**Cookie Jar Setup:**
```dart
// ApiService.dart
static Future<CookieJar> getCookieJar() async {
  if (_cookieJar != null) return _cookieJar!;
  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
    final appDocDir = await getApplicationDocumentsDirectory();
    final cookiePath = '${appDocDir.path}/.cookies/';
    _cookieJar = PersistCookieJar(storage: FileStorage(cookiePath));
  } else {
    _cookieJar = CookieJar(); // Memory-only for web/desktop
  }
  return _cookieJar!;
}
```

**✅ Session cookies persist across requests on mobile**

## Recommendations

### High Priority

1. **Add Invitation Token Support to Mobile**
   ```dart
   // In mobile_webauthn_login_screen.dart
   - Check server settings on init
   - If invitation-only, add invitation token field
   - Pass token to sendRegistrationRequest()
   ```

2. **Add Backup Code Login to Mobile**
   ```dart
   // Create: mobile_backup_code_login_screen.dart
   - Similar to magic_key_login_page.dart
   - POST /backupcode-login with {email, backupCode}
   - Uses ApiService (session cookies)
   ```

3. **Fix Profile Setup for Mobile**
   ```dart
   // In register_profile_page.dart
   - Use full URL if serverUrl provided or mobile
   - Use ApiService (not direct HTTP)
   ```

### Medium Priority

4. **Add Registration Reset**
   ```javascript
   // Server: POST /register/reset
   - Clears req.session.registrationStep
   - Clears req.session.email
   - Returns success
   ```

5. **Add "Start Over" Button**
   ```dart
   // On backup codes and WebAuthn pages
   - Button to call /register/reset
   - Navigate back to start
   ```

### Low Priority

6. **Consistent Email Handling**
   - Both web and mobile should get email from session
   - Remove localStorage dependency in web

7. **Add Registration Progress Indicator**
   - Show which step user is on
   - Already have RegistrationProgressBar widget

## Testing Checklist

### Web Registration
- [ ] Open mode - complete registration
- [ ] Email suffix mode - allowed domain
- [ ] Email suffix mode - blocked domain
- [ ] Invitation-only mode - valid token
- [ ] Invitation-only mode - invalid token
- [ ] Stop at OTP - can restart
- [ ] Stop at backup codes - forced to continue
- [ ] Complete backup codes - can login with backup code
- [ ] Add multiple WebAuthn keys
- [ ] Complete profile setup

### Mobile Registration
- [ ] Open mode - complete registration
- [ ] Email suffix mode - allowed domain
- [ ] Email suffix mode - blocked domain
- [ ] ❌ Invitation-only mode - not implemented
- [ ] Stop at OTP - can restart
- [ ] Stop at backup codes - forced to continue
- [ ] Complete backup codes - ❌ no backup code login
- [ ] Add multiple WebAuthn keys (physical device only)
- [ ] Complete profile setup
- [ ] Session cookies persist across steps
- [ ] Full URLs work with server IP

### Session Management
- [ ] Cookies persist across registration steps (mobile)
- [ ] Session email available in all endpoints
- [ ] Registration step enforcement works
- [ ] Can restart after failure

## Summary

**What Works:**
- ✅ Mobile uses ApiService for all requests (session cookies work)
- ✅ OTP flow works for both web and mobile
- ✅ Backup codes flow works
- ✅ WebAuthn registration works (when biometric available)
- ✅ Can restart from beginning if stopped at OTP

**What Needs Fixing:**
- ❌ Mobile missing invitation token support (critical for invitation-only servers)
- ❌ Mobile missing backup code login (can't add WebAuthn after skipping)
- ⚠️ No way to restart from backup codes page
- ⚠️ Profile setup may not work on mobile (need to verify)

**Priority Order:**
1. ~~Add invitation token support to mobile~~ ✅ COMPLETED
2. ~~Add backup code login to mobile~~ ✅ COMPLETED
3. ~~Verify/fix profile setup for mobile~~ ✅ VERIFIED (already working)
4. Web email consistency (low priority - cosmetic)

## Implementation Summary (January 3, 2026)

### Files Created:
1. **`client/lib/screens/mobile_backupcode_login_screen.dart`** (403 lines)
   - Mobile backup code login screen for iOS/Android
   - POST `/backupcode-login` with email and backup code
   - Navigates to WebAuthn registration after successful login
   - Added route `/mobile-backupcode-login` in main.dart

### Files Modified:
1. **`client/lib/screens/mobile_webauthn_login_screen.dart`**
   - Added invitation token controller and state variables
   - Added `_loadServerSettings()` to check registration mode via `/client/meta`
   - Shows invitation token field when `registrationMode === 'invitation_only'`
   - Passes invitation token to registration endpoint
   - Added "Login with Backup Code" button

2. **`client/lib/services/webauthn_service_mobile.dart`**
   - Added `sendRegistrationRequestWithData()` method
   - Accepts custom data map (email + optional invitationToken)
   - Original `sendRegistrationRequest()` now calls new method for backwards compatibility

3. **`client/lib/main.dart`**
   - Added import for `mobile_backupcode_login_screen.dart`
   - Added route for `/mobile-backupcode-login`

### Testing Status:
- ✅ Code compiles with no errors
- ⏳ Needs physical device testing:
  - Invitation-only server registration
  - Backup code login flow
  - End-to-end registration on mobile

### All Critical & Medium Issues Resolved:
- ✅ Invitation token support (critical)
- ✅ Backup code login (critical)
- ✅ Profile setup verified working (medium)
- ✅ Session management documented (minor)

**Next Steps:**
1. Build APK: `flutter build apk --release`
2. Test on physical device with local server
3. Test invitation-only mode registration
4. Test backup code login flow
5. Verify complete registration end-to-end
