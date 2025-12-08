# Hardcoded Colors Audit - PeerWave Client

**Date:** December 8, 2025  
**Purpose:** Document all locations where static colors are used instead of theme-aware colors

## Overview

This document lists all files where hardcoded colors (`Colors.*`, `Color(0x...)`, `Color.fromRGBO(...)`) are used instead of accessing colors from the theme system.

## Theme System Reference

**Available Theme Colors:**
- `theme.colorScheme.primary` - Primary brand color
- `theme.colorScheme.secondary` - Secondary accent color
- `theme.colorScheme.surface` - Surface backgrounds
- `theme.colorScheme.background` - App background
- `theme.colorScheme.error` - Error states
- `theme.colorScheme.onPrimary` - Text on primary color
- `theme.colorScheme.onSurface` - Text on surfaces
- `theme.colorScheme.onBackground` - Text on background
- `AppThemeConstants.sidebarBackground`
- `AppThemeConstants.contextPanelBackground`
- `AppThemeConstants.mainViewBackground`
- `AppThemeConstants.inputBackground`
- `AppThemeConstants.textPrimary`
- `AppThemeConstants.textSecondary`

---

## 1. App Core Files

### `lib/app/server_panel.dart`
**Issues:** 9 hardcoded colors
- **Line 229:** `Color(0xFF202225)` - Background color
- **Line 239:** `Colors.white` - Icon color
- **Line 360:** `Colors.red[200]`, `Colors.blue[400]` - Server error/status badges
- **Line 361:** `Colors.white` - Icon color
- **Line 373:** `Colors.yellow[700]` - Warning badge
- **Line 374:** `Colors.black` - Warning icon
- **Line 379:** `Colors.orange` - Badge background
- **Line 382:** `Colors.white` - Text color

**Recommendation:** Use `theme.colorScheme.error`, `theme.colorScheme.primary`, `theme.colorScheme.onPrimary`

### `lib/app/dashboard_page.dart`
**Issues:** 4 hardcoded colors
- **Line 1023:** `Colors.grey[600]` - Empty state icon
- **Line 1028:** `Colors.grey[400]` - Empty state text
- **Line 1037:** `Colors.grey[600]` - Subtitle text
- **Line 1069:** `Colors.transparent` - Background

**Recommendation:** Use `theme.colorScheme.onSurface.withOpacity(...)` for grey variants

### `lib/app/webauthn_web.dart`
**Issues:** 4 hardcoded colors
- **Line 114:** `Colors.red` - Error SnackBar
- **Line 120:** `Colors.green` - Success SnackBar
- **Line 512:** `Colors.white` - Text color
- **Line 522:** `Colors.white` - Background

**Recommendation:** Use `theme.colorScheme.error` and `theme.colorScheme.primary` for SnackBars

### `lib/app/sidebar_panel.dart`
**Issues:** 29 hardcoded colors
- **Line 86:** `Colors.grey[900]` - Container background
- **Line 99-119:** Multiple `Colors.white` - Icons and text
- **Line 218:** `Colors.transparent`, `Colors.grey[600]` - Conditional colors
- **Line 244-790:** Extensive use of `Colors.white`, `Colors.white70`, `Colors.white54` for text and icons

**Recommendation:** Use `theme.colorScheme.onSurface` and opacity variants for text hierarchy

### `lib/app/settings/notification_settings_page.dart`
**Issues:** 11 hardcoded colors
- **Line 121:** `Colors.green`, `Colors.red` - Permission status
- **Line 426:** `Colors.orange` - Warning
- **Line 443-458:** `Colors.green`, `Colors.orange` - Status indicators
- **Line 499-523:** `Colors.blue.shade*` - Info box styling

**Recommendation:** Use semantic colors from theme (error, success, warning)

### `lib/app/settings/general_settings_page.dart`
**Issues:** 2 hardcoded colors
- **Line 71:** `Colors.green` - Success SnackBar
- **Line 80:** `Colors.red` - Error SnackBar

**Recommendation:** Use `theme.colorScheme` for feedback colors

### `lib/app/profile_page.dart`
**Note:** Currently this file appears to properly use theme colors (no hardcoded colors found)

---

