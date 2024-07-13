/* global MediaStreamTrackProcessor, MediaStreamTrackGenerator, VideoFrame, VideoDecoder VideoEncoder */

/**
 * Represents a WebRTC class with a constructor.
 * @constructor
 * @param {Socket} socket - The socket object.
 * @param {Object} config - The configuration object.
 */
class RTC {

    constructor(socket, config) {
      this.socket = socket;
      this.config = config;
      this.eventRegistry = {};
      this.peerConnections = {};
      this.dataChannels = {};
      this.currentUploads = {};

      this.INITIAL_CHUNK_SIZE = 16384; // 16KB
      this.MIN_BUFFERED_AMOUNT_LOW_THRESHOLD = 16384; // 16KB
      this.MAX_BUFFERED_AMOUNT_LOW_THRESHOLD = 1048576; // 1MB
      this.DEFAULT_BUFFERED_AMOUNT_LOW_THRESHOLD = 65536; // 64KB

      this.toastCallback = function() {};
      this.statsCallback = function() {};
      this.progressUploadCallback = function() {};

      window.onunload = window.onbeforeunload = () => {
        for (const [_, peerConnection] of Object.entries(this.peerConnections)) {
          peerConnection.close();
        }
        this.socket.close();
      };
    }
    /**
     * Displays a toast message.
     * @param {string} message - The message to display.
     * @param {string} type - The type of toast message (e.g., "success", "error", "warning").
     */
    toast(message, type) {
      this.toastCallback(message, type);
    }
    /**
     * Registers an event listener for the specified event name.
     *
     * @param {string} eventName - The name of the event to listen for.
     * @param {Function} listener - The callback function to be executed when the event is triggered.
     */
    on(eventName, listener) {
      // Check if the event already has a listener registered
      if (!this.eventRegistry[eventName]) {
        this.socket.on(eventName, listener);
        this.eventRegistry[eventName] = true; // Mark this event as having a listener
      }
    }
    /**
     * Unregisters the event listener for the specified event name.
     * @param {string} eventName - The name of the event to unregister the listener for.
     */
    off(eventName) {
      if (this.eventRegistry[eventName]) {
        this.socket.off(eventName);
        this.eventRegistry[eventName] = false; // Mark this event as not having a listener
      }
    }
    /**
     * Checks if there is a listener registered for the specified event name.
     * @param {string} eventName - The name of the event to check.
     * @returns {boolean} - Returns `true` if there is a listener registered for the event, `false` otherwise.
     */
    checkListener(eventName) {
      return this.eventRegistry[eventName] ? true : false;
    }

    /**
     * Ensures that the specified event listener is registered.
     *
     * @param {string} eventName - The name of the event.
     * @param {Function} handler - The event handler function.
     */
    ensureListener(eventName, handler) {
      if (this.checkListener(eventName) === false) {
          this.on(eventName, handler);
      }
    }

    /**
     * Sets the peers for the current instance.
     *
     * @param {Number} peers - Increase or decrease the number of peers.
     */
    setPeers(peers) {
      this.peers = peers;
      this.socket.emit("setPeers", this.room, peers);
    }

    /**
     * Handles the ICE candidate received from a remote peer.
     *
     * @param {string} id - The ID of the remote peer.
     * @param {RTCIceCandidate} candidate - The ICE candidate received from the remote peer.
     */
    handleCandidate(id, candidate) {
      this.peerConnections[id].addIceCandidate(new RTCIceCandidate(candidate)).catch(e => this.toast(e, "error"));
    }

    /**
     * Handles the answer received from a peer.
     *
     * @param {string} id - The ID of the peer.
     * @param {RTCSessionDescription} description - The answer description received from the peer.
     */
    handleAnswer(id, description) {
      if (this.peerConnections[id].signalingState === "have-local-offer") {
        this.peerConnections[id].setRemoteDescription(description);
      }
    }

    /**
     * Handles the watch operation for a given ID.
     *
     * @param {string} id - The ID of the watch operation.
     * @returns {void}
     */
    handleWatch(id) {
      const peerConnection = new RTCPeerConnection(this.config);
          this.peerConnections[id] = peerConnection;

          this.stream.getTracks().forEach(track => peerConnection.addTrack(track, this.stream));
          this.setPeers(1);

          peerConnection.onicecandidate = event => {
            if (event.candidate) {
              this.socket.emit("candidate", id, event.candidate);
            }
          };

          peerConnection.oniceconnectionstatechange = () => {
            this.toast(`Connection to ${id} is ${peerConnection.iceConnectionState}`, "info");
            if (peerConnection.iceConnectionState === "disconnected") {
              this.setPeers(-1);
            }
          };

          peerConnection
            .createOffer()
            .then(sdp => peerConnection.setLocalDescription(sdp))
            .then(() => {
              this.socket.emit("offer", id, peerConnection.localDescription);
            });
    }

