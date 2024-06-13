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

## How it works?
In the current version, you can share your screen, window, tab, or multiple files. This app uses [Socket.io](https://socket.io/) to manage some metadata for peers and files. The data is shared directly between peers without a server in the middle. All direct peers share the same stream or downloaded files to increase your audience and overcome limitations.

This is achieved using the [WebRTC](https://webrtc.org/) standard. A Google [STUN](https://en.wikipedia.org/wiki/STUN) server is used to establish connections between peers, but you can use your [own STUN server](https://www.stunprotocol.org/) if you host the app yourself. All metadata in this app is temporary and will be lost if the server restarts.

## Table of Contents
- [How it works?](#how-it-works)
- [Table of Contents](#table-of-contents)
- [Try It](#try-it)
- [Getting Started](#getting-started)
  - [Node](#node)
  - [Docker Build](#docker-build)
  - [Docker Hub](#docker-hub)
- [Limitations](#limitations)
- [Source Code](#source-code)
- [Support](#support)

## Try It
You can find a running instance at [peerwave.org](https://peerwave.org)

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

```bash
# Pull the image from Docker Hub
docker pull simonzander/peerwave

# Run the image in a container
docker run -d -p 4000:4000 peerwave
```

## Limitations
The main limitation is your upload speed, which is shared with your direct peers. If you are streaming, factors like the codec, resolution, and quick refreshes can increase your CPU (for VP8/VP9) or GPU (for H.264) load and affect your upload speed. The Chrome browser can handle up to 512 data connections and 56 streams.

If you are sharing files, the file size and the number of files increase your memory usage. The files are splitted in chunks and your peers share also your downloaded file and hold the data in their memory.

## Source Code
This is an open-source project licensed under the MIT license.

## Support
If you like this project, you can support me by [buying me a coffee](https://buymeacoffee.com/simonz). Feature requests and bug reports are welcome.