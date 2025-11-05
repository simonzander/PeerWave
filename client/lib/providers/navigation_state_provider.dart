import 'package:flutter/foundation.dart';

/// Provider für Navigation-State (Selected Channel/User)
/// 
/// Tracked welcher Channel/User aktuell ausgewählt ist,
/// um AnimatedSelectionTile entsprechend zu highlighten.
class NavigationStateProvider with ChangeNotifier {
  // Selected Channel
  String? _selectedChannelUuid;
  String? _selectedChannelType; // 'signal' oder 'webrtc'
  
  // Selected Direct Message User
  String? _selectedDirectMessageUserId;
  
  // Current View
  NavigationView _currentView = NavigationView.activity;
  
  /// Get selected channel UUID
  String? get selectedChannelUuid => _selectedChannelUuid;
  
  /// Get selected channel type
  String? get selectedChannelType => _selectedChannelType;
  
  /// Get selected DM user ID
  String? get selectedDirectMessageUserId => _selectedDirectMessageUserId;
  
  /// Get current view
  NavigationView get currentView => _currentView;
  
  /// Select a channel
  void selectChannel(String uuid, String type) {
    _selectedChannelUuid = uuid;
    _selectedChannelType = type;
    _selectedDirectMessageUserId = null; // Deselect DM
    _currentView = NavigationView.channel;
    notifyListeners();
  }
  
  /// Select a direct message
  void selectDirectMessage(String userId) {
    _selectedDirectMessageUserId = userId;
    _selectedChannelUuid = null; // Deselect channel
    _selectedChannelType = null;
    _currentView = NavigationView.directMessage;
    notifyListeners();
  }
  
  /// Set current view (Activity, People, Files, etc.)
  void setView(NavigationView view) {
    _currentView = view;
    
    // Clear selections wenn zu anderen Views navigiert wird
    if (view != NavigationView.channel && view != NavigationView.directMessage) {
      _selectedChannelUuid = null;
      _selectedChannelType = null;
      _selectedDirectMessageUserId = null;
    }
    
    notifyListeners();
  }
  
  /// Clear all selections
  void clearSelection() {
    _selectedChannelUuid = null;
    _selectedChannelType = null;
    _selectedDirectMessageUserId = null;
    notifyListeners();
  }
  
  /// Check if a channel is selected
  bool isChannelSelected(String uuid) {
    return _selectedChannelUuid == uuid;
  }
  
  /// Check if a direct message is selected
  bool isDirectMessageSelected(String userId) {
    return _selectedDirectMessageUserId == userId;
  }
}

/// Navigation Views in der App
enum NavigationView {
  activity,
  people,
  files,
  channel,
  directMessage,
  settings,
}
