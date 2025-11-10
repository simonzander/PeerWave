import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:just_audio/just_audio.dart';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import '../utils/file_operations_native.dart'
    if (dart.library.html) '../utils/file_operations_web.dart';

/// Voice message player with waveform visualization
class VoiceMessagePlayer extends StatefulWidget {
  final String base64Audio;
  final int? durationSeconds;
  final int? sizeBytes;
  final bool isOwnMessage;

  const VoiceMessagePlayer({
    Key? key,
    required this.base64Audio,
    this.durationSeconds,
    this.sizeBytes,
    this.isOwnMessage = false,
  }) : super(key: key);

  @override
  State<VoiceMessagePlayer> createState() => _VoiceMessagePlayerState();
}

class _VoiceMessagePlayerState extends State<VoiceMessagePlayer> {
  late AudioPlayer _audioPlayer;
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  bool _isLoading = false;
  String? _tempFilePath;

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _setupAudioPlayer();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _cleanupTempFile();
    super.dispose();
  }

  Future<void> _setupAudioPlayer() async {
    // Listen to player state
    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing;
        });
      }
    });

    // Listen to position updates
    _audioPlayer.positionStream.listen((position) {
      if (mounted) {
        setState(() {
          _currentPosition = position;
        });
      }
    });

    // Listen to duration updates
    _audioPlayer.durationStream.listen((duration) {
      if (mounted && duration != null) {
        setState(() {
          _totalDuration = duration;
        });
      }
    });

    // Auto-reset when playback completes
    _audioPlayer.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _audioPlayer.seek(Duration.zero);
        _audioPlayer.pause();
      }
    });
  }

  Future<void> _prepareAudio() async {
    if (_tempFilePath != null) {
      // Already prepared
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Decode base64 to bytes
      final audioBytes = base64Decode(widget.base64Audio);

      if (kIsWeb) {
        // Web: Use data URL directly
        // Create a data URL from the audio bytes
        final mimeType = 'audio/opus'; // or 'audio/ogg'
        final base64String = base64Encode(audioBytes);
        final dataUrl = 'data:$mimeType;base64,$base64String';
        
        // Load from data URL
        await _audioPlayer.setUrl(dataUrl);
        _tempFilePath = dataUrl; // Store for cleanup check
        
        debugPrint('[VOICE_PLAYER] Audio prepared from data URL (web)');
      } else {
        // Native: Use file system
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        _tempFilePath = '${tempDir.path}/voice_$timestamp.opus';

        // Write to file
        await FileOperations.writeBytes(_tempFilePath!, audioBytes);

        // Load audio
        await _audioPlayer.setFilePath(_tempFilePath!);

        debugPrint('[VOICE_PLAYER] Audio prepared from file: $_tempFilePath');
      }
    } catch (e) {
      debugPrint('[VOICE_PLAYER] Error preparing audio: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading audio: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _cleanupTempFile() async {
    if (_tempFilePath != null && !kIsWeb) {
      // Only cleanup file on native platforms
      try {
        if (await FileOperations.exists(_tempFilePath!)) {
          await FileOperations.delete(_tempFilePath!);
        }
      } catch (e) {
        debugPrint('[VOICE_PLAYER] Error cleaning up temp file: $e');
      }
    }
  }

  Future<void> _togglePlayPause() async {
    if (_isLoading) return;

    if (_tempFilePath == null) {
      await _prepareAudio();
    }

    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    
    final displayDuration = _totalDuration.inSeconds > 0 
        ? _totalDuration 
        : Duration(seconds: widget.durationSeconds ?? 0);

    final progress = displayDuration.inSeconds > 0
        ? _currentPosition.inSeconds / displayDuration.inSeconds
        : 0.0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.isOwnMessage ? primaryColor.withOpacity(0.15) : Colors.grey[850],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.isOwnMessage ? primaryColor.withOpacity(0.3) : Colors.grey[700]!,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Play/Pause button
          GestureDetector(
            onTap: _togglePlayPause,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: primaryColor,
                shape: BoxShape.circle,
              ),
              child: _isLoading
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      _isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
            ),
          ),
          const SizedBox(width: 12),
          // Waveform and duration
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Waveform visualization
                _buildWaveform(progress),
                const SizedBox(height: 6),
                // Duration and size
                Row(
                  children: [
                    Text(
                      _isPlaying || _currentPosition.inSeconds > 0
                          ? _formatDuration(_currentPosition)
                          : _formatDuration(displayDuration),
                      style: TextStyle(
                        color: widget.isOwnMessage ? theme.colorScheme.primary : Colors.grey[300],
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      ' / ${_formatDuration(displayDuration)}',
                      style: TextStyle(
                        color: widget.isOwnMessage ? theme.colorScheme.primary.withOpacity(0.7) : Colors.grey[500],
                        fontSize: 12,
                      ),
                    ),
                    if (widget.sizeBytes != null) ...[
                      Text(
                        ' • ',
                        style: TextStyle(
                          color: widget.isOwnMessage ? theme.colorScheme.primary.withOpacity(0.5) : Colors.grey[600],
                        ),
                      ),
                      Text(
                        '${(widget.sizeBytes! / 1024).toStringAsFixed(1)} KB',
                        style: TextStyle(
                          color: widget.isOwnMessage ? theme.colorScheme.primary.withOpacity(0.7) : Colors.grey[500],
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaveform(double progress) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    
    // Generate simple waveform bars
    const barCount = 40;
    
    return SizedBox(
      height: 30,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(barCount, (index) {
          // Generate pseudo-random heights for waveform effect
          final seed = widget.base64Audio.hashCode + index;
          final height = 0.3 + ((seed % 70) / 100);
          
          final barProgress = index / barCount;
          final isPlayed = barProgress <= progress;
          
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
                decoration: BoxDecoration(
                  color: isPlayed
                      ? (widget.isOwnMessage ? primaryColor : primaryColor)
                      : (widget.isOwnMessage ? primaryColor.withOpacity(0.3) : Colors.grey[600]),
                  borderRadius: BorderRadius.circular(2),
                ),
                height: 30 * height,
              ),
            ),
          );
        }),
      ),
    );
  }
}
