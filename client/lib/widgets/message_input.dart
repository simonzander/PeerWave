import 'package:flutter/material.dart';

/// Reusable widget for message input with formatting toolbar
class MessageInput extends StatefulWidget {
  final Function(String) onSendMessage;

  const MessageInput({
    super.key,
    required this.onSendMessage,
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _showFormatting = false;
  OverlayEntry? _emojiOverlay;
  final LayerLink _emojiLayerLink = LayerLink();

  @override
  void dispose() {
    _emojiOverlay?.remove();
    _emojiOverlay = null;
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Insert markdown/formatting at cursor position
  void _insertFormatting(String prefix, String suffix) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.start;
    final end = selection.end;

    if (start < 0) {
      // No selection, insert at end
      _controller.text = text + prefix + suffix;
      _controller.selection = TextSelection.collapsed(offset: text.length + prefix.length);
    } else if (start == end) {
      // Cursor position, no selection
      final newText = text.substring(0, start) + prefix + suffix + text.substring(end);
      _controller.text = newText;
      _controller.selection = TextSelection.collapsed(offset: start + prefix.length);
    } else {
      // Text selected
      final selectedText = text.substring(start, end);
      final newText = text.substring(0, start) + prefix + selectedText + suffix + text.substring(end);
      _controller.text = newText;
      _controller.selection = TextSelection(
        baseOffset: start + prefix.length,
        extentOffset: start + prefix.length + selectedText.length,
      );
    }

    _focusNode.requestFocus();
  }

  /// Insert emoji at cursor position
  void _insertEmoji(String emoji) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.start;

    if (start < 0) {
      // No selection, insert at end
      _controller.text = text + emoji;
      _controller.selection = TextSelection.collapsed(offset: text.length + emoji.length);
    } else {
      // Insert at cursor
      final newText = text.substring(0, start) + emoji + text.substring(selection.end);
      _controller.text = newText;
      _controller.selection = TextSelection.collapsed(offset: start + emoji.length);
    }

    _focusNode.requestFocus();
  }

  /// Show emoji picker overlay
  void _showEmojiPicker(BuildContext context) {
    // Remove existing overlay if present
    _emojiOverlay?.remove();

    _emojiOverlay = OverlayEntry(
      builder: (context) => Positioned(
        width: 350,
        height: 400,
        child: CompositedTransformFollower(
          link: _emojiLayerLink,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -10),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            color: Colors.grey[850],
            child: _EmojiPickerWidget(
              onEmojiSelected: (emoji) {
                _insertEmoji(emoji);
                _hideEmojiPicker();
              },
              onClose: _hideEmojiPicker,
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_emojiOverlay!);
  }

  /// Hide emoji picker overlay
  void _hideEmojiPicker() {
    _emojiOverlay?.remove();
    _emojiOverlay = null;
  }

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      widget.onSendMessage(text);
      _controller.clear();
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Rich text formatting toolbar
        if (_showFormatting)
          Container(
            color: Colors.grey[900],
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.format_bold, size: 20),
                    color: Colors.white70,
                    tooltip: 'Bold',
                    onPressed: () => _insertFormatting('**', '**'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.format_italic, size: 20),
                    color: Colors.white70,
                    tooltip: 'Italic',
                    onPressed: () => _insertFormatting('_', '_'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.format_strikethrough, size: 20),
                    color: Colors.white70,
                    tooltip: 'Strikethrough',
                    onPressed: () => _insertFormatting('~~', '~~'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.link, size: 20),
                    color: Colors.white70,
                    tooltip: 'Link',
                    onPressed: () => _insertFormatting('[', '](https://example.com)'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.format_list_numbered, size: 20),
                    color: Colors.white70,
                    tooltip: 'Numbered List',
                    onPressed: () => _insertFormatting('1. ', '\n'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.format_list_bulleted, size: 20),
                    color: Colors.white70,
                    tooltip: 'Bullet List',
                    onPressed: () => _insertFormatting('• ', '\n'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.code, size: 20),
                    color: Colors.white70,
                    tooltip: 'Inline Code',
                    onPressed: () => _insertFormatting('`', '`'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.code_off, size: 20),
                    color: Colors.white70,
                    tooltip: 'Code Block',
                    onPressed: () => _insertFormatting('```\n', '\n```'),
                  ),
                ],
              ),
            ),
          ),
        // Input area
        Container(
          color: Colors.grey[850],
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Plus button with context menu
              PopupMenuButton<String>(
                icon: const Icon(Icons.add_circle_outline, color: Colors.white70),
                color: Colors.grey[800],
                tooltip: 'Attach',
                onSelected: (value) {
                  print('[MESSAGE_INPUT] Selected attachment type: $value');
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'file',
                    child: Row(
                      children: [
                        Icon(Icons.attach_file, color: Colors.white70),
                        SizedBox(width: 8),
                        Text('File', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'image',
                    child: Row(
                      children: [
                        Icon(Icons.image, color: Colors.white70),
                        SizedBox(width: 8),
                        Text('Image', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'camera',
                    child: Row(
                      children: [
                        Icon(Icons.camera_alt, color: Colors.white70),
                        SizedBox(width: 8),
                        Text('Camera', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              // Text input
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: 'Type a message...',
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: Colors.grey[800],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  style: const TextStyle(color: Colors.white),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              // Formatting toggle
              IconButton(
                icon: Icon(
                  _showFormatting ? Icons.format_clear : Icons.format_size,
                  color: Colors.white70,
                ),
                tooltip: _showFormatting ? 'Hide Formatting' : 'Show Formatting',
                onPressed: () {
                  setState(() {
                    _showFormatting = !_showFormatting;
                  });
                },
              ),
              // Emoji button
              CompositedTransformTarget(
                link: _emojiLayerLink,
                child: IconButton(
                  icon: const Icon(Icons.emoji_emotions_outlined, color: Colors.white70),
                  tooltip: 'Emoji',
                  onPressed: () {
                    if (_emojiOverlay == null) {
                      _showEmojiPicker(context);
                    } else {
                      _hideEmojiPicker();
                    }
                  },
                ),
              ),
              // Mention button
              IconButton(
                icon: const Icon(Icons.alternate_email, color: Colors.white70),
                tooltip: 'Mention',
                onPressed: () {
                  _insertFormatting('@', '');
                },
              ),
              // Send button
              IconButton(
                icon: const Icon(Icons.send, color: Colors.amber),
                tooltip: 'Send',
                onPressed: _sendMessage,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Emoji Picker Widget
class _EmojiPickerWidget extends StatefulWidget {
  final Function(String) onEmojiSelected;
  final VoidCallback onClose;

  const _EmojiPickerWidget({
    required this.onEmojiSelected,
    required this.onClose,
  });

  @override
  State<_EmojiPickerWidget> createState() => _EmojiPickerWidgetState();
}

class _EmojiPickerWidgetState extends State<_EmojiPickerWidget> {
  String _searchQuery = '';
  String _selectedCategory = 'Smileys';

  // Emoji categories
  static const Map<String, List<String>> _emojiCategories = {
    'Smileys': ['😀', '😃', '😄', '😁', '😅', '😂', '🤣', '😊', '😇', '🙂', '🙃', '😉', '😌', '😍', '🥰', '😘', '😗', '😙', '😚', '😋', '😛', '😝', '😜', '🤪', '🤨', '🧐', '🤓', '😎', '🤩', '🥳'],
    'Gestures': ['👋', '🤚', '🖐', '✋', '🖖', '👌', '🤌', '🤏', '✌️', '🤞', '🤟', '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️', '👍', '👎', '✊', '👊', '🤛', '🤜', '👏', '🙌', '👐', '🤲'],
    'People': ['👶', '👧', '🧒', '👦', '👩', '🧑', '👨', '👩‍🦱', '🧑‍🦱', '👨‍🦱', '👩‍🦰', '🧑‍🦰', '👨‍🦰', '👱‍♀️', '👱', '👱‍♂️', '👩‍🦳', '🧑‍🦳', '👨‍🦳', '👩‍🦲', '🧑‍🦲', '👨‍🦲', '🧔', '👵', '🧓', '👴', '👲', '👳‍♀️', '👳', '👳‍♂️'],
    'Animals': ['🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🐤', '🦆', '🦅', '🦉', '🦇', '🐺', '🐗', '🐴', '🦄', '🐝', '🐛', '🦋'],
    'Food': ['🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🍈', '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🍆', '🥑', '🥦', '🥬', '🥒', '🌶', '🌽', '🥕', '🧄', '🧅', '🥔', '🍠', '🥐'],
    'Activities': ['⚽', '🏀', '🏈', '⚾', '🥎', '🎾', '🏐', '🏉', '🥏', '🎱', '🏓', '🏸', '🏒', '🏑', '🥍', '🏏', '🥅', '⛳', '🏹', '🎣', '🤿', '🥊', '🥋', '🎽', '🛹', '🛼', '🛷', '⛸', '🥌', '🎿'],
    'Travel': ['🚗', '🚕', '🚙', '🚌', '🚎', '🏎', '🚓', '🚑', '🚒', '🚐', '🛻', '🚚', '🚛', '🚜', '🦯', '🦽', '🦼', '🛴', '🚲', '🛵', '🏍', '🛺', '🚨', '🚔', '🚍', '🚘', '🚖', '🚡', '🚠', '🚟'],
    'Objects': ['⌚', '📱', '📲', '💻', '⌨️', '🖥', '🖨', '🖱', '🖲', '🕹', '🗜', '💾', '💿', '📀', '📼', '📷', '📸', '📹', '🎥', '📽', '🎞', '📞', '☎️', '📟', '📠', '📺', '📻', '🎙', '🎚', '🎛'],
    'Symbols': ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝', '💟', '☮️', '✝️', '☪️', '🕉', '☸️', '✡️', '🔯', '🕎', '☯️', '☦️', '🛐'],
    'Flags': ['🏁', '🚩', '🎌', '🏴', '🏳️', '🏳️‍🌈', '🏳️‍⚧️', '🏴‍☠️', '🇩🇪', '🇺🇸', '🇬🇧', '🇫🇷', '🇪🇸', '🇮🇹', '🇯🇵', '🇨🇳', '🇰🇷', '🇧🇷', '🇨🇦', '🇦🇺', '🇮🇳', '🇷🇺', '🇲🇽', '🇸🇪', '🇳🇴', '🇩🇰', '🇫🇮', '🇳🇱', '🇧🇪', '🇨🇭'],
  };

  List<String> get _filteredEmojis {
    final categoryEmojis = _emojiCategories[_selectedCategory] ?? [];
    if (_searchQuery.isEmpty) {
      return categoryEmojis;
    }
    return categoryEmojis;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[700]!, width: 1),
      ),
      child: Column(
        children: [
          // Header with search and close button
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[800],
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search emojis...',
                      hintStyle: TextStyle(color: Colors.grey[500], fontSize: 14),
                      prefixIcon: Icon(Icons.search, color: Colors.grey[500], size: 20),
                      filled: true,
                      fillColor: Colors.grey[900],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  iconSize: 20,
                  onPressed: widget.onClose,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          // Category tabs
          Container(
            height: 40,
            color: Colors.grey[800],
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: _emojiCategories.keys.map((category) {
                final isSelected = category == _selectedCategory;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedCategory = category;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.amber : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      category,
                      style: TextStyle(
                        color: isSelected ? Colors.black : Colors.white70,
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // Emoji grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: _filteredEmojis.length,
              itemBuilder: (context, index) {
                final emoji = _filteredEmojis[index];
                return InkWell(
                  onTap: () {
                    widget.onEmojiSelected(emoji);
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Center(
                      child: Text(
                        emoji,
                        style: const TextStyle(fontSize: 24),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