## 2. Widget Files

### `lib/widgets/message_list.dart`
**Issues:** 50+ hardcoded colors (CRITICAL - Most used component)
- **Lines 140-209:** Message status icons - `Colors.green`, `Colors.grey`, `Colors.red`
- **Lines 222-226:** Empty state - `Colors.grey[600]`
- **Lines 278-290:** Date dividers - `Colors.grey[700]`, `Colors.grey[500]`
- **Lines 337-344:** Message bubbles - `Colors.white`, `Colors.white54`
- **Lines 487-515:** Reply indicators - `Colors.amber.shade*` (multiple shades)
- **Lines 546-572:** Image preview - `Colors.black87`, `Colors.grey[700]`, `Colors.grey[600]`, `Colors.grey[500]`
- **Lines 594-652:** Error messages - `Colors.red[300]`
- **Lines 676-710:** Markdown styling - `Colors.white`, `Colors.grey[800]`, `Colors.amber[300]`, `Colors.grey[850]`, `Colors.grey[700]`, `Colors.grey[400]`, `Colors.grey[600]`, `Colors.blue`
- **Lines 737-803:** Image viewer overlay - `Colors.transparent`, `Colors.black.withOpacity(0.5)`, `Colors.black.withOpacity(0.7)`, `Colors.white`, `Colors.grey[300]`

**Recommendation:** HIGH PRIORITY - Refactor entire file to use theme colors

### `lib/widgets/message_input.dart`
**Issues:** 30+ hardcoded colors
- **Lines 116-215:** Input container backgrounds - `Colors.grey[850]`, `Colors.grey[900]`
- **Lines 163-205:** Icon buttons - `Colors.white70` (repeated)
- **Lines 222-255:** Attachment menu - `Colors.grey[800]`, `Colors.white`, `Colors.white70`
- **Lines 271-280:** Text input - `Colors.white54`, `Colors.grey[800]`, `Colors.white`
- **Lines 289-332:** Action buttons - `Colors.white70`, `Colors.amber`
- **Lines 389-493:** Mention picker - `Colors.grey[700]`, `Colors.grey[800]`, `Colors.grey[500]`, `Colors.grey[900]`, `Colors.white`, `Colors.white70`, `Colors.amber`, `Colors.transparent`, `Colors.black`

**Recommendation:** HIGH PRIORITY - Create themed input component

### `lib/widgets/user_avatar.dart`
**Issues:** 20+ hardcoded colors
- **Lines 112-134:** Avatar background - `Colors.transparent`, `Colors.white`, `Colors.green`, `Colors.grey`
- **Lines 170-179:** Color palette for avatar backgrounds (8 colors):
  - `Color(0xFF7C4DFF)` - Deep Purple
  - `Color(0xFF5C6BC0)` - Indigo
  - `Color(0xFF42A5F5)` - Blue
  - `Color(0xFF26A69A)` - Teal
  - `Color(0xFF66BB6A)` - Green
  - `Color(0xFFFF7043)` - Deep Orange
  - `Color(0xFFEC407A)` - Pink
  - `Color(0xFFAB47BC)` - Purple
- **Lines 344-375:** Duplicate avatar colors
- **Lines 401-410:** Another color palette (duplicate)

**Recommendation:** MEDIUM PRIORITY - Could keep color palette but add theme variant, fix status indicators

### `lib/widgets/voice_message_player.dart`
**Issues:** 11 hardcoded colors
- **Line 281:** `Colors.grey[850]` - Background
- **Line 284:** `Colors.grey[700]` - Border
- **Lines 306-311:** `Colors.white` - Icons
- **Lines 332-395:** `Colors.grey[300]`, `Colors.grey[500]`, `Colors.grey[600]` - Waveform colors

**Recommendation:** MEDIUM PRIORITY - Use theme colors for backgrounds and theme primary for active states

### `lib/widgets/custom_window_title_bar.dart`
**Issues:** 4 hardcoded colors
- **Line 114:** `Color(0xFFD32F2F)` - Close button hover (red)
- **Line 115:** `Color(0xFFB71C1C)` - Close button pressed (dark red)
- **Lines 117-118:** `Colors.white` - Icon colors

