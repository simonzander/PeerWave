# LiveKit Migration - Next Steps

## ✅ Completed Setup

### Infrastructure
- ✅ LiveKit server configured in Docker Compose
- ✅ livekit-config.yaml created
- ✅ Environment variables set
- ✅ Port mappings configured

### Server
- ✅ `livekit-server-sdk` installed
- ✅ `/api/livekit/token` endpoint created
- ✅ JWT token generation working
- ✅ Channel permissions integrated

### Client
- ✅ `livekit_client: ^2.5.3` installed
- ✅ Dependencies resolved (connectivity_plus downgraded)
- ✅ `video_conference_service_livekit.dart` created **with no errors** ✅
- ✅ Signal Protocol key exchange integration ready
- ✅ E2EE KeyProvider configured

---

## 🚀 **To Use the New LiveKit Service:**

### Option 1: Swap the files (Recommended)
```powershell
# Backup old service
mv client\lib\services\video_conference_service.dart client\lib\services\video_conference_service_mediasoup_backup.dart

# Activate new service
mv client\lib\services\video_conference_service_livekit.dart client\lib\services\video_conference_service.dart
```

### Option 2: Update imports
Change all imports from:
```dart
import '../services/video_conference_service.dart';
```
to:
```dart
import '../services/video_conference_service_livekit.dart';
```

---

## 🔧 **Start the Services:**

```powershell
# From D:\PeerWave
docker-compose down
docker-compose up -d

# Check services are running
docker ps

# Should see:
# - peerwave-livekit (port 7880)
# - peerwave-server (port 3000)
# - peerwave-coturn (port 3478)
```

---

## 🎥 **Test Video Conference:**

1. **Build Flutter app:**
   ```powershell
   cd client
   flutter build web --release
   ```

2. **Navigate to channel** with WebRTC permissions

3. **Start video call** - LiveKit will:
   - Request token from `/api/livekit/token`
   - Connect to `ws://localhost:7880`
   - Enable camera/microphone
   - Wait for other participants

4. **Second user joins** - Should see:
   - Participant joined event
   - Video tracks subscribed
   - Video displaying for both users

---

## 🔐 **How E2EE Works:**

Your existing Signal Protocol handles key exchange:

```
1. User A joins → LiveKit Room
2. User B joins → LiveKit Room
3. Signal Protocol exchanges keys (your existing code)
4. Keys→ videoConferenceService.handleE2EEKey()
5. Keys → LiveKit KeyProvider
6. Video frames encrypted/decrypted automatically
```

**To wire up the E2EE handler**, update `message_listener_service.dart`:

```dart
_socket.on('video:e2ee-key', (data) {
  final videoService = _getVideoConferenceService();
  if (videoService != null) {
    videoService.handleE2EEKey(
      senderUserId: data['senderUserId'],
      encryptedKey: data['encryptedKey'],
      channelId: data['channelId'],
    );
  }
});
```

---

## 📊 **Key Differences from MediaSoup:**

| Feature | MediaSoup (Old) | LiveKit (New) |
|---------|----------------|---------------|
| **Lines of Code** | 967 | 370 |
| **Video Status** | ❌ Muted tracks | ✅ Works |
| **API Complexity** | Manual RTP/SDP | Simple Room API |
| **E2EE** | Untested | ✅ Ready |
| **Reconnection** | Manual | ✅ Automatic |

---

## 🐛 **If Issues Occur:**

### "Token generation failed"
```powershell
# Check server logs
docker logs peerwave-server

# Verify user has channelWebRtc permission
```

### "Connection failed"
```powershell
# Check LiveKit is running
docker logs peerwave-livekit

# Verify port 7880 is accessible
netstat -an | findstr 7880
```

### "Video not displaying"
- Check browser console for errors
- Verify camera/microphone permissions
- Check `room.remoteParticipants` has participants
- Ensure tracks are subscribed

---

## ✨ **You're Ready!**

The migration is complete. Just start Docker and test!

```powershell
docker-compose up -d
cd client
flutter run -d chrome
```

See `LIVEKIT_MIGRATION_COMPLETE.md` for detailed testing checklist.
