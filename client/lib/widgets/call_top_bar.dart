import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import '../services/video_conference_service.dart';
import '../services/user_profile_service.dart';
import '../services/web_pip_bridge_stub.dart'
    if (dart.library.js_interop) '../services/web_pip_bridge.dart';
import '../services/web_pip_video_stub.dart'
    if (dart.library.html) '../services/web_pip_video.dart';
import '../main.dart';
import 'call_duration_timer.dart';
import 'dart:convert';

/// Global top bar showing active call status
/// Only visible when in a call and overlay is visible
class CallTopBar extends StatefulWidget {
  const CallTopBar({super.key});

  @override
  State<CallTopBar> createState() => _CallTopBarState();
}

class _CallTopBarState extends State<CallTopBar> {
  static const bool _enableDocPip = false;
  final Map<String, String?> _profilePictures = {};
  final Map<String, String> _displayNames = {};
  final Set<String> _loadedProfiles =
      {}; // Track which profiles we've already loaded
  final Map<String, Widget> _cachedAvatars =
      {}; // Cache avatar widgets to prevent rebuilds
  final Map<String, DateTime> _remoteLastSpokeAt = {};
  bool _pipOpen = false;
  bool _pipAutoOpening = false;
  DateTime? _pipLastAttemptAt;
  String? _pipLayoutSignature;

  @override
  void initState() {
    super.initState();
    // Load participant profiles when topbar is created
    _loadParticipantProfiles();

    if (kIsWeb) {
      WebPipBridge.instance.registerOnClose(() {
        final service = VideoConferenceService.instance;
        WebPipVideoManager.instance.detach();
        if (mounted) {
          setState(() {
            _pipOpen = false;
          });
        }
        if (service.isInCall && !service.isInFullView) {
          service.showOverlay();
        }
      });
    }
  }