**Recommendation:** LOW PRIORITY - System colors are appropriate but could be themeable

### `lib/widgets/navigation_sidebar.dart`
**Issues:** 1 hardcoded color
- **Line 200:** `Colors.transparent` - Background

**Recommendation:** LOW PRIORITY - Transparent is acceptable

### `lib/widgets/navigation_badge.dart`
**Issues:** 8 hardcoded colors
- **Lines 55-59:** `Colors.white`, `Colors.black.withOpacity(0.2)` - Badge text and shadow
- **Lines 93-138:** `Colors.red`, `Colors.white` - Notification badges

**Recommendation:** MEDIUM PRIORITY - Use theme error color for badges

### `lib/widgets/notification_badge.dart`
**Issues:** 4 hardcoded colors
- **Lines 41-107:** `Colors.red`, `Colors.white` - Notification indicators

**Recommendation:** MEDIUM PRIORITY - Use theme error color

### `lib/widgets/people_context_panel.dart`
**Issues:** 6 hardcoded colors
- **Lines 205-214:** `Colors.transparent`, `Color(0xFF1A1E24)`, `Color(0xFF252A32)`, `Color(0xFF1F242B)` - Hover states
- **Line 240:** `Colors.green` - Online status
- **Line 299:** `Colors.amber` - Status indicator

**Recommendation:** MEDIUM PRIORITY - Use theme colors for hover, keep semantic status colors or make themeable

### `lib/widgets/participant_profile_display.dart`
**Issues:** 10 hardcoded colors
- **Lines 48-68:** `Colors.teal` - Background
- **Line 79:** `Colors.grey[900]` - Container
- **Lines 94-95:** `Colors.teal.withOpacity(...)` - Gradient
- **Lines 126-175:** `Colors.black.withOpacity(0.3)`, `Colors.grey[800]`, `Colors.white` - Overlays and text

**Recommendation:** MEDIUM PRIORITY - Use theme colors

### `lib/widgets/registration_progress_bar.dart`
**Issues:** 12 hardcoded colors
- **Line 18:** `Color(0xFF23272A)` - Background
- **Line 21:** `Color(0xFF40444B)` - Track color
- **Lines 53-106:** `Colors.blueAccent`, `Color(0xFF40444B)`, `Colors.white`, `Colors.white54` - Progress indicators

**Recommendation:** MEDIUM PRIORITY - Use theme primary color

### `lib/widgets/sync_progress_banner.dart`
**Issues:** 2 hardcoded colors
- **Line 147:** `Colors.black.withOpacity(0.1)` - Shadow
- **Line 257:** `Colors.transparent` - Background

**Recommendation:** LOW PRIORITY - Acceptable

### `lib/widgets/theme_selector_dialog.dart`
**Issues:** 4 hardcoded colors
- **Line 212:** `Colors.transparent` - Background
- **Line 227:** `Colors.black.withOpacity(0.1)` - Shadow
- **Lines 333:** `Colors.black87`, `Colors.white` - Contrast calculation

**Recommendation:** LOW PRIORITY - Functional colors for theme preview

### `lib/widgets/user_profile_card_overlay.dart`
**Issues:** 3 hardcoded colors
- **Lines 137-147:** `Colors.green`, `Colors.grey` - Online status indicators

**Recommendation:** LOW PRIORITY - Semantic status colors are acceptable

### `lib/widgets/partial_download_dialog.dart`
**Issues:** 3 hardcoded colors
- **Lines 33-41:** `Colors.orange`, `Colors.deepOrange`, `Colors.red` - Warning levels

**Recommendation:** LOW PRIORITY - Semantic warning colors

### `lib/widgets/file_message_widget.dart`
**Issues:** 5 hardcoded colors
- **Lines 199-215:** `Colors.green`, `Colors.lightGreen`, `Colors.orange`, `Colors.deepOrange`, `Colors.red` - File size badges

**Recommendation:** LOW PRIORITY - Semantic indicators

### `lib/widgets/file_size_error_dialog.dart`
**Issues:** 2 hardcoded colors
- **Line 26:** `Colors.orange`, `Colors.red` - Error levels

**Recommendation:** LOW PRIORITY - Semantic colors

