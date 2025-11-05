import 'package:flutter/material.dart';
import 'dart:async';
import '../../services/api_service.dart';
import '../../services/activities_service.dart';
import '../../services/user_profile_service.dart';
import '../../services/recent_conversations_service.dart';
import '../../widgets/user_avatar.dart';

/// Modern People Screen with Grid Layout
/// 
/// Features:
/// - Search bar with dynamic filtering (displayName, atName)
/// - Shows 10 users from recent 1:1 conversations
/// - Shows 10 random users without conversations
/// - Grid card layout with profile picture, name, online status, atName
/// - Load More button for 20 additional random users
/// - Responsive: showRecentSection controls visibility of "Recent Conversations"
class PeopleScreen extends StatefulWidget {
  final String host;
  final Function(String uuid, String displayName) onMessageTap;
  final bool showRecentSection;

  const PeopleScreen({
    Key? key,
    required this.host,
    required this.onMessageTap,
    this.showRecentSection = true,
  }) : super(key: key);

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;
  
  List<Map<String, dynamic>> _recentConversationUsers = [];
  List<Map<String, dynamic>> _randomUsers = [];
  List<Map<String, dynamic>> _searchResults = [];
  
  bool _isLoadingRecent = false;
  bool _isLoadingRandom = false;
  bool _isSearching = false;
  
  String _searchQuery = '';
  int _randomUsersOffset = 0;
  bool _hasMoreRandomUsers = true;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  /// Safe picture extraction from API response
  /// Handles String, Map, JSArray, and null values
  String _extractPictureData(dynamic picture) {
    if (picture == null) return '';
    
    try {
      if (picture is String) {
        return picture;
      } else if (picture is Map) {
        final data = picture['data'];
        if (data is String) return data;
      }
      // If it's JSArray or other type, return empty string
      return '';
    } catch (e) {
      debugPrint('[PEOPLE_SCREEN] Error extracting picture: $e');
      return '';
    }
  }