  void _loadParticipantProfiles() {
    final service = VideoConferenceService.instance;
    if (service.remoteParticipants.isNotEmpty) {
      for (final participant in service.remoteParticipants) {
        final uuid = participant.identity;

        // Skip if already loaded
        if (_loadedProfiles.contains(uuid)) continue;
        _loadedProfiles.add(uuid);

        final profile = UserProfileService.instance.getProfileOrLoad(
          uuid,
          onLoaded: (profile) {
            if (mounted && profile != null) {
              setState(() {
                _profilePictures[uuid] = profile['picture'] as String?;
                _displayNames[uuid] = profile['displayName'] as String? ?? uuid;
                // Clear cached avatar to rebuild with new picture
                _cachedAvatars.remove(uuid);
              });
            }
          },
        );

        // Use cached data immediately if available
        if (profile != null) {
          _profilePictures[uuid] = profile['picture'] as String?;
          _displayNames[uuid] = profile['displayName'] as String? ?? uuid;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Consumer<VideoConferenceService>(
      builder: (context, service, _) {
        if (_pipOpen && kIsWeb) {
          _updatePipVideo(service);
        }

        if (_enableDocPip &&
            kIsWeb &&
            !_pipOpen &&
            !_pipAutoOpening &&
            service.isInCall &&
            service.isOverlayVisible &&
            !service.isInFullView &&
            WebPipBridge.instance.isSupported) {
          final now = DateTime.now();
          final lastAttempt = _pipLastAttemptAt;
          final canAttempt =
              lastAttempt == null || now.difference(lastAttempt).inSeconds > 4;
          if (canAttempt) {
            _pipAutoOpening = true;
            _pipLastAttemptAt = now;
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              final opened = await WebPipBridge.instance.open(
                title: service.channelName ?? 'Video Call',
                status: 'Call active',
              );
              if (opened) {
                _pipOpen = true;
                _updatePipVideo(service);
                service.hideOverlay();
              } else {
                if (service.isInCall && !service.isInFullView) {
                  service.showOverlay();
                }
              }
              _pipAutoOpening = false;
            });
          }
        }
        // Show TopBar only when in call AND not in full-view mode
        // For meetings, hide the top bar when in full-view
        if (!service.isInCall || (service.isInFullView && service.isMeeting)) {
          return const SizedBox.shrink();
        }

        // For channels, hide when in full-view
        if (service.isInFullView && !service.isMeeting) {
          return const SizedBox.shrink();
        }

        return Container(
          color: colorScheme.surfaceContainerHighest,
          child: SafeArea(
            bottom: false,
            child: Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  // Live indicator
                  Icon(
                    Icons.videocam,
                    color: colorScheme.errorContainer,
                    size: 16,
                  ),
                  const SizedBox(width: 8),

                  // Channel info - all in one row
                  Expanded(
                    child: Row(
                      children: [
                        // Channel name
                        Flexible(
                          flex: 3,
                          child: Text(
                            service.channelName ?? 'Video Call',
                            style: TextStyle(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.normal,
                              fontSize: 14,
                              decoration: TextDecoration.none,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),

                        const SizedBox(width: 8),
                        Icon(
                          Icons.access_time,
                          color: colorScheme.onSurface,
                          size: 14,
                        ),
                        const SizedBox(width: 4),

                        // Call duration
                        if (service.callStartTime != null)
                          Flexible(
                            flex: 2,
                            child: CallDurationTimer(
                              startTime: service.callStartTime!,
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.normal,
                                fontSize: 12,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),

                        const SizedBox(width: 8),
                        Icon(
                          Icons.people,
                          color: colorScheme.onSurface,
                          size: 14,
                        ),
                        const SizedBox(width: 4),

                        // Participant count
                        Text(
                          '${service.remoteParticipants.length + 1}',
                          style: TextStyle(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.normal,
                            fontSize: 12,
                            decoration: TextDecoration.none,
                          ),
                        ),

                        const SizedBox(width: 8),

                        // Participant avatars
                        if (service.remoteParticipants.isNotEmpty)
                          Builder(
                            builder: (context) {
                              // Ensure profiles are loaded when participant list changes
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                _loadParticipantProfiles();
                              });

                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (
                                    var i = 0;
                                    i < service.remoteParticipants.length &&
                                        i < 3;
                                    i++
                                  )
                                    _getCachedAvatar(
                                      service.remoteParticipants[i].identity,
                                      colorScheme,
                                    ),
                                  if (service.remoteParticipants.length > 3)
                                    Container(
                                      width: 24,
                                      height: 24,
                                      margin: const EdgeInsets.only(left: 4),
                                      decoration: BoxDecoration(
                                        color: colorScheme.outlineVariant,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Center(
                                        child: Text(
                                          '+${service.remoteParticipants.length - 3}',
                                          style: TextStyle(
                                            color: colorScheme.onSurface,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            decoration: TextDecoration.none,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 8),

                  // Return to full view button
                  IconButton(
                    iconSize: 24,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      Icons.open_in_full,
                      color: colorScheme.onSurface,
                      size: 20,
                    ),
                    onPressed: () {
                      final channelId = service.currentChannelId;
                      final channelName = service.channelName;
                      if (channelId != null) {
                        service.enterFullView();
                        // Use global navigator key to access GoRouter
                        final navigatorContext =
                            MyApp.rootNavigatorKey.currentContext;
                        if (navigatorContext != null) {
                          // Navigate to meeting or channel view based on type
                          if (service.isMeeting) {
                            GoRouter.of(navigatorContext).go(
                              '/meeting/video/$channelId',
                              extra: <String, dynamic>{
                                'meetingTitle': channelName ?? 'Meeting',
                              },
                            );
                          } else {
                            GoRouter.of(navigatorContext).go(
                              '/app/channels/$channelId',
                              extra: {
                                'host': 'localhost:3000',
                                'name': channelName ?? 'Channel',
                                'type': 'webrtc',
                              },
                            );
                          }
                        } else {
                          debugPrint(
                            '[CallTopBar] Navigator key has no context',
                          );
                        }
                      }
                    },
                  ),

                  const SizedBox(width: 12),

                  // Show overlay button (visible when overlay is hidden)
                  if (_shouldShowFloatingButton)
                    IconButton(
                      iconSize: 24,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(
                        Icons.picture_in_picture_alt,
                        color: colorScheme.onSurface,
                        size: 20,
                      ),
                      onPressed: () async {
                        if (kIsWeb && WebPipBridge.instance.isSupported) {
                          final opened = await WebPipBridge.instance.open(
                            title: service.channelName ?? 'Video Call',
                            status: 'Call active',
                          );
                          if (opened) {
                            _pipOpen = true;
                            _updatePipVideo(service);
                            service.hideOverlay();
                          }
                          return;
                        }

                        service.showOverlay();
                      },
                    ),

                  if (_shouldShowFloatingButton) const SizedBox(width: 12),

                  // Toggle camera button
                  IconButton(
                    iconSize: 24,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      service.localParticipant?.isCameraEnabled() == true
                          ? Icons.videocam
                          : Icons.videocam_off,
                      color: colorScheme.onSurface,
                      size: 20,
                    ),
                    onPressed: () => service.toggleCamera(),
                  ),

                  const SizedBox(width: 12),

                  // Toggle microphone button
                  IconButton(
                    iconSize: 24,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      service.localParticipant?.isMicrophoneEnabled() == true
                          ? Icons.mic
                          : Icons.mic_off,
                      color: colorScheme.onSurface,
                      size: 20,
                    ),
                    onPressed: () => service.toggleMicrophone(),
                  ),

                  const SizedBox(width: 12),

                  // Leave call button
                  IconButton(
                    iconSize: 24,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      Icons.call_end,
                      color: colorScheme.errorContainer,
                      size: 20,
                    ),
                    onPressed: () async {
                      await service.leaveRoom();
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _updatePipVideo(VideoConferenceService service) {
    final layout = _buildPipLayout(service);
    if (layout.screenShare == null && layout.tiles.isEmpty) {
      return;
    }
    final signature = _pipLayoutKey(layout);
    if (signature == _pipLayoutSignature) {
      return;
    }
    _pipLayoutSignature = signature;
    WebPipVideoManager.instance.updateLayout(
      title: service.channelName ?? 'Video Call',
      status: 'Call active',
      screenShare: layout.screenShare,
      tiles: layout.tiles,
    );
  }

  bool get _shouldShowFloatingButton {
    if (_enableDocPip && kIsWeb && WebPipBridge.instance.isSupported) {
      return true;
    }
    return false;
  }

  ({lk.VideoTrack? screenShare, List<WebPipTile> tiles}) _buildPipLayout(
    VideoConferenceService service,
  ) {
    final room = service.room;
    if (room == null) return (screenShare: null, tiles: <WebPipTile>[]);

    final tiles = <WebPipTile>[];
    lk.VideoTrack? screenShareTrack;

    final sortedRemotes = _sortedRemotes(room);

    if (service.hasActiveScreenShare &&
        service.currentScreenShareParticipantId != null) {
      final screenShareId = service.currentScreenShareParticipantId!;
      final participant = screenShareId == room.localParticipant?.identity
          ? room.localParticipant
          : _findRemoteParticipant(room, screenShareId);
      if (participant is lk.LocalParticipant) {
        final screenPubs = participant.videoTrackPublications.where(
          (p) => p.source == lk.TrackSource.screenShareVideo,
        );
        if (screenPubs.isNotEmpty) {
          screenShareTrack = screenPubs.first.track as lk.VideoTrack?;
        }
      } else if (participant is lk.RemoteParticipant) {
        final screenPubs = participant.videoTrackPublications.where(
          (p) => p.source == lk.TrackSource.screenShareVideo,
        );
        if (screenPubs.isNotEmpty) {
          screenShareTrack = screenPubs.first.track as lk.VideoTrack?;
        }
      }
    }

    final local = room.localParticipant;
    if (local != null &&
        local.identity != service.currentScreenShareParticipantId) {
      final localTrack = _pickCameraTrack(local);
      if (localTrack != null) {
        tiles.add(
          WebPipTile(
            track: localTrack,
            label: 'You',
            isSpeaking: local.isSpeaking,
          ),
        );
      }
    }

    final maxTiles = screenShareTrack == null ? 4 : 3;
    for (final remote in sortedRemotes) {
      if (remote.identity == service.currentScreenShareParticipantId) {
        continue;
      }
      if (tiles.length >= maxTiles) {
        break;
      }
      final remoteTrack = _pickCameraTrack(remote);
      if (remoteTrack != null) {
        tiles.add(
          WebPipTile(
            track: remoteTrack,
            label: _displayNames[remote.identity] ?? remote.identity,
            isSpeaking: remote.isSpeaking,
          ),
        );
      }
    }

    return (screenShare: screenShareTrack, tiles: tiles);
  }

  String _pipLayoutKey(
    ({lk.VideoTrack? screenShare, List<WebPipTile> tiles}) layout,
  ) {
    final buffer = StringBuffer();
    final screenSid = layout.screenShare?.sid ?? '';
    buffer.write(screenSid);
    buffer.write('|');
    for (final tile in layout.tiles) {
      buffer.write(tile.track.sid);
      buffer.write(':');
      buffer.write(tile.isSpeaking ? '1' : '0');
      buffer.write(':');
      buffer.write(tile.track.muted ? '1' : '0');
      buffer.write(':');
      buffer.write(tile.label);
      buffer.write('|');
    }
    return buffer.toString();
  }

  lk.RemoteParticipant? _findRemoteParticipant(lk.Room room, String identity) {
    for (final participant in room.remoteParticipants.values) {
      if (participant.identity == identity) {
        return participant;
      }
    }
    return null;
  }

  List<lk.RemoteParticipant> _sortedRemotes(lk.Room room) {
    if (room.remoteParticipants.isEmpty) return <lk.RemoteParticipant>[];

    final remotes = room.remoteParticipants.values.toList();
    final now = DateTime.now();
    for (final remote in remotes) {
      if (remote.isSpeaking) {
        _remoteLastSpokeAt[remote.identity] = now;
      }
    }

    remotes.sort((a, b) {
      if (a.isSpeaking && !b.isSpeaking) return -1;
      if (b.isSpeaking && !a.isSpeaking) return 1;

      final aLast =
          _remoteLastSpokeAt[a.identity] ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bLast =
          _remoteLastSpokeAt[b.identity] ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bLast.compareTo(aLast);
    });

    return remotes;
  }

  lk.VideoTrack? _pickCameraTrack(dynamic participant) {
    if (participant is! lk.LocalParticipant &&
        participant is! lk.RemoteParticipant) {
      return null;
    }
    final cameraPubs = participant.videoTrackPublications.where(
      (p) => p.source != lk.TrackSource.screenShareVideo,
    );
    if (cameraPubs.isNotEmpty) {
      return cameraPubs.first.track as lk.VideoTrack?;
    }
    return null;
  }

  /// Get cached avatar widget or build new one if profile changed
  Widget _getCachedAvatar(String uuid, ColorScheme colorScheme) {
    final picture = _profilePictures[uuid];
    final cacheKey = '$uuid-$picture'; // Include picture in cache key

    // Return cached widget if it exists and hasn't changed
    if (_cachedAvatars.containsKey(cacheKey)) {
      return _cachedAvatars[cacheKey]!;
    }

    // Build and cache new avatar widget
    final avatar = _buildParticipantAvatar(uuid, colorScheme);
    _cachedAvatars[cacheKey] = avatar;
    return avatar;
  }

  Widget _buildParticipantAvatar(String uuid, ColorScheme colorScheme) {
    final picture = _profilePictures[uuid];
    final displayName = _displayNames[uuid] ?? uuid;
    final fallbackLetter = displayName.substring(0, 1).toUpperCase();

    return Container(
      width: 24,
      height: 24,
      margin: const EdgeInsets.only(left: 4),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: colorScheme.outline.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: picture != null && picture.isNotEmpty
            ? Image.memory(
                base64Decode(picture.split(',').last),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Center(
                    child: Text(
                      fallbackLetter,
                      style: TextStyle(
                        color: colorScheme.onPrimaryContainer,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  );
                },
              )
            : Center(
                child: Text(
                  fallbackLetter,
                  style: TextStyle(
                    color: colorScheme.onPrimaryContainer,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
      ),
    );
  }
}
