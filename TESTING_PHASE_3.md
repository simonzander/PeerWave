# 🧪 P2P File Sharing - Quick Test Guide

## ✅ Phase 3 Implementation: File Key Exchange

**Status:** Ready for Testing  
**URL:** http://localhost:3000

---

## 🎯 What to Test

Phase 3 implementiert **File Key Exchange** - der kritische fehlende Teil für funktionierende Downloads.

**Before Phase 3:**
- ❌ Download Button zeigte Error: "Download feature requires file key distribution - coming in Phase 3"

**After Phase 3:**
- ✅ Download Button startet Key Exchange
- ✅ Encryption Key wird von Uploader zu Downloader übertragen
- ✅ Download funktioniert!

---

## 🚀 Quick Test (5 Minuten)

### **Setup:**
1. **Browser 1 (Normal):** User A (Uploader)
2. **Browser 2 (Incognito):** User B (Downloader)

### **User A: Upload File**
```
1. http://localhost:3000
2. Login (oder Register falls nötig)
3. Navigate: /file-upload (oder über Menü)
4. Click: "Choose File" → Select small file (< 5 MB)
5. Click: "Upload & Share"
6. Wait: Chunking ✓ → Encryption ✓ → Storage ✓ → Announce ✓
7. See: "Upload complete!" message
8. ⚠️ KEEP BROWSER OPEN (User A = Seeder)
```

### **User B: Download File**
```
1. http://localhost:3000(Incognito window)
2. Login as different user
3. Navigate: /file-browser
4. See: User A's file with seeder badge
5. Click: "Download" button
6. 🔍 Watch Console (F12)
7. See: Navigation to /downloads
8. See: Progress bar advancing
9. Wait: Download complete
```

---

## 🔍 What to Look For

### **Success Indicators:**

#### **User B Console (Downloader):**
```javascript
[FILE BROWSER] Requesting file key from seeder: <peerId>
[P2P] Requesting file key for <fileId> from <peerId>
[P2P] File key received for <fileId> (32 bytes)         ← KEY EXCHANGE!
[FILE BROWSER] File key received (32 bytes)
[FILE BROWSER] Download started for file: <fileId>
[P2P] Received chunk 0 from <peerId>
[P2P] Chunk 0 verified and stored
[P2P] Received chunk 1 from <peerId>
...
```

#### **User A Console (Seeder):**
```javascript
[P2P] Received key request for <fileId> from <peerId>   ← KEY REQUEST!
[P2P] Sent file key for <fileId> to <peerId>            ← KEY SENT!
[P2P] Received chunk request for chunk 0 from <peerId>
[P2P] Sent chunk 0 to <peerId>
...
```

### **UI Indicators:**
- ✅ /downloads Screen zeigt Progress Bar
- ✅ Progress Bar bewegt sich (10%...50%...100%)
- ✅ "Downloaded" / "Completed" Status

---

## ❌ Error Scenarios (Expected Behavior)

### **1. Seeder Offline**
**Test:** Close User A's browser before User B clicks Download

**Expected:**
```
❌ Error: "Failed to get file key: TimeoutException"
```

### **2. Network Issues**
**Test:** Disconnect network during key exchange

**Expected:**
```
❌ Error: "Key request timed out after 10s"
```

### **3. No Seeders Available**
**Test:** User A uploads file but closes browser

**Expected:**
```
❌ Error: "No seeders available for this file"
```

---

## 🐛 Troubleshooting

### **Problem: "No seeders available"**
**Solution:**
- User A muss Browser offen lassen (Seeder!)
- Check: User A's Console für "File announced successfully"

### **Problem: Key Exchange Timeout**
**Solution:**
- Check: Both users logged in?
- Check: WebRTC connection established? (Console logs)
- Check: Docker containers running? (`docker-compose ps`)

### **Problem: Download stuck at 0%**
**Solution:**
- Open Browser Console (F12)
- Check for errors in both User A and User B
- Verify: Key exchange succeeded (see console logs above)

### **Problem: Docker not running**
**Solution:**
```powershell
cd D:\PeerWave
docker-compose up -d
```

