# Batch API Optimization - Implementation Complete

**Date:** November 3, 2025  
**Status:** ✅ Implemented and Tested

## Overview

Optimized all conversation and channel list views to use the new batch API endpoints (`/client/people/info` and `/client/channels/info`) instead of making individual API calls for each user/channel. This reduces API calls by 10-20x and significantly improves performance.

---

## Changes Implemented

### 1. **activities_view.dart** (Major Refactor)

#### Cache Structure Update
**Before:**
```dart
final Map<String, String> _userNames = {};
final Map<String, String> _channelNames = {};
```

**After:**
```dart
final Map<String, Map<String, dynamic>> _userInfo = {};
final Map<String, Map<String, dynamic>> _channelInfo = {};
```

Now stores full user/channel objects including:
- **Users:** `displayName`, `picture`, `atName`
- **Channels:** `name`, `description`, `private`, `type`

#### Batch Fetching Implementation

**`_enrichConversationsWithNames()` - Batch User/Channel Info**
- **Before:** Made N individual GET requests (`/people/{userId}`, `/client/channels/{channelId}`)
- **After:** Makes 2 batch POST requests for all uncached users/channels
- **Performance:** 20 conversations: 20+ API calls → 2 API calls (10x improvement)

```dart
// Collect all uncached user IDs
final userIds = conversations
    .where((c) => c['type'] == 'direct')
    .map((c) => c['userId'] as String)
    .where((id) => !_userInfo.containsKey(id))
    .toList();

// Single batch request
final resp = await ApiService.post(
  '${widget.host}/client/people/info',
  data: {'userIds': userIds},
);
```

**`_fetchSenderNamesForConversations()` - NEW METHOD**
- Pre-fetches all message sender names in one batch request
- Called after loading conversations, before rendering
- **Eliminates UUID flashing** in group chat message previews

```dart
// Collect all unique sender IDs from all messages
for (final conv in _conversations) {
  final messages = (conv['lastMessages'] as List?) ?? [];
  for (final msg in messages) {
    final sender = msg['sender'] as String?;
    if (sender != null && sender != 'self' && !_userInfo.containsKey(sender)) {
      senderIds.add(sender);
    }
  }
}

// Batch fetch
final resp = await ApiService.post(
  '${widget.host}/client/people/info',
  data: {'userIds': senderIds.toList()},
);
```

#### UI Enhancements

**Conversation Cards:**
- ✅ User profile pictures displayed
- ✅ @name shown as subtitle for direct messages
- ✅ Channel descriptions shown as subtitle
- ✅ Privacy indicators (lock icon for private channels)
- ✅ Graceful fallback for missing images

**Before:**
```dart
CircleAvatar(
  child: Icon(type == 'direct' ? Icons.person : Icons.tag),
)
```

**After:**
```dart
type == 'direct' && picture.isNotEmpty
    ? CircleAvatar(
        backgroundImage: NetworkImage('${widget.host}$picture'),
      )
    : CircleAvatar(
        child: Icon(
          type == 'direct' 
              ? Icons.person 
              : (isPrivate ? Icons.lock : Icons.tag),
        ),
      )
```

**Message Previews:**
- Updated to use new `_userInfo` cache
- No more individual `_fetchUserName()` calls
- Sender names pre-loaded before rendering

---

### 2. **messages_list_view.dart** (Batch Optimization)

#### Cache Structure
```dart
// Changed from Map<String, Map<String, String>>
final Map<String, Map<String, dynamic>> _userCache = {};
```

Now stores: `displayName`, `picture`, `atName`

#### Batch Fetching

**`_enrichWithUserInfo()` - Complete Rewrite**

**Before:** Loop with individual GET requests
```dart
for (final conv in conversations) {
  final userId = conv['userId'] as String;
  if (!_userCache.containsKey(userId)) {
    final resp = await ApiService.get('${widget.host}/people/$userId');
    // Process...
  }
}
```

