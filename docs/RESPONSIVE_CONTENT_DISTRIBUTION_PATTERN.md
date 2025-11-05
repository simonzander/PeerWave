# Responsive Content Distribution Pattern

## Overview
PeerWave implements a **context-aware content distribution** pattern that intelligently shows or hides information based on available screen space and layout type.

## Core Principle
**Show high-frequency items in the Context Panel (desktop), integrate them into Main View (mobile/tablet)**

---

## Layout Breakdown

### 🖥️ Desktop (3-Column Layout)

```
┌──────┬──────────────┬────────────────────────┐
│ Icon │ Context      │ Main View              │
│ Bar  │ Panel        │                        │
│ 60px │ 280px        │ Flexible               │
├──────┼──────────────┼────────────────────────┤
│  ⚡   │ [Recent]     │ [Discovery/Details]    │
│  👥  │ [Quick]      │ [Browse/Content]       │
│  📁  │ [Access]     │ [Exploration]          │
│  #   │              │                        │
│  💬  │              │                        │
└──────┴──────────────┴────────────────────────┘
```

### 📱 Tablet/Mobile (No Context Panel)

```
┌─────────────────────────────────┐
│ Main View (Full Width)          │
│                                  │
│ [Recent + Discovery Combined]   │
│ [All Content Together]           │
│                                  │
└─────────────────────────────────┘
```

---

## Implementation Example: People View

### Desktop Strategy

#### **Context Panel** (280px)
**Purpose**: Quick access to frequent contacts

Content:
- 🔍 **Search bar** (compact)
- 📋 **Recent Conversations** (last 10-20 people)
- ⭐ **Favorite Contacts** (pinned)
- 🟢 **Online Status** indicators
- 💬 **Quick message** button

Visual Style:
- Compact list (32-36px avatars)
- Name + @username only
- Minimal metadata
- Single-click to message

#### **Main View** (Flexible width)
**Purpose**: Discovery and exploration

Content:
- 🔍 **Advanced Search** (full-featured)
- 🌍 **Discover People** (browse all users)
- 📊 **User Profiles** (detailed view when clicked)
- 🏷️ **Filters & Sorting** (by activity, name, etc.)
- 📄 **Pagination** (load more)

Visual Style:
- Grid or card layout
- Larger avatars (64-80px)
- Full metadata (bio, status, last seen)
- Detailed interaction options

### Tablet/Mobile Strategy

#### **Main View** (Full width, no context panel)
**Purpose**: Everything combined

Content (Sections in order):
1. 🔍 **Search bar** (prominent)
2. 📋 **Recent Conversations** (first section)
   - Last 5-10 people
   - "View All" button
3. ⭐ **Favorites** (if any)
4. 🌍 **Discover People** (scrollable below)

Visual Style:
- List layout (better for mobile)
- Medium avatars (48px)
- Name, @username, last message
- Swipe actions (message, favorite)

---

## Code Structure

### 1. **PeopleContextPanel** (Context Panel Component)
```dart
// lib/widgets/people_context_panel.dart
class PeopleContextPanel extends StatelessWidget {
  final List<Map<String, dynamic>> recentPeople;
  final List<Map<String, dynamic>> favoritePeople;
  // Compact, quick-access focused
}
```

### 2. **PeopleScreen** (Main View Component)
```dart
// lib/screens/people/people_screen.dart
class PeopleScreen extends StatelessWidget {
  final bool showRecent; // false on desktop, true on mobile/tablet
  
  Widget build(context) {
    if (showRecent) {
      return Column([
        _buildRecentSection(),  // Shown on mobile/tablet
        _buildDiscoverSection(),
      ]);
    } else {
      return _buildDiscoverSection(); // Desktop: only discovery
    }
  }
}
```

### 3. **Dashboard Integration**
```dart
// Desktop
Row([
  IconSidebar(),
  if (selectedIndex == 1) PeopleContextPanel(recent: ..., favorites: ...),
  PeopleScreen(showRecent: false), // Hide recent, it's in context panel
])

// Mobile/Tablet
PeopleScreen(showRecent: true) // Show everything
```

---

## Benefits

### ✅ **Better Space Utilization**
- Desktop: Use all 3 columns effectively
- Mobile: No wasted space, everything accessible

### ✅ **Faster Access** (Desktop)
- Recent people always visible in context panel
- No need to scroll through discovery to find recent contacts

### ✅ **Clean Hierarchy** (Mobile)
- Most important (recent) appears first
- Progressive disclosure - scroll for more

### ✅ **Single Source of Truth**
- Data loaded once in Dashboard state
- Passed down to both Context Panel and Main View
- No duplicate API calls

---

## Data Flow

```
DashboardPage (State)
  ├─ _recentPeople: List<User>
  ├─ _favoritePeople: List<User>
  │
  └─ Desktop: Row([
      IconSidebar,
      ContextPanel(
        type: people,
        recentPeople: _recentPeople,     ← Shared data
        favoritePeople: _favoritePeople,
      ),
      PeopleScreen(
        showRecentSection: false,        ← Hide recent
      ),
    ])
  
  └─ Mobile/Tablet:
      PeopleScreen(
        recentPeople: _recentPeople,     ← Pass data
        favoritePeople: _favoritePeople,
        showRecentSection: true,         ← Show recent
      )
```

---

## Extending to Other Views

### Channels View
- **Context Panel**: Favorite channels, recently visited
- **Main View**: All channels, public channel discovery

### Messages View
- **Context Panel**: Recent conversations (already implemented)
- **Main View**: Message details, conversation view

### Files View
- **Context Panel**: Recent files, starred files
- **Main View**: File browser, folder navigation

---

## Implementation Checklist

- [x] Create `PeopleContextPanel` widget
- [x] Update `ContextPanel` to support people type
- [ ] Update `PeopleScreen` to accept `showRecentSection` parameter
- [ ] Add `_recentPeople` and `_favoritePeople` state to Dashboard
- [ ] Load recent people data in Dashboard
- [ ] Pass data to ContextPanel and PeopleScreen
- [ ] Test on all layouts (Desktop, Tablet, Mobile)

---

## UX Guidelines

### When to use Context Panel
✅ **Use for:**
- Frequently accessed items
- Quick actions
- Recent activity
- Favorites/pins
- Quick filters

❌ **Don't use for:**
- Primary content browsing
- Detailed views
- Complex forms
- Search results (full list)

### When to combine into Main View (Mobile)
- When screen width < 840px (no context panel shown)
- Show recent items FIRST (top of list/scroll)
- Use clear section headers
- Allow collapsing sections if needed

---

## Performance Considerations

1. **Lazy Loading**: Context panel shows limited items (10-20 max)
2. **Shared State**: Load data once, use in multiple places
3. **Conditional Rendering**: Only render context panel when needed
4. **Virtualization**: Use ListView.builder for long lists

---

## Accessibility

- Context panel items have clear labels and tooltips
- Keyboard navigation works in all layouts
- Screen readers announce section changes
- Focus management when switching between views

---

## Future Enhancements

1. **Collapsible Context Panel** (Desktop)
   - Toggle button to hide/show
   - Persist preference in storage

2. **Drawer on Tablet** (Slide-in Context Panel)
   - Swipe from left to show context panel
   - Overlay on main content

3. **Smart Sections** (Context Panel)
   - Auto-collapse less used sections
   - Reorder based on usage

4. **Sync Across Devices**
   - Favorites and recents sync via backend
   - Consistent experience across devices