  void _onSearchChanged() {
    // Debounce search to avoid too many API calls
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      final query = _searchController.text.trim();
      if (query.isEmpty) {
        setState(() {
          _searchQuery = '';
          _searchResults = [];
        });
      } else {
        _performSearch(query);
      }
    });
  }

  Future<void> _loadInitialData() async {
    await Future.wait([
      _loadRecentConversationUsers(),
      _loadRandomUsers(reset: true),
    ]);
  }

  /// Load users from recent 1:1 conversations (last 10)
  Future<void> _loadRecentConversationUsers() async {
    if (_isLoadingRecent) return;
    
    if (!mounted) return;
    
    setState(() => _isLoadingRecent = true);
    
    try {
      debugPrint('[PEOPLE_SCREEN] Loading recent conversation users...');
      
      // Alternative approach: Get directly from RecentConversationsService
      // This uses SharedPreferences that might be populated elsewhere
      final recentConvs = await RecentConversationsService.getRecentConversations();
      debugPrint('[PEOPLE_SCREEN] RecentConversationsService returned ${recentConvs.length} conversations');
      
      final userMap = <String, Map<String, dynamic>>{};
      
      for (final conv in recentConvs.take(10)) {
        final userId = conv['uuid'];
        final displayName = conv['displayName'];
        
        if (userId != null && userId.isNotEmpty) {
          // FIRST: Try to get full profile from UserProfileService cache
          final profile = UserProfileService.instance.getProfile(userId);
          
          if (profile != null) {
            // Use cached profile data
            userMap[userId] = {
              'uuid': userId,
              'displayName': profile['displayName'] ?? userId,
              'atName': profile['atName'] ?? '',
              'picture': profile['picture'] ?? '',
              'isOnline': false, // TODO: Get online status from server
            };
          } else {
            // Profile not in cache, use conversation data
            userMap[userId] = {
              'uuid': userId,
              'displayName': displayName ?? userId,
              'atName': '',
              'picture': conv['picture'] ?? '',
              'isOnline': false,
            };
          }
        }
      }
      
      debugPrint('[PEOPLE_SCREEN] Processed ${userMap.length} users from RecentConversationsService');
      
      // Fallback: If no recent conversations in SharedPreferences,
      // try to get from ActivitiesService (which queries IndexedDB)
      if (userMap.isEmpty) {
        debugPrint('[PEOPLE_SCREEN] Falling back to ActivitiesService...');
        final conversations = await ActivitiesService.getRecentDirectConversations(
          limit: 10,
        );
        
        debugPrint('[PEOPLE_SCREEN] ActivitiesService found ${conversations.length} conversations');
        
        for (final conv in conversations) {
          final userId = conv['userId'] as String?;
          final displayName = conv['displayName'] as String?;
          
          if (userId != null && displayName != null) {
            final profile = UserProfileService.instance.getProfile(userId);
            
            userMap[userId] = {
              'uuid': userId,
              'displayName': displayName,
              'atName': profile?['atName'] ?? '',
              'picture': profile?['picture'] ?? '',
              'isOnline': false,
            };
          }
        }
        
        // Batch fetch display names from API if still showing UUIDs
        final userIdsNeedingNames = userMap.entries
            .where((entry) => entry.value['displayName'] == entry.key) // UUID used as name
            .map((entry) => entry.key)
            .toList();
        
        if (userIdsNeedingNames.isNotEmpty) {
          debugPrint('[PEOPLE_SCREEN] Fetching display names for ${userIdsNeedingNames.length} users from API...');
          try {
            ApiService.init();
            final resp = await ApiService.post(
              '${widget.host}/client/people/info',
              data: {'userIds': userIdsNeedingNames},
            );
            
            if (resp.statusCode == 200) {
              final users = resp.data is List ? resp.data : [];
              for (final user in users) {
                final userId = user['uuid'] as String?;
                if (userId != null && userMap.containsKey(userId)) {
                  userMap[userId]!['displayName'] = user['displayName'] ?? userId;
                  userMap[userId]!['atName'] = user['atName'] ?? '';
                  userMap[userId]!['picture'] = _extractPictureData(user['picture']);
                }
              }
              debugPrint('[PEOPLE_SCREEN] Updated ${users.length} display names from API');
            }
          } catch (e) {
            debugPrint('[PEOPLE_SCREEN] Error fetching display names from API: $e');
          }
        }
      }
      
      setState(() {
        _recentConversationUsers = userMap.values.toList();
        _isLoadingRecent = false;
      });
      
      debugPrint('[PEOPLE_SCREEN] Loaded ${_recentConversationUsers.length} recent users');
      debugPrint('[PEOPLE_SCREEN] Users: $_recentConversationUsers');
    } catch (e, stackTrace) {
      debugPrint('[PEOPLE_SCREEN] Error loading recent users: $e');
      debugPrint('[PEOPLE_SCREEN] Stack trace: $stackTrace');
      setState(() => _isLoadingRecent = false);
    }
  }

  /// Load random users (excluding those with conversations)
  Future<void> _loadRandomUsers({bool reset = false}) async {
    if (_isLoadingRandom) return;
    
    if (!mounted) return;
    
    setState(() => _isLoadingRandom = true);
    
    try {
      if (reset) {
        _randomUsersOffset = 0;
        _randomUsers.clear();
      }
      
      debugPrint('[PEOPLE_SCREEN] Loading random users (offset: $_randomUsersOffset)...');
      
      // Get all users
      ApiService.init();
      final resp = await ApiService.get('${widget.host}/people/list');
      
      if (resp.statusCode == 200) {
        final List<dynamic> allUsers = resp.data is List 
            ? resp.data 
            : (resp.data['users'] ?? []);
        
        // Load profiles for all users if not cached
        try {
          final userUuids = allUsers
              .where((u) => u['uuid'] != null)
              .map((u) => u['uuid'] as String)
              .toList();
          
          if (userUuids.isNotEmpty) {
            debugPrint('[PEOPLE_SCREEN] Loading profiles for ${userUuids.length} discover users...');
            await UserProfileService.instance.loadProfiles(userUuids);
            debugPrint('[PEOPLE_SCREEN] ✓ Profiles loaded');
          }
        } catch (e) {
          debugPrint('[PEOPLE_SCREEN] ⚠ Failed to load profiles (server may be unavailable): $e');
          // Continue anyway - UI will show fallback names
        }
        
        // Filter out users who already have conversations
        final recentUserUuids = _recentConversationUsers
            .map((u) => u['uuid'] as String)
            .toSet();
        
        final usersWithoutConversations = allUsers
            .where((user) {
              final uuid = user['uuid'] as String?;
              return uuid != null && !recentUserUuids.contains(uuid);
            })
            .map((user) {
              final userId = user['uuid'] as String;
              
              // Check UserProfileService cache first
              final profile = UserProfileService.instance.getProfile(userId);
              
              return {
                'uuid': userId,
                'displayName': profile?['displayName'] ?? user['displayName'] ?? user['username'] ?? 'Unknown',
                'atName': profile?['atName'] ?? user['atName'] ?? '',
                'picture': profile?['picture'] ?? _extractPictureData(user['picture']),
                'isOnline': false, // TODO: Get online status
              };
            })
            .toList();
        
        // Shuffle for randomness
        usersWithoutConversations.shuffle();
        
        // Take next batch (20 on load more, 10 initially)
        final batchSize = reset ? 10 : 20;
        final endIndex = (_randomUsersOffset + batchSize)
            .clamp(0, usersWithoutConversations.length);
        
        final newUsers = usersWithoutConversations
            .skip(_randomUsersOffset)
            .take(batchSize)
            .toList();
        
        setState(() {
          _randomUsers.addAll(newUsers);
          _randomUsersOffset = endIndex;
          _hasMoreRandomUsers = endIndex < usersWithoutConversations.length;
          _isLoadingRandom = false;
        });
        
        debugPrint('[PEOPLE_SCREEN] Loaded ${newUsers.length} random users (total: ${_randomUsers.length})');
      }
    } catch (e) {
      debugPrint('[PEOPLE_SCREEN] Error loading random users: $e');
      setState(() => _isLoadingRandom = false);
    }
  }

  /// Perform search with displayName and atName filter
  Future<void> _performSearch(String query) async {
    if (!mounted) return;
    
    setState(() {
      _searchQuery = query;
      _isSearching = true;
    });
    
    try {
      debugPrint('[PEOPLE_SCREEN] Searching for: $query');
      
      ApiService.init();
      final resp = await ApiService.get('${widget.host}/people/list');
      
      if (resp.statusCode == 200) {
        final List<dynamic> allUsers = resp.data is List 
            ? resp.data 
            : (resp.data['users'] ?? []);
        
        // Load profiles for search results if not cached
        try {
          final userUuids = allUsers
              .where((u) => u['uuid'] != null)
              .map((u) => u['uuid'] as String)
              .toList();
          
          if (userUuids.isNotEmpty) {
            debugPrint('[PEOPLE_SCREEN] Loading profiles for ${userUuids.length} search result users...');
            await UserProfileService.instance.loadProfiles(userUuids);
            debugPrint('[PEOPLE_SCREEN] ✓ Profiles loaded');
          }
        } catch (e) {
          debugPrint('[PEOPLE_SCREEN] ⚠ Failed to load profiles (server may be unavailable): $e');
          // Continue anyway - UI will show fallback names
        }
        
        // Filter by displayName or atName
        final queryLower = query.toLowerCase();
        final filtered = allUsers
            .where((user) {
              final displayName = (user['displayName'] ?? '').toString().toLowerCase();
              final atName = (user['atName'] ?? '').toString().toLowerCase();
              return displayName.contains(queryLower) || atName.contains(queryLower);
            })
            .map((user) {
              final userId = user['uuid'] as String;
              
              // Check UserProfileService cache first
              final profile = UserProfileService.instance.getProfile(userId);
              
              return {
                'uuid': userId,
                'displayName': profile?['displayName'] ?? user['displayName'] ?? user['username'] ?? 'Unknown',
                'atName': profile?['atName'] ?? user['atName'] ?? '',
                'picture': profile?['picture'] ?? _extractPictureData(user['picture']),
                'isOnline': false, // TODO: Get online status
              };
            })
            .toList();
        
        if (!mounted) return;
        
        setState(() {
          _searchResults = filtered;
          _isSearching = false;
        });
        
        debugPrint('[PEOPLE_SCREEN] Found ${filtered.length} results');
      }
    } catch (e) {
      debugPrint('[PEOPLE_SCREEN] Search error: $e');
      if (!mounted) return;
      
      setState(() => _isSearching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    // Determine which users to display
    final displayUsers = _searchQuery.isNotEmpty
        ? _searchResults
        : [..._recentConversationUsers, ..._randomUsers];
    
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Column(
        children: [
          // Search Bar
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                bottom: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search people by name or @username...',
                prefixIcon: Icon(Icons.search, color: colorScheme.onSurfaceVariant),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: colorScheme.onSurfaceVariant),
                        onPressed: () {
                          _searchController.clear();
                        },
                      )
                    : null,
                filled: true,
                fillColor: colorScheme.surfaceVariant,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
            ),
          ),
          
          // Content
          Expanded(
            child: _buildContent(displayUsers, colorScheme),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(List<Map<String, dynamic>> users, ColorScheme colorScheme) {
    // Loading state
    if (_isLoadingRecent && _isLoadingRandom && users.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    
    // Empty state
    if (users.isEmpty && !_isSearching) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.people_outline,
              size: 80,
              color: colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isNotEmpty ? 'No users found' : 'No users available',
              style: TextStyle(
                fontSize: 18,
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isNotEmpty
                  ? 'Try a different search term'
                  : 'Check back later',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
            ),
          ],
        ),
      );
    }
    
    return CustomScrollView(
      slivers: [
        // Section headers (only when not searching)
        if (_searchQuery.isEmpty && widget.showRecentSection && _recentConversationUsers.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
              child: Text(
                'Recent Conversations',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ),
          _buildUserGrid(_recentConversationUsers, colorScheme),
        ],
        
        if (_searchQuery.isEmpty && _randomUsers.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
              child: Text(
                'Discover People',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ),
          _buildUserGrid(_randomUsers, colorScheme),
        ],
        
        // Search results (when searching)
        if (_searchQuery.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
              child: Text(
                'Search Results (${_searchResults.length})',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ),
          _buildUserGrid(_searchResults, colorScheme),
        ],
        
        // Load More Button (only when not searching)
        if (_searchQuery.isEmpty && _hasMoreRandomUsers && !_isLoadingRandom)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ElevatedButton.icon(
                  onPressed: () => _loadRandomUsers(reset: false),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Load More'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                  ),
                ),
              ),
            ),
          ),
        
        // Loading indicator for Load More
        if (_isLoadingRandom)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  Widget _buildUserGrid(List<Map<String, dynamic>> users, ColorScheme colorScheme) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 200,
          childAspectRatio: 0.75,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final user = users[index];
            return _UserCard(
              user: user,
              colorScheme: colorScheme,
              onTap: () {
                widget.onMessageTap(
                  user['uuid'] as String,
                  user['displayName'] as String,
                );
              },
            );
          },
          childCount: users.length,
        ),
      ),
    );
  }
}

/// User Card Widget - Badge/Work Card Style
class _UserCard extends StatelessWidget {
  final Map<String, dynamic> user;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _UserCard({
    required this.user,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final displayName = user['displayName'] as String? ?? 'Unknown';
    final atName = user['atName'] as String? ?? '';
    final isOnline = user['isOnline'] as bool? ?? false;
    final userId = user['uuid'] as String? ?? '';
    
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.onInverseSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant,
          width: 2,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Picture at top (takes ~60% of card height)
            Expanded(
              flex: 3,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(10),
                        topRight: Radius.circular(10),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(10),
                        topRight: Radius.circular(10),
                      ),
                      child: SquareUserAvatar(
                        userId: userId,
                        displayName: displayName,
                        pictureData: user['picture'] as String?,
                        size: double.infinity,
                      ),
                    ),
                  ),
                  // Online status indicator
                  if (isOnline)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorScheme.surface,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            
            // Name section at bottom (~40% of card height)
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Display Name
                    Text(
                      displayName,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    
                    const SizedBox(height: 4),
                    
                    // @username
                    if (atName.isNotEmpty)
                      Text(
                        '@$atName',
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