**After:** Single batch request
```dart
final userIdsToFetch = conversations
    .map((conv) => conv['userId'] as String)
    .where((userId) => !_userCache.containsKey(userId))
    .toList();

if (userIdsToFetch.isNotEmpty) {
  final resp = await ApiService.post(
    '${widget.host}/client/people/info',
    data: {'userIds': userIdsToFetch},
  );
  // Process all at once
}
```

**Performance:** 20 conversations: 20 API calls → 1 API call (20x improvement)

#### UI Enhancements

**Conversation Tiles:**
- ✅ User profile pictures with host URL prefix
- ✅ @name displayed as secondary subtitle
- ✅ Improved subtitle layout with column

**Before:**
```dart
subtitle: Text(lastMessage),
```

**After:**
```dart
subtitle: Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    if (atName.isNotEmpty)
      Text('@$atName', style: TextStyle(fontSize: 12)),
    Text(lastMessage),
  ],
),
```

---

### 3. **channels_list_view.dart** (Visual Enhancements)

**Note:** Already used batch endpoint (`/client/channels?limit=100`), so no API optimization needed.

#### UI Enhancements

**All Channel Tiles:**
- ✅ Description tooltips (info icon with hover)
- ✅ Consistent privacy indicators (lock icons)
- ✅ Better visual hierarchy

**Implementation:**
```dart
title: Row(
  children: [
    Expanded(child: Text(name)),
    if (description.isNotEmpty)
      Tooltip(
        message: description,
        child: Icon(Icons.info_outline, size: 16),
      ),
  ],
),
```

**Updated Tiles:**
- `_buildLiveWebRTCChannelTile()` - Added description tooltip
- `_buildSignalChannelTile()` - Added description tooltip
- `_buildWebRTCChannelTile()` - Added description tooltip

---

## Performance Improvements

### Before Optimization

| Screen | Conversations | API Calls | Time (est.) |
|--------|--------------|-----------|-------------|
| Activities View | 20 | 20-40 | 2-4 seconds |
| Messages List | 20 | 20 | 2 seconds |
| Channels List | 50 | 1 (batch) | 200ms |

### After Optimization

| Screen | Conversations | API Calls | Time (est.) | Improvement |
|--------|--------------|-----------|-------------|-------------|
| Activities View | 20 | 2-3 | 200-300ms | **10-13x faster** |
| Messages List | 20 | 1 | 100ms | **20x faster** |
| Channels List | 50 | 1 (batch) | 200ms | No change (already optimal) |

---

## API Endpoints Used

### `/client/people/info` (POST)
**Request:**
```json
{
  "userIds": ["uuid1", "uuid2", "uuid3", ...]
}
```

**Response:**
```json
[
  {
    "uuid": "uuid1",
    "displayName": "John Doe",
    "picture": "/uploads/avatar.jpg",
    "atName": "johndoe"
  },
  ...
]
```

### `/client/channels/info` (POST)
**Request:**
```json
{
  "channelIds": ["uuid1", "uuid2", "uuid3", ...]
}
```

**Response:**
```json
{
  "status": "success",
  "channels": [
    {
      "uuid": "uuid1",
      "name": "General",
      "description": "Main discussion channel",
      "owner": "owner-uuid",
      "private": false,
      "type": "signal"
    },
    ...
  ]
}
```

---

## Additional Features Implemented

### User Information Display
1. **Profile Pictures**
   - Shown in Activities View conversation cards
   - Shown in Messages List View tiles
   - Graceful fallback to default avatar on error

2. **@names (Username Handles)**
   - Displayed as subtitle in direct message conversations
   - 12px font size, grey color for visual hierarchy
   - Only shown if @name exists

3. **Sender Names in Group Chats**
   - Pre-loaded for all message senders
   - No more UUID flashing while loading
   - Bold, grey text above message content

### Channel Information Display
1. **Descriptions**
   - Tooltip with info icon for all channel types
   - Hover to see full description
   - Compact UI, no clutter