    /**
     * Handles the client connection and sets up the RTCPeerConnection.
     * @param {string} id - The ID of the client.
     */
    handleClient(id) {
      const peerConnection = new RTCPeerConnection(this.config);
          this.peerConnections[id] = peerConnection;
          if (this.provFileshare || this.type === "fileshare") {
              this.dataChannels[id] = peerConnection.createDataChannel("fileshare");
              this.dataChannels[id].binaryType = 'arraybuffer';
          }

          peerConnection.onicecandidate = event => {
            if (event.candidate) {
              this.socket.emit("candidate", id, event.candidate);
            }
          };

          peerConnection.oniceconnectionstatechange = () => {
            this.toast(`Connection to ${id} is ${peerConnection.iceConnectionState}`, "info");
          };

          peerConnection
            .createOffer()
            .then(sdp => peerConnection.setLocalDescription(sdp))
            .then(() => {
              this.socket.emit("offer", id, peerConnection.localDescription);
            });
    }
    /**
     * Sets the upload speed for each peer connection.
     */
    setUploadSpeed() {
      const currentTime = new Date().getTime();
      Object.entries(this.peerConnections).forEach(([, pc], index) => {
        if (!this.stats.uploads[index]) {
          this.stats.uploads[index] = {bytes: 0, timestamp: currentTime};
        }
        const uploadStats = this.stats.uploads[index];
        pc.getStats(null).then(stats => {
          stats.forEach(report => {
            if (report.type === 'candidate-pair' && report.bytesSent !== 0) {
              const timeDiff = currentTime - uploadStats.timestamp;
              if (timeDiff > 1000) {
                const bytesDiff = report.bytesSent - uploadStats.bytes;
                uploadStats.lastbytes = uploadStats.bytes;
                uploadStats.bytes = report.bytesSent;
                uploadStats.lasttimestamp = uploadStats.timestamp;
                uploadStats.timestamp = currentTime;
                uploadStats.uploadspeed = Math.round((bytesDiff * 8) / (timeDiff / 1000));
              }
            }
          });
        });
      });

      this.stats.sumUploadSpeed = Object.values(this.stats.uploads).reduce((sum, {uploadspeed = 0}) => sum + uploadspeed, 0);
      if (isFinite(this.stats.sumUploadSpeed)) {
        this.statsCallback(this.stats);
      }
    }
    setProgressUpload(value, filename, filesize, id) {
      if (this.currentUploads[filename] === undefined) {
        this.currentUploads[filename] = {};
        this.currentUploads[filename][id] = 0;
      }
      this.currentUploads[filename][id] = value;
      let sumTransfered = 0;
      for (const [_, transfered] of Object.entries(this.currentUploads[filename])) {
        sumTransfered += transfered;
      }
      this.progressUploadCallback(filename, sumTransfered, filesize);
    }
    /**
     * Adjusts the chunk size based on the buffered amount.
     *
     * @param {number} bufferedAmount - The amount of data buffered in bytes.
     * @returns {number} The adjusted chunk size in bytes.
     */
    adjustChunkSize(bufferedAmount) {
      if (bufferedAmount < 1 * 1024 * 1024) { // Less than 1MB
        return 64 * 1024; // Increase chunk size
      } else if (bufferedAmount < 4 * 1024 * 1024) { // Less than 4MB
        return 32 * 1024; // Slightly increase chunk size
      } else {
        return 16 * 1024; // Decrease chunk size to avoid congestion
      }
    }

