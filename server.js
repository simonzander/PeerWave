/**
 * Required modules
 */
const config = require('./config/config');
const express = require("express");
const { randomUUID } = require('crypto');
const http = require("http");
const app = express();


if (config.channels) {

  const authRoutes = require('./routes/auth');

  // Register and signin webpages
  app.use(authRoutes);
}

/**
 * Room data object to store information about each room
 * @typedef {Object} RoomData
 * @property {string} host - The ID of the host socket
 * @property {Object} seeders - Object containing information about seeders in the room
 * @property {boolean} stream - Indicates if the room is currently streaming
 * @property {Object} share - Object containing shared files in the room
 */

/**
 * Object to store information about each seeder in a room
 * @typedef {Object} SeederData
 * @property {number} slots - Number of available download slots for the seeder
 * @property {number} peers - Number of connected peers to the seeder
 * @property {number} level - Level of the seeder in the streaming hierarchy
 * @property {number} score - Score of the seeder based on level and number of peers
 */

/**
 * Callback function type
 * @callback Callback
 * @param {any} data - The data to be passed to the callback function
 */

const rooms = {};
const port = config.port || 4000;

const server = http.createServer(app);
const io = require("socket.io")(server);

/**
 * Handles the callback function by invoking it with the provided data.
 *
 * @param {Callback} callback - The callback function to be invoked.
 * @param {any} data - The data to be passed to the callback function.
 */
function callbackHandler(callback, data) {
  if (typeof callback === "function") {
    callback(data);
  }
}

app.use(express.static(__dirname + "/public"));

app.set("view engine", "pug");

/**
 * Route for a meeting
 */
app.get("/meet", (req, res) => {
  res.render("meet");
});

/**
 * Route for hosting a room
 */
app.get("/host", (req, res) => {
  res.render("host");
});

/**
 * Default route
 */
app.get("/", (req, res) => {
  res.render("about");
});

/**
 * Route for viewing a room
 * @param {string} room - The ID of the room to view
 */
app.get("/view/:room", ({ params: { room } }, res) => {
  res.render("view", { room });
});

/**
 * Route for join a meeting room
 * @param {string} room - The ID of the room to meet
 */
app.get("/meet/:room", ({ params: { room } }, res) => {
  res.render("meet", { room });
});

/**
 * Route for sharing a room
 * @param {string} room - The ID of the room to share
 */
app.get("/share/:room", ({ params: { room } }, res) => {
  res.render("share", { room });
});