---

## 📊 Server Status Check

```powershell
# Check containers
docker-compose ps

# Expected output:
# peerwave-server   Up X minutes (healthy)
# peerwave-coturn   Up X hours

# Check logs
docker-compose logs -f peerwave-server

# Should see:
# [P2P FILE] User <uuid> announcing file: <fileId>
# [P2P WEBRTC] Relaying offer/answer/ICE
```

---

## 🎓 Technical Details

### **What Happens Under the Hood:**

1. **User A Uploads:**
   - File → 64KB Chunks
   - Generate AES-256 Key
   - Encrypt Chunks with Key
   - Store Key in IndexedDB
   - Announce File to Server

2. **User B Clicks Download:**
   - Get File Info (size, checksum, seeders)
   - **NEW:** Request Key from Seeder
   - Wait for Key Response (max 10s)
   - Store Key in IndexedDB
   - Start WebRTC Download

3. **Key Exchange (NEW!):**
   ```
   User B → WebRTC DataChannel → User A
   Message: { type: 'key-request', fileId: '...' }
   
   User A → IndexedDB → Get Key
   User A → WebRTC DataChannel → User B
   Message: { type: 'key-response', fileId: '...', key: 'base64...' }
   
   User B → Decode Key → Store in IndexedDB
   User B → Start Chunk Requests
   ```

4. **Chunk Download:**
   - Request Chunks from Seeder(s)
   - Decrypt Chunks with Key
   - Verify SHA-256 Hash
   - Store in IndexedDB
   - Assemble File

---

## 🔐 Security Notes

- **Keys are NEVER sent to server**
- **WebRTC uses DTLS encryption** (like HTTPS for UDP)
- **Keys travel peer-to-peer only**
- **Base64 encoding** is for JSON format, NOT security
- **Security comes from DTLS**

---

## ✅ Test Completion Checklist

- [ ] User A can upload file
- [ ] User A sees "Upload complete" message
- [ ] User B can see file in /file-browser
- [ ] User B clicks Download button
- [ ] **Console shows key exchange messages** (CRITICAL!)
- [ ] User B navigated to /downloads screen
- [ ] Progress bar shows advancement
- [ ] Download completes without errors
- [ ] User B console shows chunk verification

---

## 📞 If Something Goes Wrong

### **Rebuild & Restart:**
```powershell
cd D:\PeerWave
.\build-and-start.ps1
```

### **Check Logs:**
```powershell
# Server logs
docker-compose logs -f peerwave-server

# Browser Console (F12)
# Check for errors in both User A and User B
```

### **Clean Slate:**
```powershell
# Stop containers
docker-compose down

# Clean build
cd client
flutter clean
flutter build web --release

# Rebuild everything
cd ..
.\build-and-start.ps1
```

---

## 🎉 Success!

Wenn du diese Meldungen siehst, ist alles perfekt:

**User B Console:**
```
✅ [FILE BROWSER] File key received (32 bytes)
✅ [FILE BROWSER] Download started for file: <fileId>
✅ [P2P] Chunk 0 verified and stored
✅ [P2P] Chunk 1 verified and stored
...
```

**Das bedeutet:**
- ✅ Key Exchange funktioniert
- ✅ WebRTC P2P Transfer funktioniert
- ✅ Encryption/Decryption funktioniert
- ✅ Chunk Verification funktioniert
- ✅ **PHASE 3 COMPLETE!**

---

## 📚 Next Steps

Nach erfolgreichem Test:

1. **Optional: Phase 4 UX Enhancements**
   - Inline Upload Button
   - Floating Progress Overlay
   - Preview/Thumbnails
   - Auto-Resume
   
2. **Production Deployment**
   - coturn Server Setup
   - HTTPS/SSL Certificates
   - Domain & DNS

3. **Performance Optimization**
   - Multi-Seeder Parallel Downloads
   - Chunk Request Pipelining
   - Better Rarest-First Algorithm

---

**Viel Erfolg beim Testen! 🚀**

Bei Fragen oder Problemen, check die Console Logs - sie sind sehr detailliert!