### `lib/widgets/mention_text_widget.dart`
**Issues:** 1 hardcoded color
- **Line 131:** `Colors.white` - Default text color

**Recommendation:** MEDIUM PRIORITY - Use theme text color

### `lib/widgets/socket_aware_widget.dart`
**Issues:** 2 hardcoded colors
- **Lines 74-89:** `Colors.grey`, `Colors.grey[600]` - Loading state

**Recommendation:** MEDIUM PRIORITY - Use theme colors

### `lib/widgets/animated_widgets.dart`
**Issues:** 6 hardcoded colors
- **Lines 55-339:** `Colors.transparent`, `Colors.white`, `Colors.red` - Various states

**Recommendation:** MEDIUM PRIORITY - Use theme colors for consistency

### `lib/widgets/e2ee_debug_overlay.dart`
**Issues:** 15 hardcoded colors
- **Lines 33-138:** Debug overlay colors - `Colors.black87`, `Colors.green`, `Colors.red`, `Colors.white`, `Colors.grey`, `Colors.white70`

**Recommendation:** LOW PRIORITY - Debug interface, but should still be themeable

---

## 3. Screen Files

### `lib/screens/dashboard/channels_list_view.dart`
**Issues:** 26 hardcoded colors
- **Lines 493-1248:** Extensive hardcoded colors throughout
  - `Colors.red` - Delete/error actions
  - `Colors.amber` - Star indicators
  - `Colors.grey[*]` - Text and icons (multiple shades)
  - `Colors.green` - Success states
  - `Colors.white` - Text

**Recommendation:** HIGH PRIORITY - Major user-facing component

### `lib/screens/channel/channel_settings_screen.dart`
**Issues:** 15 hardcoded colors
- **Lines 171-482:** Form and danger zone styling
  - `Colors.grey[600]` - Secondary text
  - `Colors.red` - Danger zone (multiple shades)
  - `Colors.green` - Success SnackBar
  - `Colors.white` - Button text

**Recommendation:** HIGH PRIORITY - Settings should use theme

### `lib/screens/channel/channel_members_screen.dart`
**Issues:** 17 hardcoded colors
- **Lines 105-619:** Member list and role management
  - `Colors.grey[600]` - Subtitles
  - `Colors.orange` - Action buttons
  - `Colors.red` - Delete actions
  - `Colors.green` - Success states
  - `Colors.purple`, `Colors.blue`, `Colors.grey` - Role indicators
  - `Colors.white` - Text
  - `Colors.grey[300]` - Disabled states

**Recommendation:** HIGH PRIORITY - Core channel management

### `lib/screens/messages/signal_group_chat_screen.dart`
**Issues:** 20+ hardcoded colors
- **Lines 274-1631:** Message screen with numerous hardcoded colors
  - `Colors.orange` - Warnings (many instances)
  - `Colors.red` - Errors
  - `Colors.blue` - Info
  - `Colors.green` - Success
  - `Colors.white` - Text

**Recommendation:** CRITICAL PRIORITY - Most used screen

---

## 4. Views

### `lib/views/video_conference_view.dart`
**Issues:** 11 hardcoded colors
- **Lines 670-1257:** Video controls and UI
  - `Colors.black` - Overlays
  - `Colors.white` - Icons
  - `Colors.transparent` - Backgrounds
  - `Colors.red` - End call
  - `Colors.green` - Active states

**Recommendation:** HIGH PRIORITY - Important feature

---

## 5. Auth & Registration

### `lib/auth/magic_link_native.dart`
**Issues:** 9 hardcoded colors
- **Lines 176-222:** Login UI
  - `Color(0xFF2C2F33)` - Background
  - `Color(0xFF23272A)` - Container
  - `Color(0xFF40444B)` - Input background
  - `Colors.white` - Text
  - `Colors.blueAccent` - Button
  - `Colors.green` - Success

**Recommendation:** MEDIUM PRIORITY - Auth flows should be branded

### `lib/auth/auth_layout_native.dart`
**Issues:** 14 hardcoded colors
- **Lines 96-212:** Auth layout with Discord-style colors
  - `Color(0xFF2C2F33)`, `Color(0xFF23272A)`, `Color(0xFF40444B)` - Layout colors
  - `Colors.white` - Text
  - `Colors.blueAccent`, `Colors.greenAccent` - Actions
  - `Colors.red` - Errors

