import 'package:flutter/material.dart';
import '../theme/app_theme_constants.dart';
import 'animated_widgets.dart';

/// Beispiel-Implementierung des neuen PeerWave Design Systems
/// 
/// Zeigt alle Design-Features:
/// - Context Panel mit UPPERCASE Headers
/// - Animierte Selection Tiles mit linkem Border
/// - Badges mit 8px Radius
/// - Hover-Effekte
/// - Tonwert-Trennung statt Divider

class DesignSystemExample extends StatefulWidget {
  const DesignSystemExample({super.key});

  @override
  State<DesignSystemExample> createState() => _DesignSystemExampleState();
}

class _DesignSystemExampleState extends State<DesignSystemExample> {
  int _selectedChannelIndex = 0;
  bool _channelsExpanded = true;
  bool _messagesExpanded = true;

  final List<_ChannelItem> _channels = [
    _ChannelItem('general', 5),
    _ChannelItem('support', 0),
    _ChannelItem('random', 12),
    _ChannelItem('announcements', 2),
  ];

  final List<_MessageItem> _messages = [
    _MessageItem('Alice', 3),
    _MessageItem('Bob', 0),
    _MessageItem('Charlie', 1),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // ================================================================
          // CONTEXT PANEL - #14181D
          // ================================================================
          Container(
            width: AppThemeConstants.contextPanelWidth,
            color: AppThemeConstants.contextPanelBackground,
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: AppThemeConstants.spacingSm,
                vertical: AppThemeConstants.spacingMd,
              ),
              children: [
                // ============================================================
                // CHANNELS SECTION
                // ============================================================
                ContextPanelHeader(
                  title: 'Channels',
                  trailing: IconButton(
                    icon: Icon(
                      _channelsExpanded 
                          ? Icons.expand_less 
                          : Icons.expand_more,
                      size: AppThemeConstants.iconSizeSmall,
                    ),
                    onPressed: () {
                      setState(() => _channelsExpanded = !_channelsExpanded);
                    },
                  ),
                ),
                AnimatedSection(
                  expanded: _channelsExpanded,
                  child: Column(
                    children: _channels.asMap().entries.map((entry) {
                      final index = entry.key;
                      final channel = entry.value;
                      
                      return AnimatedSelectionTile(
                        leading: const Icon(
                          Icons.tag,
                          size: AppThemeConstants.iconSizeSmall,
                        ),
                        title: Text(
                          '# ${channel.name}',
                          style: const TextStyle(
                            fontSize: AppThemeConstants.fontSizeBody,
                            color: AppThemeConstants.textPrimary,
                          ),
                        ),
                        trailing: AnimatedBadge(
                          count: channel.unreadCount,
                          isSmall: true,
                        ),
                        selected: _selectedChannelIndex == index,
                        onTap: () {
                          setState(() => _selectedChannelIndex = index);
                        },
                      );
                    }).toList(),
                  ),
                ),
                
                SizedBox(height: AppThemeConstants.spacingMd),
                
                // ============================================================
                // MESSAGES SECTION
                // ============================================================
                ContextPanelHeader(
                  title: 'Direct Messages',
                  trailing: IconButton(
                    icon: Icon(
                      _messagesExpanded 
                          ? Icons.expand_less 
                          : Icons.expand_more,
                      size: AppThemeConstants.iconSizeSmall,
                    ),
                    onPressed: () {
                      setState(() => _messagesExpanded = !_messagesExpanded);
                    },
                  ),
                ),
                AnimatedSection(
                  expanded: _messagesExpanded,
                  child: Column(
                    children: _messages.map((message) {
                      return AnimatedSelectionTile(
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          child: Text(
                            message.name[0].toUpperCase(),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          message.name,
                          style: const TextStyle(
                            fontSize: AppThemeConstants.fontSizeBody,
                            color: AppThemeConstants.textPrimary,
                          ),
                        ),
                        trailing: AnimatedBadge(
                          count: message.unreadCount,
                          isSmall: true,
                        ),
                        selected: false,
                        onTap: () {
                          // Navigate to DM
                        },
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
          
          // ================================================================
          // MAIN VIEW - #181C21 (Tonwert-Trennung, kein Divider!)
          // ================================================================
          Expanded(
            child: Container(
              color: AppThemeConstants.mainViewBackground,
              child: Column(
                children: [
                  // App Bar
                  Container(
                    height: 60,
                    padding: AppThemeConstants.paddingHorizontalMd,
                    decoration: BoxDecoration(
                      color: AppThemeConstants.contextPanelBackground,
                      // Keine Border/Divider - nur Tonwert-Trennung!
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.tag,
                          size: AppThemeConstants.iconSizeStandard,
                          color: AppThemeConstants.textPrimary,
                        ),
                        SizedBox(width: AppThemeConstants.spacingSm),
                        Text(
                          '# ${_channels[_selectedChannelIndex].name}',
                          style: const TextStyle(
                            fontSize: AppThemeConstants.fontSizeH2,
                            fontWeight: AppThemeConstants.fontWeightH2,
                            color: AppThemeConstants.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  // Content
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.chat_bubble,
                            size: 64,
                            color: AppThemeConstants.textSecondary,
                          ),
                          SizedBox(height: AppThemeConstants.spacingMd),
                          const Text(
                            'Chat Content Area',
                            style: TextStyle(
                              fontSize: AppThemeConstants.fontSizeH2,
                              color: AppThemeConstants.textPrimary,
                            ),
                          ),
                          SizedBox(height: AppThemeConstants.spacingXs),
                          const Text(
                            'Main View Background: #181C21',
                            style: TextStyle(
                              fontSize: AppThemeConstants.fontSizeCaption,
                              color: AppThemeConstants.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  // Input Area
                  Container(
                    padding: AppThemeConstants.paddingMd,
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: 'Nachricht schreiben...',
                        fillColor: AppThemeConstants.inputBackground,
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: AppThemeConstants.borderRadiusStandard,
                          borderSide: BorderSide.none,
                        ),
                        suffixIcon: IconButton(
                          icon: Icon(
                            Icons.send,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          onPressed: () {},
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      
      // Floating Action Button mit neuem Style
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // Navigate mit Custom Page Transition
          Navigator.of(context).push(
            SlidePageRoute(
              builder: (context) => const _SecondPage(),
            ),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ============================================================================
// Helper Classes
// ============================================================================

class _ChannelItem {
  final String name;
  final int unreadCount;

  _ChannelItem(this.name, this.unreadCount);
}

class _MessageItem {
  final String name;
  final int unreadCount;

  _MessageItem(this.name, this.unreadCount);
}

/// Second Page für Page Transition Demo
class _SecondPage extends StatelessWidget {
  const _SecondPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Page Transition Demo'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.check_circle,
              size: 100,
              color: AppThemeConstants.textPrimary,
            ),
            SizedBox(height: AppThemeConstants.spacingMd),
            const Text(
              'Smooth Slide Transition!',
              style: TextStyle(
                fontSize: AppThemeConstants.fontSizeH1,
                fontWeight: AppThemeConstants.fontWeightH1,
                color: AppThemeConstants.textPrimary,
              ),
            ),
            SizedBox(height: AppThemeConstants.spacingXs),
            const Text(
              '250ms easeInOutQuart',
              style: TextStyle(
                fontSize: AppThemeConstants.fontSizeCaption,
                color: AppThemeConstants.textSecondary,
              ),
            ),
            SizedBox(height: AppThemeConstants.spacingLg),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Zurück'),
            ),
          ],
        ),
      ),
    );
  }
}
