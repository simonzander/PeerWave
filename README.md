<div align="center">
  <img src="https://github.com/simonzander/PeerWave/blob/main/public/logo_43.png?raw=true" height="100px">
  <h1>
  PeerWave</h1>
  <strong>WebRTC share peer to peer to peer... the endless meshed wave of sharing</strong>
</div>
<br>
<p align="center">
  <a href="https://github.com/simonzander/PeerWave/actions/workflows/docker-image.yml">
    <img src="https://github.com/simonzander/peerwave/actions/workflows/docker-image.yml/badge.svg" alt="Build Status">
  </a>
  <img src="https://img.shields.io/github/last-commit/simonzander/peerwave" alt="GitHub last commit">
  <a href="https://github.com/simonzander/PeerWave/issues?q=is:issue+is:open+label:bug">
    <img src="https://img.shields.io/github/issues-search?query=https%3A%2F%2Fgithub.com%2Fsimonzander%2FPeerWave%2Fissues%3Fq%3Dis%3Aissue%2Bis%3Aopen%2Blabel%3Abug&label=ISSUES&color=red" alt="GitHub issues">
  </a>
</p>

![License: Source-Available](https://img.shields.io/badge/license-Source--Available-blue.svg)
![Commercial Use Requires License](https://img.shields.io/badge/commercial%20use-requires%20license-red.svg)
![Not for SaaS Hosting](https://img.shields.io/badge/Hosting%2FSaaS-Requires%20Commercial%20License-orange)

## How it works?

[![PeerWave Demo](https://img.youtube.com/vi/S69E2orWrys/default.jpg)](https://youtu.be/S69E2orWrys)

In the current version, you can share your screen, window, tab, or multiple files. This app uses [Socket.io](https://socket.io/) to manage some metadata for peers and files. The data is shared directly between peers without a server in the middle. All direct peers share the same stream or downloaded files to increase your audience and overcome limitations.

This is achieved using the [WebRTC](https://webrtc.org/) standard. A Google [STUN](https://en.wikipedia.org/wiki/STUN) server is used to establish connections between peers, but you can use your [own STUN server](https://www.stunprotocol.org/) if you host the app yourself. All metadata in this app is temporary and will be lost if the server restarts.

:rotating_light: **New Feature: Meeting** :rotating_light:

We're excited to announce our latest feature! You can now create a room for instant or scheduled meetings. Participants can join using their webcam and microphone, and even share their screens. Get ready to enhance your collaboration experience!

## Table of Contents
- [How it works?](#how-it-works)
- [Table of Contents](#table-of-contents)
- [Try It](#try-it)
- [Meeting](#meeting)
  - [Chat Function](#chat-function)
  - [Voice Only](#voice-only)
  - [Scheduled or Instant Meeting](#scheduled-or-instant-meeting)
  - [Emojis](#emojis)
  - [Switch Camera \& Microphone in Meeting](#switch-camera--microphone-in-meeting)
  - [Mute and Unmute](#mute-and-unmute)
  - [Camera On and Off](#camera-on-and-off)
  - [Screen Sharing](#screen-sharing)
  - [Set Max Cam Resolution to Prevent Traffic](#set-max-cam-resolution-to-prevent-traffic)
  - [Raise Hand](#raise-hand)
  - [Other Audio Output in Chrome with Test Sound](#other-audio-output-in-chrome-with-test-sound)
- [Stream Settings](#stream-settings)
  - [Cropping](#cropping)
  - [Resizing](#resizing)
- [Getting Started](#getting-started)
  - [Node](#node)
  - [Docker Build](#docker-build)
  - [Docker Hub](#docker-hub)
- [Limitations](#limitations)
- [Support](#support)
- [License](#license)
  - [Commercial Licensing](#commercial-licensing)

## Try It
You can find a running instance at [peerwave.org](https://peerwave.org)

## Meeting
Our new meeting feature provides a comprehensive set of tools designed to enhance your communication and collaboration experience. Below is a detailed overview of each capability:

### Chat Function
- **Description**: Engage in real-time text conversations alongside video meetings.
- **Usage**: Accessible via the chat icon within the meeting interface.

### Voice Only
- **Description**: Participate in meetings using audio-only mode.
- **Usage**: Select the voice-only option when creating the meeting.

### Scheduled or Instant Meeting
- **Description**: Create meetings that can either be scheduled for a future time or initiated instantly.
- **Usage**: Use the Schedule or Instant when you set up a meeting.

### Emojis
- **Description**: Express emotions and reactions using a variety of emojis during meetings.
- **Usage**: Access the emoji panel within the meeting interface.

### Switch Camera & Microphone in Meeting
- **Description**: Toggle between different cameras and microphones during the meeting.
- **Usage**: Use the bottom menu within the meeting interface to switch devices.

### Mute and Unmute
- **Description**: Control your audio input by muting or unmuting your microphone.
- **Usage**: Click the microphone icon to mute or unmute during the meeting.

### Camera On and Off
- **Description**: Turn your camera on or off during the meeting as needed.
- **Usage**: Click the camera icon to enable or disable your video feed.

### Screen Sharing
- **Description**: Share your screen to present documents, slides, or other content.
- **Usage**: Click the screen sharing button and select the screen or window you wish to share.

### Set Max Cam Resolution to Prevent Traffic
- **Description**: Optimize bandwidth usage by setting a maximum camera resolution.
- **Usage**: Adjust the camera resolution settings when you set up the meeting.

### Raise Hand
- **Description**: Indicate that you wish to speak without interrupting the conversation.
- **Usage**: Click the raise hand icon to notify the host and participants.

### Other Audio Output in Chrome with Test Sound
- **Description**: Select different audio outputs in Chrome and test sound settings to ensure optimal audio performance.
- **Usage**: Select Sound Output before joining the meeting. You can also test it.

These features are designed to provide a versatile and user-friendly meeting experience, enabling effective communication and collaboration.

## Stream Settings
### Cropping 
You can crop the hosted video with an experimental API that has not yet been standardized. As of 2024-06-19, this API is available in Chrome 94, Edge 94 and Opera 80.
### Resizing
You can resize the hosted video with an experimental API that has not yet been standardized. As of 2024-06-19, this API is available in Chrome 94, Edge 94 and Opera 80. 
## Getting Started

### Quick Start with Docker Compose (Recommended)

The easiest way to run PeerWave is using Docker Compose:

```bash
# Clone the repository
git clone https://github.com/simonzander/PeerWave.git
cd PeerWave

# Copy environment template
cp server/.env.example server/.env

# Edit configuration (see Configuration section below)
nano server/.env

# Start all services
docker-compose up -d

# View logs
docker-compose logs -f
```

PeerWave will be available at `http://localhost:3000`

### Configuration

#### Environment Variables

Copy `server/.env.example` to `server/.env` and adjust values:

```bash
# Required: Change these in production!
SESSION_SECRET=your-long-random-string-here
LIVEKIT_API_KEY=your-livekit-key
LIVEKIT_API_SECRET=your-livekit-secret

# Optional: Adjust as needed
PORT=3000
NODE_ENV=production
LIVEKIT_TURN_DOMAIN=your-domain.com
```

Generate secure secrets:
```bash
openssl rand -base64 32
```

#### Configuration File

Alternatively, mount a custom config file:

```yaml
# docker-compose.yml
volumes:
  - ./my-config.js:/usr/src/app/config/config.js:ro
```

See `server/config/config.example.js` for all available options.

### Manual Deployment

#### Prerequisites
- Node.js 22+
- Flutter 3.27.1+ (for web client)
- Docker (optional)

#### Build Web Client

```bash
cd client
flutter pub get
flutter build web --release

# Copy to server
cp -r build/web ../server/web
```

#### Run Server

```bash
cd server
npm install
node server.js
```

### Building Docker Image

Use the provided build script:

```bash
# Linux/Mac
chmod +x build-docker.sh
./build-docker.sh v1.0.0

# Windows
.\build-docker.ps1 v1.0.0

# With Docker Hub push
./build-docker.sh v1.0.0 --push
```

Or manually:

```bash
# Build web client
cd client && flutter build web --release
cp -r build/web ../server/web

# Build Docker image
cd ../server
docker build -t simonzander/peerwave:v1.0.0 .
```

### Docker Hub

Pre-built images: [simonzander/peerwave](https://hub.docker.com/r/simonzander/peerwave)

```bash
# Pull latest image
docker pull simonzander/peerwave:latest

# Run with environment variables
docker run -d \
  -p 3000:3000 \
  -e SESSION_SECRET=your-secret \
  -e LIVEKIT_API_KEY=your-key \
  -e LIVEKIT_API_SECRET=your-secret \
  -v ./db:/usr/src/app/db \
  simonzander/peerwave:latest
```

### Native Clients

Download pre-built native clients from [GitHub Releases](https://github.com/simonzander/PeerWave/releases):

- **Windows**: `.exe` installer or portable `.zip`
- **macOS**: `.dmg` installer (coming soon)
- **Linux**: AppImage (coming soon)

#### Build from Source

```bash
# Windows
cd client
flutter build windows --release

# macOS  
flutter build macos --release

# Linux
flutter build linux --release
```

### Production Deployment Checklist

- [ ] Change `SESSION_SECRET` to a random 32+ character string
- [ ] Change `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET`
- [ ] Set `NODE_ENV=production`
- [ ] Configure your domain in `LIVEKIT_TURN_DOMAIN`
- [ ] Set up SSL certificates (if using HTTPS)
- [ ] Configure CORS origins for your domains
- [ ] Set up database backups (volume: `./db`)
- [ ] Configure firewall rules for required ports
- [ ] Review rate limiting settings
- [ ] Enable logging and monitoring

### Required Ports

| Port Range | Protocol | Service | Required |
|------------|----------|---------|----------|
| 3000 | TCP | Web/API | Yes |
| 7880 | TCP | LiveKit WebRTC | Yes |
| 7881 | TCP | LiveKit HTTP API | Yes |
| 5349 | TCP/UDP | TURN/TLS | Yes (P2P) |
| 443 | UDP | TURN/UDP (QUIC) | Yes (P2P) |
| 30100-30200 | UDP | RTP (WebRTC media) | Yes |
| 30300-30400 | UDP | TURN Relay | Yes (P2P) |

### Troubleshooting

**Web client not loading:**
- Ensure `server/web/` folder exists with built Flutter web files
- Run `./build-docker.sh` to rebuild

**Video calls not working:**
- Check LiveKit is running: `docker-compose logs peerwave-livekit`
- Verify TURN configuration in `.env`
- Ensure UDP ports 30100-30400 are open

**Database errors:**
- Check `./db` volume permissions
- Ensure SQLite file is writable
- Review logs: `docker-compose logs peerwave-server`

**Authentication issues (native clients):**
- Verify `SESSION_SECRET` is set and persistent
- Check HMAC configuration in `.env`
- Review client/server time synchronization

## Limitations
The main limitation is your upload speed, which is shared with your direct peers. If you are streaming, factors like the codec, resolution, and quick refreshes can increase your CPU (for VP8/VP9) or GPU (for H.264) load and affect your upload speed. The Chrome browser can handle up to 512 data connections and 56 streams.

If you are sharing files, the file size and the number of files increase your memory usage. The files are splitted in chunks and your peers share also your downloaded file and hold the data in their memory.

## Support
If you like this project, you can support me by [buying me a coffee](https://buymeacoffee.com/simonz). Feature requests and bug reports are welcome.

## License

PeerWave is **Source-Available**.

- Private and personal use: **free**
- Viewing, studying, and modifying the source: **allowed**
- Commercial use (including company internal use): **requires a paid license**
- Hosting or offering PeerWave as a public service (SaaS / cloud / multi-tenant): **not permitted without a commercial license**

### Commercial Licensing

Commercial licenses are based on company size (annual billing):

| Employees | Annual Price |
|---|---:|
| 1–5 | 199 € |
| 6–25 | 499 € |
| 26–100 | 1,499 € |
| 101–500 | 4,999 € |
| > 500 | Contact us |

**Contact for commercial use:**  
📧 license@peerwave.org 

⚠️ Note: Versions up to v0.x were licensed under MIT. Starting from v1.0.0, this project is licensed under the PolyForm Shield License 1.0.0.