**Recommendation:** MEDIUM PRIORITY - Should use brand colors

### `lib/auth/auth_layout.dart`
**Issues:** 13 hardcoded colors
- **Lines 88-206:** Similar to native layout
- Same color scheme as native version

**Recommendation:** MEDIUM PRIORITY - Consolidate with native version

### `lib/auth/register_profile_page.dart`
**Issues:** 1 hardcoded color
- **Line 133:** `Colors.green` - Success

**Recommendation:** LOW PRIORITY

### `lib/auth/register_webauthn_page_native.dart`
**Issues:** 3 hardcoded colors
- **Lines 33-50:** `Colors.grey` - Placeholder text

**Recommendation:** LOW PRIORITY

### `lib/auth/backup_recover_web_native.dart`
**Issues:** 3 hardcoded colors
- **Lines 23-48:** `Colors.grey` - Loading/disabled states

**Recommendation:** LOW PRIORITY

### `lib/auth/auth_layout_web.dart`
**Issues:** 1 hardcoded color
- **Line 447:** `Colors.transparent`

**Recommendation:** LOW PRIORITY

---

## 6. Backupcode Pages

### `lib/app/backupcode_web_native.dart`
**Issues:** 3 hardcoded colors
- **Lines 23-39:** `Colors.grey` - Disabled states

**Recommendation:** LOW PRIORITY

### `lib/app/backupcode_settings_page_native.dart`
**Issues:** 3 hardcoded colors
- **Lines 23-48:** `Colors.grey` - Disabled states

**Recommendation:** LOW PRIORITY

---

## 7. Server Panel (Widget duplicate)

### `lib/widgets/server_panel.dart`
**Issues:** 2 hardcoded colors
- **Line 285:** `Colors.green` - Status
- **Line 419:** `Colors.transparent` - Background

**Recommendation:** LOW PRIORITY

---

## Priority Summary

### CRITICAL (Immediate Action Required)
1. **`lib/screens/messages/signal_group_chat_screen.dart`** - Most used screen, 20+ colors
2. **`lib/widgets/message_list.dart`** - Core messaging component, 50+ colors

### HIGH PRIORITY
3. **`lib/widgets/message_input.dart`** - Message composition, 30+ colors
4. **`lib/screens/dashboard/channels_list_view.dart`** - Channel navigation, 26 colors
5. **`lib/screens/channel/channel_settings_screen.dart`** - Settings UI, 15 colors
6. **`lib/screens/channel/channel_members_screen.dart`** - Member management, 17 colors
7. **`lib/views/video_conference_view.dart`** - Video features, 11 colors

### MEDIUM PRIORITY
8. **`lib/widgets/user_avatar.dart`** - Could keep color palette but fix status indicators
9. **`lib/widgets/voice_message_player.dart`** - Voice message UI
10. **`lib/widgets/navigation_badge.dart`** - Notification badges
11. **`lib/widgets/notification_badge.dart`** - Badge components
12. **`lib/widgets/people_context_panel.dart`** - People list
13. **`lib/widgets/participant_profile_display.dart`** - Profile displays
14. **`lib/widgets/registration_progress_bar.dart`** - Registration flow
15. **`lib/widgets/mention_text_widget.dart`** - Text mentions
16. **`lib/widgets/socket_aware_widget.dart`** - Connection states
17. **`lib/widgets/animated_widgets.dart`** - Animation components
18. **`lib/app/sidebar_panel.dart`** - Sidebar navigation, 29 colors
19. **`lib/app/settings/notification_settings_page.dart`** - Settings
20. **`lib/auth/magic_link_native.dart`** - Auth flow
21. **`lib/auth/auth_layout_native.dart`** - Auth layout
22. **`lib/auth/auth_layout.dart`** - Auth layout (web)

### LOW PRIORITY (Acceptable but could improve)
23. Debug overlays
24. Status indicators (green/red for online/offline)
25. Semantic warning colors (orange/red for errors)
26. System UI components (window controls)
27. Transparent backgrounds
28. Backup/recovery pages