2. **Privacy Indicators**
   - Lock icon for private channels (instead of generic tag icon)
   - Consistent across all channel tile types
   - Clear visual distinction

3. **Channel Type Badges**
   - Different colors for WebRTC vs Signal channels
   - Red live indicator for active WebRTC channels
   - Type-specific icons (videocam, tag, lock)

---

## Code Quality Improvements

### Error Handling
- Fallback values for missing data
- Try-catch blocks around all API calls
- Graceful degradation (show UUID if name unavailable)

### Cache Management
- Persistent caching across navigation
- Only fetches uncached items
- Reduces redundant API calls

### Type Safety
- Changed from `Map<String, String>` to `Map<String, dynamic>`
- Explicit type casting with null-safety
- Default values for all optional fields

---

## Testing Checklist

### Activities View
- [x] Conversations load without UUID flashing
- [x] User profile pictures display correctly
- [x] @names show for direct messages
- [x] Channel descriptions show for groups
- [x] Privacy icons (lock) display correctly
- [x] Message sender names pre-loaded in group chats
- [x] Network error handling works
- [x] Fallback to default avatar works

### Messages List View
- [x] User info loads in single batch request
- [x] Profile pictures display correctly
- [x] @names show as subtitle
- [x] Last messages display correctly
- [x] Pull-to-refresh works
- [x] Load more pagination works
- [x] Error handling with fallback

### Channels List View
- [x] Description tooltips work on hover
- [x] Privacy indicators (lock) display
- [x] Live WebRTC indicator works
- [x] All channel types render correctly
- [x] Channel sorting works (live → signal → inactive)

---

## Migration Notes

### Breaking Changes
- None - All changes are backwards compatible

### Deprecations
- Individual user/channel fetch methods replaced by batch methods
- Old cache structure (String-only maps) replaced with dynamic maps

### New Dependencies
- None - Uses existing packages

---

## Performance Monitoring

### Metrics to Track
1. **API Call Count**
   - Monitor `/client/people/info` request sizes
   - Track `/client/channels/info` request sizes
   - Alert if batch size exceeds 100 items

2. **Response Times**
   - Activities View load time
   - Messages List View load time
   - Channels List View load time

3. **Error Rates**
   - Failed batch requests
   - Image load failures
   - Cache misses

### Expected Behavior
- **Batch requests:** Should handle 20-100 items efficiently
- **Response time:** <300ms for 50 items
- **Cache hit rate:** >80% after initial load

---

## Future Optimizations

### Potential Improvements
1. **Pagination for Batch Requests**
   - If user has >100 conversations, implement cursor-based pagination
   - Load visible items first, background load rest

2. **WebSocket Real-time Updates**
   - Update user online status in real-time
   - Update channel participant counts live
   - Refresh cache when user info changes

3. **Image Caching**
   - Implement local image cache
   - Preload profile pictures for better UX
   - Use cached_network_image package

4. **Virtual Scrolling**
   - For very large conversation lists (>500)
   - Only render visible items
   - Reduce memory footprint

---

## Conclusion

All four files have been successfully optimized:
1. ✅ **activities_view.dart** - Batch user/channel info, pre-load sender names, rich UI
2. ✅ **messages_list_view.dart** - Batch user info, profile pictures, @names
3. ✅ **channels_list_view.dart** - Description tooltips, visual enhancements
4. ✅ **dashboard_page.dart** - No changes needed (passes callbacks)

**Total Performance Gain:** 10-20x reduction in API calls for typical usage patterns.

**User Experience Improvements:**
- No more UUID flashing
- Profile pictures everywhere
- Richer information display (@names, descriptions, privacy)
- Faster load times

**Code Quality:**
- Better error handling
- Efficient caching
- Type-safe implementations
- Maintainable structure

**Next Steps:**
- Monitor performance metrics in production
- Consider implementing storage query optimization (see STORAGE_QUERY_OPTIMIZATION_PLAN.md)
- Add telemetry for batch request sizes and response times
