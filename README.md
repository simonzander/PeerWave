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
### Node

```bash
# Install dependencies for server
npm install

# Run the server
node server
```

### Docker Build

```bash
# Building the image
docker build --tag peerwave .

# Run the image in a container
docker run -d -p 4000:4000 peerwave
```

### Docker Hub
Image: [simonzander/peerwave](https://hub.docker.com/r/simonzander/peerwave)

```bash
# Pull the image from Docker Hub
docker pull simonzander/peerwave

# Run the image in a container
docker run -d -p 4000:4000 peerwave
```

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