---

## Migration Strategy

### Phase 1: Core Messaging (Week 1)
- [ ] `signal_group_chat_screen.dart`
- [ ] `message_list.dart`
- [ ] `message_input.dart`

### Phase 2: Navigation & Channels (Week 2)
- [ ] `channels_list_view.dart`
- [ ] `channel_settings_screen.dart`
- [ ] `channel_members_screen.dart`
- [ ] `sidebar_panel.dart`

### Phase 3: Widgets & Components (Week 3)
- [ ] `user_avatar.dart` (partial - keep color palette)
- [ ] `voice_message_player.dart`
- [ ] Notification badges
- [ ] People panels
- [ ] Progress bars

### Phase 4: Video & Media (Week 4)
- [ ] `video_conference_view.dart`
- [ ] Media widgets

### Phase 5: Auth & Settings (Week 5)
- [ ] Auth layouts
- [ ] Settings pages
- [ ] Profile pages

### Phase 6: Polish & Review (Week 6)
- [ ] Animated widgets
- [ ] Debug overlays
- [ ] Edge cases
- [ ] Testing & verification

---

## Implementation Guidelines

### DO:
✅ Use `theme.colorScheme.primary` for brand colors  
✅ Use `theme.colorScheme.error` for errors  
✅ Use `theme.colorScheme.onSurface.withOpacity(0.6)` for secondary text  
✅ Use `theme.colorScheme.surface` for backgrounds  
✅ Keep semantic status colors (green=online, red=offline) but make them theme variants  
✅ Use `AppThemeConstants.*` for layout-specific backgrounds  

### DON'T:
❌ Use `Colors.red`, `Colors.green`, `Colors.blue` directly  
❌ Use `Colors.grey[*]` for text - use opacity on theme colors instead  
❌ Hardcode hex colors like `Color(0xFF...)` for UI elements  
❌ Use `Colors.white` or `Colors.black` - use `onSurface` or `onPrimary`  

### Example Migration:

**Before:**
```dart
Container(
  color: Colors.grey[850],
  child: Text(
    'Message',
    style: TextStyle(color: Colors.white),
  ),
)
```

**After:**
```dart
Container(
  color: theme.colorScheme.surface,
  child: Text(
    'Message',
    style: TextStyle(color: theme.colorScheme.onSurface),
  ),
)
```

**For secondary text:**
```dart
// Before
TextStyle(color: Colors.grey[600])

// After
TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6))
```

**For status indicators:**
```dart
// Before
color: isOnline ? Colors.green : Colors.grey

// After (if keeping semantic colors)
color: isOnline 
  ? theme.brightness == Brightness.dark 
    ? Colors.green.shade400 
    : Colors.green.shade600
  : theme.colorScheme.onSurface.withOpacity(0.3)

// Or use theme extension
color: isOnline ? theme.extension<StatusColors>()!.online : theme.extension<StatusColors>()!.offline
```

---

## Total Count

- **Files with hardcoded colors:** ~45 files
- **Total hardcoded color instances:** ~400+
- **Critical files:** 2
- **High priority files:** 5
- **Medium priority files:** 15
- **Low priority files:** 23

---

## Notes

1. Some semantic colors (green for success, red for error) are acceptable but should still reference theme variants
2. Avatar color palettes can remain but should be adjusted per theme brightness
3. Status indicators (online/offline) use green/grey which is standard but could be themeable
4. Debug overlays are low priority but should still be updated for consistency
5. Consider creating a `StatusColors` theme extension for online/offline/away states

---

## Testing Checklist

After migration, test each file with:
- [ ] PeerWave Dark theme
- [ ] Monochrome Dark theme
- [ ] Sunset Orange theme
- [ ] Lavender Purple theme
- [ ] Forest Green theme
- [ ] Cherry Red theme
- [ ] Light mode variants (when applicable)

Verify:
- [ ] Text is readable on all backgrounds
- [ ] Interactive elements have proper contrast
- [ ] Hover states are visible
- [ ] Focus indicators work
- [ ] Error states are clear
- [ ] Success states are distinct
- [ ] Disabled states are obvious

---

**End of Audit**
