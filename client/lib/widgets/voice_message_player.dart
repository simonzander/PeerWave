import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:just_audio/just_audio.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
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
  // Use audioplayers on Windows (just_audio doesn't support Windows)
  // Use just_audio on other platforms (better web/mobile support)
  AudioPlayer? _justAudioPlayer;
  ap.AudioPlayer? _audioPlayersPlayer;
  
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  bool _isLoading = false;
  String? _tempFilePath;
  
  bool get _isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    if (_isWindows) {
      _audioPlayersPlayer = ap.AudioPlayer();
    } else {
      _justAudioPlayer = AudioPlayer();
    }
    _setupAudioPlayer();
  }

  @override
  void dispose() {
    _justAudioPlayer?.dispose();
    _audioPlayersPlayer?.dispose();
    _cleanupTempFile();
    super.dispose();
  }

  Future<void> _setupAudioPlayer() async {
    if (_isWindows) {
      // Windows: Use audioplayers
      _audioPlayersPlayer!.onPlayerStateChanged.listen((state) {
        if (mounted) {
          setState(() {
            _isPlaying = state == ap.PlayerState.playing;
          });
        }
      });

      _audioPlayersPlayer!.onPositionChanged.listen((position) {
        if (mounted) {
          setState(() {
            _currentPosition = position;
          });
        }
      });

      _audioPlayersPlayer!.onDurationChanged.listen((duration) {
        if (mounted) {
          setState(() {
            _totalDuration = duration;
          });
        }
      });

      _audioPlayersPlayer!.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _isPlaying = false;
            _currentPosition = Duration.zero;
          });
        }
      });
    } else {
      // Other platforms: Use just_audio
      _justAudioPlayer!.playerStateStream.listen((state) {
        if (mounted) {
          setState(() {
            _isPlaying = state.playing;
          });
        }
      });

      _justAudioPlayer!.positionStream.listen((position) {
        if (mounted) {
          setState(() {
            _currentPosition = position;
          });
        }
      });

      _justAudioPlayer!.durationStream.listen((duration) {
        if (mounted && duration != null) {
          setState(() {
            _totalDuration = duration;
          });
        }
      });

      _justAudioPlayer!.processingStateStream.listen((state) {
        if (state == ProcessingState.completed) {
          _justAudioPlayer!.seek(Duration.zero);
          _justAudioPlayer!.pause();
        }
      });
    }
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
        // Web: Try multiple approaches for browser compatibility
        final base64String = base64Encode(audioBytes);
        
        // Try different MIME types in order of browser compatibility
        // Support both Opus (most platforms) and AAC (Windows native)
        final mimeTypes = [
          'audio/webm;codecs=opus', // Best for Chrome
          'audio/ogg;codecs=opus',  // Good for Firefox
          'audio/opus',              // Generic Opus fallback
          'audio/mp4',               // AAC from Windows
          'audio/aac',               // AAC alternative
        ];
        
        String? workingUrl;
        Exception? lastError;
        
        for (final mimeType in mimeTypes) {
          try {
            final dataUrl = 'data:$mimeType;base64,$base64String';
            await _justAudioPlayer!.setUrl(dataUrl);
            workingUrl = dataUrl;
            debugPrint('[VOICE_PLAYER] Audio prepared with MIME type: $mimeType');
            break;
          } catch (e) {
            lastError = e as Exception;
            debugPrint('[VOICE_PLAYER] Failed with $mimeType: $e');
            continue;
          }
        }
        
        if (workingUrl != null) {
          _tempFilePath = workingUrl;
        } else {
          throw lastError ?? Exception('Failed to load audio with any MIME type');
        }
      } else {
        // Native: Use file system
        // Support multiple formats: .opus (Android/iOS/Linux), .m4a (Windows AAC)
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        
        // Detect format from first bytes or use .m4a as universal fallback
        String extension = '.m4a'; // AAC container, widely supported
        if (audioBytes.length > 4) {
          // Check for Opus magic number (OpusHead)
          final header = String.fromCharCodes(audioBytes.take(8));
          if (header.contains('Opus')) {
            extension = '.opus';
          }
        }
        
        _tempFilePath = '${tempDir.path}/voice_$timestamp$extension';

        // Write to file
        await FileOperations.writeBytes(_tempFilePath!, audioBytes);

        // Load audio
        if (_isWindows) {
          await _audioPlayersPlayer!.setSourceDeviceFile(_tempFilePath!);
        } else {
          await _justAudioPlayer!.setFilePath(_tempFilePath!);
        }

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
      if (_isWindows) {
        await _audioPlayersPlayer!.pause();
      } else {
        await _justAudioPlayer!.pause();
      }
    } else {
      if (_isWindows) {
        await _audioPlayersPlayer!.resume();
      } else {
        await _justAudioPlayer!.play();
      }
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