io.sockets.on("error", e => console.log(e));
io.sockets.on("connection", socket => {

  /**
   * Event handler for hosting a room
   * @param {number} slots - Number of available download slots for the host
   * @param {Callback} callback - Callback function to be invoked with the room ID
   */
  socket.on("host", (slots, callback) => {
    const room = randomUUID();
    const seeders = {[socket.id]: {slots: Number(slots), peers: 0, level: 0, score: 100.0}};
    rooms[room] = {host: socket.id, seeders: seeders, stream: false, share: {}, meeting: false, meetingSettings: {}};

    socket.join(room);
    callbackHandler(callback, room);
  });

  /**
   * Event handler for connecting as a client to a room
   * @param {string} room - The ID of the room to connect to
   * @param {string} filename - The name of the file to download
   * @param {Callback} callback - Callback function to be invoked with the connection status
   */
  socket.on("client", (room, filename, callback) => {
    const roomData = rooms[room];
    if (!roomData || roomData.host === undefined) {
        if (typeof callback === "function") callback({message: "Room not found", room});
        return;
    }

    socket.join(room);
    const seeders = Object.entries(roomData.seeders);

    for (const [seeder, value] of seeders) {
        let fileSeeders;
        if (roomData.share.files[filename]) {
            fileSeeders = roomData.share.files[filename].seeders;
        }
        if (!fileSeeders || !fileSeeders.includes(seeder) || value.slots <= value.peers || seeder === socket.id) continue;

        socket.to(seeder).emit("client", socket.id);
        callbackHandler(callback, {message: "Client connected", room, host: seeder});
        socket.to(roomData.host).emit("currentPeers", Object.keys(roomData.seeders).length);
        return;
    }

    callbackHandler(callback, {message: "no available download slot, please try later", room});
  });

  /**
   * Event handler for watching a room
   * @param {string} room - The ID of the room to watch
   * @param {Callback} callback - Callback function to be invoked with the connection status
   */
  socket.on("watch", (room, callback) => {
    const roomData = rooms[room];
    if (!roomData || roomData.host === undefined || roomData.stream !== true) {
        callbackHandler(callback, {message: "Room not found", room});
        return;
    }

    socket.join(room);
    const seedersDesc = Object.entries(roomData.seeders).sort((a,b) => a.score > b.score);

    for (const [seeder, value] of seedersDesc) {
        if (value.slots <= value.peers || seeder === socket.id) continue;

        socket.to(seeder).emit("watch", socket.id);
        callbackHandler(callback, {message: "Client connected", room, host: seeder});
        socket.to(roomData.host).emit("currentPeers", Object.keys(roomData.seeders).length);
        return;
    }

    callbackHandler(callback, {message: "no available stream slot, please try later", room});
  });

  socket.on("negotiationneeded", (id) => {
    socket.to(id).emit("negotiationneeded", socket.id);
  });

  /**
   * Event handler for offering a WebRTC connection
   * @param {string} id - The ID of the recipient socket
   * @param {any} message - The offer message
   */
  socket.on("offer", (id, message) => {
    socket.to(id).emit("offer", socket.id, message);
  });

  socket.on("offerScreenshare", (id, message) => {
    socket.to(id).emit("offerScreenshare", socket.id, message);
  });

  /**
   * Event handler for answering a WebRTC connection
   * @param {string} id - The ID of the recipient socket
   * @param {any} message - The answer message
   */
  socket.on("answer", (id, message) => {
    socket.to(id).emit("answer", socket.id, message);
  });

  socket.on("answerScreenshare", (id, message) => {
    socket.to(id).emit("answerScreenshare", socket.id, message);
  });

  /**
   * Event handler for sending ICE candidate information
   * @param {string} id - The ID of the recipient socket
   * @param {any} message - The ICE candidate message
   */
  socket.on("candidate", (id, message) => {
    socket.to(id).emit("candidate", socket.id, message);
  });

  socket.on("candidateScreenshare", (id, message) => {
    socket.to(id).emit("candidateScreenshare", socket.id, message);
  });

  /**
   * Event handler for disconnecting from a room
   */
  socket.on("disconnect", () => {
    if (!rooms) return;


    Object.keys(rooms).forEach((room) => {
        const roomSeeders = rooms[room].seeders;
        const roomFiles = rooms[room].share && rooms[room].share.files;
        const roomParticipants = rooms[room].participants;

        if (roomParticipants && roomParticipants[socket.id]) {
          delete roomParticipants[socket.id];
          socket.to(room).emit("message", socket.id, "leave", "");
          const hourFuture = new Date(Date.now() + 60 * 60 * 1000).getTime();
          const meetingTime = new Date(rooms[room].meetingSettings.meetingDate).getTime();
          if (Object.keys(roomParticipants).length === 0 && hourFuture < meetingTime) {
            delete rooms[room];
          }
        }

        if (!roomSeeders) return;

        if (roomSeeders[socket.id]) {
            delete roomSeeders[socket.id];
            socket.to(rooms[room].host).emit("currentPeers", Object.keys(roomSeeders).length - 1);
        }

        if (!roomFiles) return;

        Object.keys(roomFiles).forEach((file) => {
            const fileSeeders = roomFiles[file].seeders;
            const socketIndex = fileSeeders.indexOf(socket.id);

            if (socketIndex !== -1) {
                fileSeeders.splice(socketIndex, 1);
                socket.to(rooms[room].host).emit("currentFilePeers", file, Object.keys(fileSeeders).length);
            }

            if (fileSeeders.length === 0) {
                delete roomFiles[file];
            }
        });

        socket.to(room).emit("getFiles", roomFiles);
    });
  });

  /**
   * Event handler for setting the number of download slots for a seeder
   * @param {string} room - The ID of the room
   * @param {number} slots - The number of download slots
   */
  socket.on("setSlots", (room, slots) => {
    if (!rooms[room]) return;

    const seeder = rooms[room].seeders[socket.id] || (rooms[room].seeders[socket.id] = { peers: 0, slots: 0 });

    seeder.slots = Number(slots);
  });

  /**
   * Event handler for setting the number of connected peers for a seeder
   * @param {string} room - The ID of the room
   * @param {number} peers - The number of connected peers
   */
  socket.on("setPeers", (room, peers) => {
    if (!rooms[room]) return;

    const seeder = rooms[room].seeders[socket.id] || (rooms[room].seeders[socket.id] = { peers: 0 });

    seeder.peers += peers;
    if (seeder.peers < 0) seeder.peers = 0;

    if (seeder.level !== undefined && seeder.score !== undefined) {
        let scoreStep = 1 / seeder.slots;
        seeder.score = (100.0 - (seeder.level * 10)) - (scoreStep * seeder.peers);
    }
  });

  /**
   * Event handler for starting or stopping streaming in a room
   * @param {string} room - The ID of the room
   * @param {string} host - The ID of the host socket
   */
  socket.on("stream", (room, host) => {
    if (!rooms[room]) return;

    const seeder = rooms[room].seeders[socket.id] || (rooms[room].seeders[socket.id] = {});

    if (rooms[room].host === socket.id) {
        rooms[room].stream = true;
        seeder.level = 0;
        seeder.score = 100.0;
    }

    if (host) {
        seeder.level = ((rooms[room].seeders[host] && rooms[room].seeders[host].level) || 0) + 1;
        seeder.score = 100.0 - (seeder.level * 10);
        seeder.peers = 0;
        seeder.slots = 0;
    }
  });

  /**
 * Event handler for offering a file for download in a room
 * @param {string} room - The ID of the room
 * @param {Object} file - The file object containing name and size
 */
  socket.on("offerFile", (room, file) => {
    if (!rooms[room]) return;

    const roomFiles = rooms[room].share.files || {};

    if (rooms[room].host === socket.id) {
        roomFiles[file.name] = { size: file.size, seeders: [socket.id] };
    } else if (roomFiles[file.name] &&
        roomFiles[file.name].size === file.size &&
        !roomFiles[file.name].seeders.includes(socket.id)) {
        roomFiles[file.name].seeders.push(socket.id);
    }

    rooms[room].share.files = roomFiles;
    socket.to(room).emit("getFiles", roomFiles);
    socket.to(rooms[room].host).emit("currentFilePeers", file.name, Object.keys(rooms[room].share.files[file.name].seeders).length);
  });

  /**
   * Event handler for getting the shared files in a room
   * @param {string} room - The ID of the room
   * @param {Callback} callback - Callback function to be invoked with the shared files
   */
  socket.on("getFiles", (room, callback) => {
    if (!rooms[room] || !rooms[room].share.files) return;

    socket.join(room);
    socket.to(socket.id).emit("getFiles", rooms[room].share.files);

    if (typeof callback === "function") {
        callback(rooms[room].share.files);
    }
  });

  /**
   * Event handler for deleting a file from a room
   * @param {string} filename - The name of the file to delete
   */
  socket.on("deleteFile", (filename) => {
    Object.entries(rooms).forEach(([id, room]) => {
        if (room.host !== socket.id) return;
        if (!room.share.files || !room.share.files[filename]) return;

        delete room.share.files[filename];
        socket.to(id).emit("getFiles", room.share.files);
    });
  });

  /**
   * Event handler for downloading a file from a room
   * @param {string} room - The ID of the room
   * @param {Object} file - The file object to download
   * @param {string} host - The ID of the host socket
   */
  socket.on("downloadFile", (room, file, host) => {
    if (!rooms[room]) return;

    socket.to(host).emit("downloadFile", socket.id, file);
  });

  /**
   * Event handler for creating a meeting room
   * @param {string} room - The ID of the room
   * @param {string} host - The ID of the host socketst socket
   * @param {Object} settings - The meeting settings
   */
  socket.on("createMeeting", (room, host, settings) => {
    if (!rooms[room]) return;
    rooms[room].meeting = true;
    rooms[room].meetingSettings = settings;
  });

  socket.on("message", (room, type, message) => {
    socket.to(room).emit("message", socket.id, type, message);
  });

  /*socket.on("meeting", (room, callback) => {
    if (!rooms[room] && rooms[room].meeting) return;
    const roomData = rooms[room];
    if (!rooms[room] && rooms[room].meeting) {
        callbackHandler(callback, {message: "Room not found", room});
        return;
    }
    socket.join(room);
    const participants = Object.entries(rooms[room].participants);

    for (const [participant, value] of participants) {
        if (participant !== socket.id) continue;

        socket.to(participant).emit("meeting", socket.id);
        callbackHandler(callback, {message: "Client connected", room, participant: participant});
        return;
    }
  });*/
  /**
   * Event handler for getting meeting settings
   * @param {string} room - The ID of the room
   * @param {Callback} callback - Callback function to be invoked with the meeting settings
   */
  socket.on("getMeetingSettings", (room, callback) => {
    if (!rooms[room] || !rooms[room].meeting) {
      callbackHandler(callback, { message: "Meeting not found", room });
      return;
    }
    const settings = rooms[room].meetingSettings;
    callbackHandler(callback, { message: "Meeting settings retrieved", room, settings });
  });

  socket.on("getParticipants", (room, callback) => {
    if (!rooms[room] || !rooms[room].meeting) {
      callbackHandler(callback, { message: "Meeting not found", room });
      return;
    }
    const participants = rooms[room].participants;
    callbackHandler(callback, { message: "Meeting settings retrieved", room, participants });
  });
  /**
   * Event handler for joining a meeting
   * @param {string} room - The ID of the meeting room
   * @param {string} name - The name of the participant
   */
  socket.on("joinMeeting", (room, name, callback) => {
    if (!rooms[room] || !rooms[room].meeting) return;
    socket.join(room);
    if (!rooms[room].participants) rooms[room].participants = {};
    rooms[room].participants[socket.id] = {name: name, id: socket.id};
    socket.to(room).emit("participantJoined", rooms[room].participants[socket.id]);
    socket.to(room).emit("message", socket.id, "join", "");
    callbackHandler(callback, { message: "meeting joined", participants: rooms[room].participants, id: socket.id });
  });
});

server.listen(port, () => console.log(`Server is running on port ${port}`));