    /**
     * Sets up the event handlers for the data channel used for uploading files.
     *
     * @param {string} id - The ID of the data channel.
     * @param {File} transferFile - The file to be transferred.
     */
    setupDataChannelUploadEvents(id, transferFile) {
      // Set the bufferedAmountLowThreshold to the default value
      this.dataChannels[id].bufferedAmountLowThreshold = this.DEFAULT_BUFFERED_AMOUNT_LOW_THRESHOLD; // 64KB

      // Event handler for when the buffered amount becomes low
      this.dataChannels[id].onbufferedamountlow = async () => {
      // Get the stats of the peer connection
      const stats = await this.peerConnections[id].getStats();
      stats.forEach(report => {
        // Check if the candidate pair is succeeded and the round trip time is below 250ms
        if (report.type === 'candidate-pair' && report.state === 'succeeded') {
          if ((report.currentRoundTripTime === undefined || report.currentRoundTripTime < 250) &&
            this.dataChannels[id].bufferedAmount < this.dataChannels[id].bufferedAmountLowThreshold) {
            // Double the bufferedAmountLowThreshold
            this.dataChannels[id].bufferedAmountLowThreshold *= 2;
            // Clamp the bufferedAmountLowThreshold between the minimum and maximum values
            this.dataChannels[id].bufferedAmountLowThreshold = Math.max(this.MIN_BUFFERED_AMOUNT_LOW_THRESHOLD, Math.min(this.dataChannels[id].bufferedAmountLowThreshold, this.MAX_BUFFERED_AMOUNT_LOW_THRESHOLD)); // Between 16KB and 1MB
          }
        }
      });
      };

      // Event handler for when the data channel is open
      this.dataChannels[id].onopen = () => {
      // Increase the current number of peers
      this.setPeers(1);
      this.toast(`Data Channel from ${id} is open. Start to send file ${transferFile.name}`, "info");

      let fileReader = new FileReader();
      let offset = 0;
      let dynamicChunkSize = this.INITIAL_CHUNK_SIZE; // Initial chunk size

      // Function to adjust the buffer threshold
      const adjustBufferThreshold = () => {
        this.dataChannels[id].bufferedAmountLowThreshold /= 2;
        this.dataChannels[id].bufferedAmountLowThreshold = Math.max(this.MIN_BUFFERED_AMOUNT_LOW_THRESHOLD, Math.min(this.dataChannels[id].bufferedAmountLowThreshold, this.MAX_BUFFERED_AMOUNT_LOW_THRESHOLD));
      };

      // Function to wait for the buffer to decrease
      const waitForBufferDecrease = async () => {
        while (this.dataChannels[id].bufferedAmount > this.dataChannels[id].bufferedAmountLowThreshold) {
          await new Promise(resolve => setTimeout(resolve, 100));
          if (this.dataChannels[id].bufferedAmount > this.dataChannels[id].bufferedAmountLowThreshold) adjustBufferThreshold();
        }
      };

      // Event listener for when the file is loaded
      fileReader.addEventListener('load', async (e) => {
        await waitForBufferDecrease();
        dynamicChunkSize = this.adjustChunkSize(this.dataChannels[id].bufferedAmount);
        // Set the upload speed with callback to frontend
        this.setUploadSpeed();
        // Set the progress of the upload with callback to frontend
        this.setProgressUpload(offset, transferFile.name, transferFile.size, id);
        try {
          this.dataChannels[id].send(e.target.result);
        } catch (error) {
          this.toast(`Error sending file ${error}`, "error");
        }
        offset += e.target.result.byteLength;
        if (offset < transferFile.size) {
          readSlice(offset);
        } else {
          this.toast(`File ${transferFile.name} with ${transferFile.size / 1024 / 1024 / 8} MB transferred to ${id}`, "success");
          this.dataChannels[id].close();
          this.dataChannels[id] = null;
        }
      });

      // Event listener for file reading error
      fileReader.addEventListener('error', error => this.toast(`Error reading file ${error}`, "error"));
      // Event listener for file reading abort
      fileReader.addEventListener('abort', event => this.toast(`File reading aborted: ${event}`, "info"));
      // Function to read a slice of the file
      const readSlice = (o) => {
        const slice = transferFile.slice(o, o + dynamicChunkSize);
        fileReader.readAsArrayBuffer(slice);
      };
      readSlice(0);
      };
      // Event handler for when a message is received (currently not used)
      this.dataChannels[id].onmessage =  () => {};
      // Event handler for when an error occurs - decrease the number of peers
      this.dataChannels[id].onerror = (error) => {
          this.setPeers(-1);
          this.toast("Data Channel Error: " + error, "error");
      };
      // Event handler for when the data channel is closed - decrease the number of peers
      this.dataChannels[id].onclose = () => {
          this.setPeers(-1);
          this.toast(`Data Channel  from ${id} closed`, "info");
      };
    }

    handleDownloadFile(id, file) {
      let transferFile = this.findTransferFile(file);
      if (!transferFile) {
        this.toast(`File ${file} not found`, "error");
        return;
      }
      this.setupDataChannelUploadEvents(id, transferFile);
    }

  }

  class Client extends RTC {
    /**
     * Creates a new instance of the class.
     * @param {Socket} socket - The socket object.
     * @param {Object} config - The configuration object.
     * @param {string} type - The type of the instance.
     * @param {string} room - The room identifier.
     * @param {number} slots - The number of slots available.
     */
    constructor(socket, config, type, room, slots) {
      super(socket, config);
      this.type = type;
      this.room = room;
      this.files = {};
      this.rehostFiles = {};
      this.slots = slots;
      this.peers = 0;
      this.stats = {uploads: {}, downloads: {}, sumUploadSpeed: 0, sumDownloadSpeed: 0};
      this.getFilesCallback = function() {};
      this.streamCallback = function() {};

      this.socket.on("connect", () => {

        if (this.type === "stream") {
          this.socket.emit("watch", this.room, (response) => {
            if (response.host !== undefined) {
              this.host = response.host;
              this.toast(`Connected to ${response.host}`, "info");
            } else {
              this.toast(response.message, "error");
            }
          });
        }

        // RESHARE AS HOST

        this.ensureListener('answer', (id, description) => this.handleAnswer(id, description));

        if (this.type === "stream") {
          setInterval(this.setUploadSpeed.bind(this), 1000);
          setInterval(this.setDownloadSpeed.bind(this), 1000);

          this.ensureListener('watch', id => this.handleWatch(id));
        }

        this.ensureListener('client', id => this.handleClient(id));
        this.ensureListener('candidate', (id, candidate) => this.handleCandidate(id, candidate));

        // END RESHARE AS HOST

        this.ensureListener("offer", (id, description) => this.handlerOffer(id, description));
        this.ensureListener('getFiles', () => this.getFiles());

        this.getFiles();
      });
    }
    /**
     * Sets the media stream for the current instance.
     *
     * @param {MediaStream} stream - The media stream to set.
     */
    setStream(stream) {
      if (!(stream instanceof MediaStream)) return;
      this.stream = stream;
      this.socket.emit("stream", this.room, this.host);
      this.socket.emit("setSlots", this.room, this.slots);
    }
    /**
     * Updates the sharing files and emits the necessary events.
     *
     * @param {Object} files - The files to be shared.
     */
    updateSharingFiles(files) {
      Object.entries(files).forEach(([name, value]) => {
        this.socket.emit("offerFile", this.room, {name: name, size: value.size});
        this.socket.emit("setSlots", this.room, this.slots);
      });
      this.ensureListener("downloadFile", (id, file) => this.handleDownloadFile(id, file));
    }
    /**
     * Sets the progress of a download for a given filename.
     *
     * @param {number} value - The progress value to set.
     * @param {string} filename - The name of the file to update the progress for.
     */
    setProgressDownload(value, filename) {
      document.getElementById(filename + "-download").value = value;
    }
    /**
     * Finds a transfer file by its name.
     * @param {string} file - The name of the file to find.
     * @returns {File|null} - The found file object, or null if not found.
     */
    findTransferFile(file) {
      for (const [_, inputfile] of Object.entries(this.rehostFiles)) {
          if (inputfile.name === file) {
            return {name: inputfile.name, size: inputfile.size, slice: inputfile.blob.slice.bind(inputfile.blob)};
          }
      }
      return null;
    }

    /**
     * Handles the offer received from a peer and establishes a connection.
     * @param {string} id - The ID of the peer.
     * @param {RTCSessionDescription} description - The offer description received from the peer.
     */
    handlerOffer(id, description) {
      this.peerConnections[id] = new RTCPeerConnection(this.config);
          let receiveBuffer = [];
          let receivedSize = 0;
          this.peerConnections[id].oniceconnectionstatechange = () => {
            this.toast(`Connection to ${id} is ${this.peerConnections[id].iceConnectionState}`, "info");
            if (this.peerConnections[id].iceConnectionState === "disconnected" && this.type === "stream") {
              this.socket.emit("watch", this.room, (response) => {
                if (response.host !== undefined) {
                  this.host = response.host;
                  this.toast(`Connected to ${response.host}`, "info");
                } else {
                  this.toast(response.message, "error");
                }
              });
            }
          };
          if (this.type === "stream") {
            this.peerConnections[id].ontrack = (event) => {
              this.toast(`Stream from ${id} is available`, "info");
              this.streamCallback(event.streams[0]);
              this.stream = event.streams[0];
            };
          }
          if (this.type === "fileshare") {
            this.peerConnections[id].ondatachannel = function (event) {
              let channel = event.channel;
              channel.binaryType = 'arraybuffer';
              channel.onopen = function () {
                    //channel.send('ANSWEREROPEN');
                };
              channel.onmessage = function (event) {
                receiveBuffer.push(event.data);
                receivedSize += Number(event.data.byteLength);
                let file = this.file;
                this.setProgressDownload(receivedSize, file.name);
                this.setDownloadSpeed();
                if (receivedSize === file.size) {
                  const received = new Blob(receiveBuffer);
                  this.rehostFiles[file.name] = {name: file.name, size: file.size, blob: received};
                  this.updateSharingFiles(this.rehostFiles);
                  receiveBuffer = [];
                  receivedSize = 0;
                  this.browserDownload(received, file.name);
                  channel.close();
                  this.peerConnections[id].close();
                }
              }.bind(this);
            }.bind(this);
          }
          this.peerConnections[id]
            .setRemoteDescription(description)
            .then(() => this.peerConnections[id].createAnswer())
            .then((sdp) => this.peerConnections[id].setLocalDescription(sdp))
            .then(() => {
              this.socket.emit("answer", id, this.peerConnections[id].localDescription);
            });
          this.peerConnections[id].onicecandidate = (event) => {
            if (event.candidate) {
              this.socket.emit("candidate", id, event.candidate);
            }
          };
    }


    /**
     * Handles the offer file by creating a download link for the file.
     * @param {File} file - The file to be handled.
     */
    handleOfferFile(file) {
      this.file = file;
      const a = document.createElement("a");
      a.innerText = file.name;
      a.href = "#";
      a.setAttribute("data-size", file.size);
      a.setAttribute("data-name", file.name);
      a.addEventListener("click", () => {
          this.downloadFile(file);
      });
      document.body.appendChild(a);
    }
    /**
     * Retrieves the file.
     * @returns {void}
     */
    getFile() {
        this.ensureListener('offerFile', (file) => this.handleOfferFile(file));
    }
    /**
     * Retrieves the files associated with the current room from the server.
     *
     * @returns {void}
     */
    getFiles() {
      this.socket.emit("getFiles", this.room, (files) => {
        this.files = files;
        this.getFilesCallback(files);
      });
    }
    /**
     * Downloads a file from the peer.
     *
     * @param {string} file - The name of the file to download.
     */
    downloadFile(file) {
        this.socket.emit("client", this.room, file, (response) => {
            for (const [key, value] of Object.entries(this.files)) {
                if (key === file) {
                    this.file = {name: key, size: value.size};
                }
            }
            if (response.host !== undefined) {
              this.toast(`File ${file} is downloading from ${response.host}`, "info");
              this.socket.emit("downloadFile", this.room, file, response.host);
            } else {
              this.toast(response.message, "error");
            }
        });
    }
    /**
     * Downloads a file in the browser.
     *
     * @param {Blob} blob - The file data to be downloaded.
     * @param {string} fileName - The name of the file to be downloaded.
     */
    browserDownload(blob, fileName) {
      this.toast(`File ${fileName} downloaded`, "success");
      const a = document.createElement('a');
      const url = window.URL.createObjectURL(blob);
      a.href = url;
      a.download = fileName;
      a.click();
      window.URL.revokeObjectURL(url);
      a.remove();
      this.getFiles();
    }

    /**
     * Sets the download speed for each peer connection and calculates the sum of download speeds.
     */
    setDownloadSpeed() {
      if (this.peerConnections !== undefined) {
        Object.entries(this.peerConnections).forEach((entry, index) => {
          if (this.stats.downloads[index] === undefined) {
            this.stats.downloads[index] = {bytes: 0, timestamp: new Date().getTime()};
          }
          entry[1].getStats(null).then(res => {
            res.forEach(report => {
                if (report.type === 'candidate-pair') {

                  this.stats.downloads[index].lastbytes = this.stats.downloads[index].bytes;
                  this.stats.downloads[index].lasttimestamp =  this.stats.downloads[index].timestamp;

                  if (report.bytesReceived !== 0 && (new Date().getTime() - this.stats.downloads[index].timestamp) > 1000) {
                    this.stats.downloads[index].bytes = report.bytesReceived;
                    this.stats.downloads[index].timestamp = new Date().getTime();
                    this.stats.downloads[index].downloadspeed = Math.round(((this.stats.downloads[index].bytes - this.stats.downloads[index].lastbytes) * 8) / ((this.stats.downloads[index].timestamp - this.stats.downloads[index].lasttimestamp) / 1000));
                  }
                }
              });
            });
        });
        this.stats.sumDownloadSpeed = 0;
        Object.values(this.stats.downloads).forEach((download) => {
          this.stats.sumDownloadSpeed += download.downloadspeed;
        });
        if (isFinite(this.stats.sumDownloadSpeed)) {
          this.statsCallback(this.stats);
        }
    }
  }
  }

  class Host extends RTC {
    constructor(socket, config, type, slots) {
      super(socket, config);
      this.provFileshare = false;
      this.provStream = false;
      this.fileinputs = [];
      this.room = "";
      this.slots = slots;
      this.stats = {uploads: {}, sumUploadSpeed: 0, download_current_bytes: [], download_last_bytes: [], upload_current_bytes: [], upload_last_bytes: []};
      this.currentPeersCallback = function() {};
      this.currentFilePeersCallback = function() {};

      this.socket.on("connect", () => {

        socket.emit('host', this.slots, (response => {
            this.room = response;
        }).bind(this));

        this.ensureListener('answer', (id, description) => this.handleAnswer(id, description));
        this.ensureListener('watch', id => this.handleWatch(id));
        this.ensureListener('client', id => this.handleClient(id));
        this.ensureListener('candidate', (id, candidate) => this.handleCandidate(id, candidate));
        this.ensureListener('disconnectPeer', id => this.handleDisconnectPeer(id));
        this.ensureListener('currentPeers', peers => this.currentPeersCallback(peers));
        this.ensureListener('currentFilePeers', (filename, peers) => this.currentFilePeersCallback(filename, peers));

      });
    }

    /**
     * Handles the disconnection of a peer.
     *
     * @param {string} id - The ID of the peer to disconnect.
     */
    handleDisconnectPeer(id) {
      this.peerConnections[id].close();
      delete this.peerConnections[id];
    }

    /**
     * Sets the stream for the current instance.
     *
     * @param {MediaStream} stream - The stream to set.
     * @returns {void}
     */
    setStream(stream) {
      this.provStream = true;
      this.stream = stream;
      this.socket.emit("stream", this.room);
      setInterval(this.setUploadSpeed.bind(this), 1000);
    }

    /**
     * Sets the slots for the current instance.
     *
     * @param {Array} slots - The array of slots to set.
     */
    setSlots(slots) {
        this.slots = slots;
        this.socket.emit("setSlots", this.room, slots);
    }

    /**
     * Sets the file input for the class.
     * @param {FileInput} fileinput - The file input to be set.
     */
    setFileInput(fileinput) {
        this.fileinputs.push(fileinput);
    }
    /**
     * Deletes a file.
     * @param {string} filename - The name of the file to be deleted.
     */
    deleteFile(filename) {
      this.socket.emit("deleteFile", filename);
    }

    /**
     * Sends an offer for a file to the server.
     *
     * @param {File} file - The file to be offered.
     */
    offerFile(file) {
        this.provFileshare = true;
        this.socket.emit("offerFile", this.room, file);
        this.ensureListener("downloadFile", (id, file) => this.handleDownloadFile(id, file));
    }

    /**
     * Finds a transfer file by its name.
     * @param {string} file - The name of the file to find.
     * @returns {File|null} - The found file object, or null if not found.
     */
    findTransferFile(file) {
      for (let input of this.fileinputs) {
        for (let inputfile of input.files) {
          if (inputfile.name === file) {
            return inputfile;
          }
        }
      }
      return null;
    }

    /**
     * Get the room associated with this instance.
     * @returns {string} The room name.
     */
    getRoom() {
        return this.room;
    }
    /**
     * Creates a meeting with the specified settings.
     * @param {Object} settings - The settings for the meeting.
     */
    createMeeting(settings) {
      this.socket.emit("createMeeting", this.room, this.host, settings);
    }
  }

  class Meet extends RTC {
      constructor(socket, config, room) {
        super(socket, config);
        this.room = room;
        this.callbackParticipantJoined = function() {};
        this.callbackMessage = function() {};
        this.participants = {};
      }
      getMeetingSettings(callback) {
        this.socket.emit("getMeetingSettings", this.room, callback);
        this.settings = callback.settings;
      }
      handleParticipantJoined(participant) {
        this.toast(`Participant ${participant.name} joined the meeting`, "info");
        this.handleParticipant(participant.id);
        this.callbackParticipantJoined(participant, this.peerConnections[participant.id]);
      }

      handleMessage(id, type, message) {
          if (this.participants[id] !== undefined) {
            this.callbackMessage(id, this.participants[id].name, type, message);
          }
      }

      sendMessage(type, message = "") {
        this.socket.emit("message", this.room, type, message);
      }

      /**
     * Sets the media stream for the current instance.
     *
     * @param {MediaStream} stream - The media stream to set.
     */
    setStream(stream) {
      if (!(stream instanceof MediaStream)) return;
      this.stream = stream;
      this.socket.emit("message", this.room, "mediaDevice", stream.id);
      this.join(this.name, function() {});
      /*Object.entries(this.peerConnections).forEach(([id, peerConnection]) => {
        stream.getTracks().forEach(track => peerConnection.addTrack(track, stream));

        console.log("set stream", peerConnection);

        /*peerConnection
        .createOffer({iceRestart: true})
        .then(sdp => peerConnection.setLocalDescription(sdp))
        .then(() => {
          this.socket.emit("message", this.room, "mediaDevice", stream.id);
          this.socket.emit("offer", id, peerConnection.localDescription);
        }).catch(error => {
          this.toast(`Error creating offer or setting local description: ${error}`, "error");
          // Handle the error appropriately
        });*/
      //});
    }
  
      /**
       * Joins the meeting.
       */
      join(name, callback) {
        this.name = name;
        //this.ensureListener('participantJoined', (participant) => this.getParticipants());
        this.ensureListener("offer", (id, description) => this.handleOffer(id, description));
        this.ensureListener('answer', (id, description) => this.handleAnswer(id, description));
        this.ensureListener('candidate', (id, candidate) => this.handleCandidate(id, candidate));
        this.ensureListener('message', (id, type, message) => this.handleMessage(id, type, message));
        
        this.socket.emit("joinMeeting", this.room, name, (response) => {
          this.id = response.id;
          Object.entries(response.participants).forEach(([id, participant]) => {
            if (id !== this.id) this.handleParticipant(id);
            console.log(`connect from ${this.id} to ${id}`);
          });
          callback(response);
          console.log(this.peerConnections);
         });
      }
  
      /**
       * Handles the meet operation for a given ID.
       *
       * @param {string} id - The ID of the meet operation.
       * @returns {void}
       */
      handleParticipant(id) {
        //if (this.peerConnections[id] !== undefined) return;
        console.log("handleParticipant", id);
        const peerConnection = new RTCPeerConnection(this.config);
        this.peerConnections[id] = peerConnection;

        console.log("SET STREAM", this.stream);
  
        this.stream.getTracks().forEach(track => peerConnection.addTrack(track, this.stream));

        if (this.screenShareStream) {
          console.log("SET STREAM", this.screenShareStream);
          this.screenShareStream.getTracks().forEach(track => peerConnection.addTrack(track, this.screenShareStream));
        }

        //peerConnection.getTracks().forEach(track => console.log("track", track));
  
        peerConnection.onicecandidate = event => {
          if (event.candidate) {
            this.socket.emit("candidate", id, event.candidate);
          }
        };
  
        peerConnection.oniceconnectionstatechange = () => {
          this.toast(`Connection to ${id} is ${peerConnection.iceConnectionState}`, "info");
          if (peerConnection.iceConnectionState === "connected") {
            this.getParticipants();
          }
        };

       this.peerConnections[id].ontrack = (event) => {
          //let stream = new MediaStream([event.track]);
          console.log("ontrack", event, event.streams, event.track);
          this.toast(`Stream from ${id} is available`, "info");
          this.getParticipants().then(() => {

            if (!this.participants[id].streams.some(stream => stream.id === event.streams[0].id)) {
              this.participants[id].streams.push(event.streams[0]);
            } else {
              this.participants[id].streams = this.participants[id].streams.map(stream => {
                if (stream.id === event.streams[0].id) {
                  return event.streams[0];
                }
                return stream;
              });
            }
            if (!this.participants[id].tracks.some(track => track.id === event.track.id)) {
              this.participants[id].tracks.push(event.track);
            } else {
              this.participants[id].tracks = this.participants[id].tracks.map(track => {
                if (track.id === event.track.id) {
                  return event.track;
                }
                return track;
              });
            }

            this.callbackParticipantJoined(this.participants[id]);
          });
        };
  
        peerConnection
          .createOffer()
          .then(sdp => peerConnection.setLocalDescription(sdp))
          .then(() => {
            this.socket.emit("offer", id, peerConnection.localDescription);
          }).catch(error => {
            this.toast(`Error creating offer or setting local description: ${error}`, "error");
            // Handle the error appropriately
          });
      }
      getParticipants() {
        return new Promise((resolve, reject) => {
          this.socket.emit("getParticipants", this.room, (response) => {
            if (response.error) {
              reject(response.error);
            } else {
              Object.entries(response.participants).forEach(([id, participant]) => {
                if (!Object.prototype.hasOwnProperty.call(this.participants, id)) {
                  this.participants[id] = participant;
                  this.participants[id].peerConnection = this.peerConnections[id];
                  this.participants[id].streams = [];
                  this.participants[id].tracks = [];
                }
              });
              resolve(this.participants);
            }
          });
        });
      }
  
      /**
       * Handles the offer received from a peer and establishes a connection.
       * @param {string} id - The ID of the peer.
       * @param {RTCSessionDescription} description - The offer description received from the peer.
       */
      handleOffer(id, description) {
        console.log("my id", this.id, "offer from ", id);
        this.peerConnections[id] = new RTCPeerConnection(this.config);

        this.peerConnections[id].ontrack = (event) => {
          //let stream = new MediaStream([event.track]);
          console.log("ontrack", event, event.streams, event.track);
          this.toast(`Stream from ${id} is available`, "info");
          this.getParticipants().then(() => {

            if (!this.participants[id].streams.some(stream => stream.id === event.streams[0].id)) {
              this.participants[id].streams.push(event.streams[0]);
            } else {
              this.participants[id].streams = this.participants[id].streams.map(stream => {
                if (stream.id === event.streams[0].id) {
                  return event.streams[0];
                }
                return stream;
              });
            }
            if (!this.participants[id].tracks.some(track => track.id === event.track.id)) {
              this.participants[id].tracks.push(event.track);
            } else {
              this.participants[id].tracks = this.participants[id].tracks.map(track => {
                if (track.id === event.track.id) {
                  return event.track;
                }
                return track;
              });
            }

            this.callbackParticipantJoined(this.participants[id]);
          });
        };

        this.peerConnections[id].oniceconnectionstatechange = () => {
          this.toast(`Connection to ${id} is ${this.peerConnections[id].iceConnectionState}`, "info");
          /*if (this.peerConnections[id].iceConnectionState === "disconnected") {
            this.socket.emit("meeting", this.room, (response) => {
              if (response.host !== undefined) {
                this.host = response.host;
                this.toast(`Connected to ${response.host}`, "info");
              } else {
                this.toast(response.message, "error");
              }
            });
          }*/
          /*if (this.peerConnections[id].iceConnectionState === "connected") {
            this.peerConnections[id].onaddtrack = (event) => {
              console.log("onaddtrack", event.streams);
            };
          }*/
        };


        if (this.peerConnections[id].signalingState === "stable") {

          this.stream.getTracks().forEach(track => this.peerConnections[id].addTrack(track, this.stream));

          console.log("SET STREAM", this.stream);
  
        if (this.screenShareStream) {
          console.log("SET STREAM", this.screenShareStream);
          this.screenShareStream.getTracks().forEach(track => this.peerConnections[id].addTrack(track, this.screenShareStream));
        }

          this.getParticipants();
          this.peerConnections[id]
            .setRemoteDescription(description)
            .then(() => this.peerConnections[id].createAnswer())
            .then((sdp) => this.peerConnections[id].setLocalDescription(sdp))
            .then(() => {
              this.socket.emit("answer", id, this.peerConnections[id].localDescription);
            });
        }
        this.peerConnections[id].onicecandidate = (event) => {
          if (event.candidate) {
            this.socket.emit("candidate", id, event.candidate);
          }
        };
      }
  
      /**
       * Leaves the meeting.
       */
      leaveMeeting() {
        this.socket.emit("leaveMeeting", this.room);
      }
      setScreenShareStream(stream) {
        if (!(stream instanceof MediaStream)) return;
        this.screenShareStream = stream;
        this.socket.emit("message", this.room, "screenshare", stream.id);
        /*Object.entries(this.peerConnections).forEach(([id, peerConnection]) => {
            stream.getTracks().forEach(track => peerConnection.addTrack(track, stream));
          peerConnection
          .createOffer({iceRestart: true})
          .then(sdp => peerConnection.setLocalDescription(sdp))
          .then(() => {
            //this.socket.emit("message", this.room, "screenshare", stream.id);
            this.socket.emit("offer", id, peerConnection.localDescription);
          }).catch(error => {
            this.toast(`Error creating offer or setting local description: ${error}`, "error");
            // Handle the error appropriately
          });
        });*/
      }
    }

  /**
   * Represents a class that crops and resizes a media stream.
   *
    * @param {Stream} stream - The input stream.
    * @param {number} x - The x-coordinate.
    * @param {number} y - The y-coordinate.
    * @param {number} right - The right boundary.
    * @param {number} bottom - The bottom boundary.
    * @param {number} width - The width.
    * @param {number} height - The height.
    * @param {boolean} crop - Whether to crop the image.
    * @param {boolean} resize - Whether to resize the image.
    */
  class MediaStreamCropperResizer {
    constructor(stream, x, y, right, bottom, width, height, crop, resize) {
      this.stream = stream;
      this.x = x;
      this.y = y;
      this.right = right;
      this.bottom = bottom;
      this.width = width;
      this.height = height;
      this.crop = crop;
      this.resize = resize;
      this.outputStream = null;
      this.processStream();
    }

    processStream() {
      const [track] = this.stream.getTracks();
      if (!track || typeof MediaStreamTrackProcessor === 'undefined' || typeof MediaStreamTrackGenerator === 'undefined' || typeof VideoFrame === 'undefined' || typeof VideoDecoder === 'undefined' || typeof VideoEncoder === 'undefined') {
        throw new Error('Cannot process stream. Make sure the browser supports the necessary APIs.');
      }

      const processor = new MediaStreamTrackProcessor({track});
      const generator = new MediaStreamTrackGenerator({kind: 'video'});

      const {readable} = processor;
      const {writable} = generator;

      this.outputStream = new MediaStream([generator]);

      const transform = (frame, controller) => {
          let x = 0;
          let y = 0;
          let widthCrop = frame.displayWidth;
          let heightCrop = frame.displayHeight;
          let displayWidth = frame.displayWidth;
          let displayHeight = frame.displayHeight;
          if (this.crop) {
              x = Number(this.x);
              y = Number(this.y);
              widthCrop = widthCrop - Number(this.right) - Number(this.x);
              heightCrop = heightCrop - Number(this.bottom) - Number(this.y);
          }
          if (this.resize) {
              displayWidth = this.width;
              displayHeight = this.height;
          }
          const newFrame = new VideoFrame(frame, {
              visibleRect: {
                  x: x,
                  width: widthCrop,
                  y: y,
                  height: heightCrop,
              },
              displayWidth: displayWidth,
              displayHeight: displayHeight
          });
          controller.enqueue(newFrame);
          frame.close();
      };

    const processFrame = async () => {
      readable.pipeThrough(new TransformStream({transform})).pipeTo(writable);
    };
    processFrame();
  }

    getProcessedStream() {
      return this.outputStream;
    }
  }

  export { Client, Host, Meet, MediaStreamCropperResizer };