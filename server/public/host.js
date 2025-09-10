/* global io, bulmaToast */
import { Host, MediaStreamCropperResizer } from '/class.js';
const socket = io.connect(window.location.origin);
const config = {
  iceServers: [
    {
      urls: "stun:stun.l.google.com:19302",
    },
    // {
    //   urls: "turn:TURN_IP?transport=tcp",
    //   username: "TURN_USERNAME",
    //   credential: "TURN_CREDENTIALS",
    // },
  ],
};
let stream, processedStream;

document.getElementById("shareurl").value = "";
document.getElementById("viewerurl").value = "";
document.getElementById("meetingurl").value = "";

const host = new Host(socket, config, "fileshare", document.getElementsByClassName("max_peers")[0].value);

function setFileShareLink() {
  document.getElementById("shareurl").value = window.location.origin + "/share/" + host.getRoom();
}

function setStreamLink() {
  document.getElementById("viewerurl").value = window.location.origin + "/view/" + host.getRoom();
}

function setMeetingLink() {
  document.getElementById("meetingurl").value = window.location.origin + "/meet/" + host.getRoom();
}

host.statsCallback = function(stats) {
  let uploadSpeed = "0 bit/s";
  switch (true) {
    case (stats.sumUploadSpeed <= 1000 * 1000):
      uploadSpeed = `${(stats.sumUploadSpeed / 1000).toFixed(2)} kbit/s`;
      break;
    case (stats.sumUploadSpeed <= (1000 * 1000 * 1000)):
      uploadSpeed = `${(stats.sumUploadSpeed / 1000 / 1000).toFixed(2)} Mbit/s`;
      break;
      case (stats.sumUploadSpeed <= (1000 * 1000 * 1000 * 1000)):
      uploadSpeed = `${(stats.sumUploadSpeed / 1000 / 1000 / 1000).toFixed(2)} Gbit/s`;
      break;
    default:
      uploadSpeed = `${(stats.sumUploadSpeed).toFixed(2)} bit/s`;
  }
    Array.from(document.getElementsByClassName("upload_speed")).forEach((el) => {
      el.innerHTML = `${uploadSpeed}`;
    });
};

host.currentPeersCallback = function(peers) {
  document.getElementById("countAudience").innerHTML = peers;
  document.getElementById("countPeers").innerHTML = peers;
};

host.currentFilePeersCallback = function(filename, peers) {
  const entry = document.querySelector('[data-filename="' + filename + '"]');
  entry.querySelector('.peers').innerHTML = peers;
};

host.progressUploadCallback = function(filename, sum, max) {
  document.getElementById(`${filename}-upload`).value = sum;
  document.getElementById(`${filename}-upload`).max = max;
};

function showStream(stream) {
  const videoElement = document.querySelector("video");
  if (videoElement.srcObject === null) {
    videoElement.addEventListener("pause", () => {
      if (videoElement.srcObject.active === true) document.getElementById("overlay_pause").style.visibility = "visible";
    });
    setTimeout(() => {
      if (videoElement.paused === false && videoElement.srcObject.active === true) {
        videoElement.pause();
        document.getElementById("overlay_pause").style.visibility = "visible";
      }
    }, 10000);
  }
  videoElement.srcObject = stream;
}

host.toastCallback = function(message, type) {
  switch (type) {
    case "error":
      bulmaToast.toast({ message: message, type: "is-danger", position: "bottom-left"});
      break;
    case "success":
      bulmaToast.toast({ message: message, type: "is-success", position: "bottom-left" });
      break;
    case "info":
      bulmaToast.toast({ message: message, type: "is-info", position: "bottom-left" });
      break;
    default:
      bulmaToast.toast({ message: message, type: "is-primary", position: "bottom-left" });
  }
};

function fileInputChange(e) {
  for (let i = 0; i < e.target.files.length; i++) {
    let uuid = self.crypto.randomUUID();
    let clone = e.target.cloneNode(true);
    clone.addEventListener("change", fileInputChange);
    document.body.appendChild(clone);
    e.target.setAttribute("id", uuid);
    host.setFileInput(e.target);
    host.offerFile({name: e.target.files[i].name, size: e.target.files[i].size });
    displayFile({name: e.target.files[i].name, size: e.target.files[i].size });
  }
  setFileShareLink();
}

function deleteFile(filename) {
  let entry = document.querySelector(`a[data-filename='${filename}']`);
  if (entry) {
    entry.remove();
    // Assuming host.deleteFile(filename) is a valid call to delete the file on the server or similar
    host.deleteFile(filename);
  } else {
    console.error('File entry not found');
  }
}

function displayFile(file) {
  let entry = document.createElement('a');
  entry.classList.add("panel-block");
  entry.setAttribute("data-filename", file.name);

  let panelIcon = document.createElement('span');
  panelIcon.classList.add("panel-icon");
  let icon = document.createElement('i');
  icon.classList.add("fa", "fa-file");
  icon.setAttribute("aria-hidden", "true");
  panelIcon.appendChild(icon);
  entry.appendChild(panelIcon);

  let columns = document.createElement('div');
  columns.classList.add("columns");
  columns.style.width = "100%";

  let nameColumn = document.createElement('div');
  nameColumn.classList.add("column");
  nameColumn.textContent = file.name;
  columns.appendChild(nameColumn);

  let progressColumn = document.createElement('div');
  progressColumn.classList.add("column");
  let progress = document.createElement('progress');
  progress.id = `${file.name}-upload`;
  progress.max = file.size;
  progress.value = 0;
  progressColumn.appendChild(progress);
  columns.appendChild(progressColumn);

  let sizeColumn = document.createElement('div');
  sizeColumn.classList.add("column");
  sizeColumn.textContent = `${Math.round(file.size / 1024 / 1024)} MB`;
  columns.appendChild(sizeColumn);

  let peersColumn = document.createElement('div');
  peersColumn.classList.add("column", "peers");
  peersColumn.textContent = "1";
  columns.appendChild(peersColumn);

  let trashColumn = document.createElement('div');
  trashColumn.classList.add("column");
  let trashIcon = document.createElement('i');
  trashIcon.classList.add("fa", "fa-trash");
  trashColumn.appendChild(trashIcon);
  columns.appendChild(trashColumn);

  entry.appendChild(columns);

  document.getElementById("filecontent").appendChild(entry);

  // Find the trash icon within the newly added entry and attach click event
  trashIcon.addEventListener('click', () => deleteFile(file.name));
}

Array.from(document.getElementsByClassName("max_peers")).forEach((el) => {
  el.addEventListener("change", (e) => {
    if (e.target.value < 1) e.target.value = 1;
    if (isNaN(e.target.value)) e.target.value = parseInt(e.target.value);
    host.setSlots(e.target.value);
    Array.from(document.getElementsByClassName("max_peers")).forEach((element) => {
      element.value = e.target.value;
    });
  });
});

document.getElementById("filesinput").onchange = fileInputChange;
document.getElementById("startStreaming").onclick = async function() {
  stopStream(stream);
  stopStream(processedStream);
    try {
      stream = await navigator.mediaDevices.getDisplayMedia({
          video: {
            displaySurface: "browser",
          },
          audio: true,
          preferCurrentTab: false,
          selfBrowserSurface: "exclude",
          systemAudio: "include",
          surfaceSwitching: "include",
          monitorTypeSurfaces: "include",
        });
      const enableCropping = document.getElementById("enableCropping").checked;
      const enableResizing = document.getElementById("enableResizing").checked;
      if (enableCropping === true || enableResizing === true) {
        const x = document.getElementById("left").value;
        const y = document.getElementById("top").value;
        const right = document.getElementById("right").value;
        const bottom = document.getElementById("bottom").value;
        const widthResize = document.getElementById("width").value;
        const heightResize = document.getElementById("height").value;
        const manipulateStream = new MediaStreamCropperResizer(stream, x, y, right, bottom, widthResize, heightResize, enableCropping, enableResizing);
        processedStream = manipulateStream.getProcessedStream();
        host.setStream(processedStream);
        setStreamLink();
        showStream(processedStream);
      } else {
        host.setStream(stream);
        setStreamLink();
        showStream(stream);
      }
    } catch (err) {
      host.toast(`Error: ${err}`, "error");
    }
 };

document.getElementById('uploadbutton').onclick = function() {
  document.getElementById('filesinput').click();
};

document.getElementById("tab_files").addEventListener("click", function() {
  document.getElementById("tab_files").classList.add("is-active");
  document.getElementById("tab_stream_content").classList.add("is-hidden");
  document.getElementById("tab_stream").classList.remove("is-active");
  document.getElementById("tab_files_content").classList.remove("is-hidden");
  document.getElementById("tab_meeting").classList.remove("is-active");
  document.getElementById("tab_meeting_content").classList.add("is-hidden");
 });

 document.getElementById("tab_stream").addEventListener("click", function() {
  document.getElementById("tab_stream").classList.add("is-active");
  document.getElementById("tab_files_content").classList.add("is-hidden");
  document.getElementById("tab_files").classList.remove("is-active");
  document.getElementById("tab_stream_content").classList.remove("is-hidden");
  document.getElementById("tab_meeting").classList.remove("is-active");
  document.getElementById("tab_meeting_content").classList.add("is-hidden");
 });

 document.getElementById("tab_meeting").addEventListener("click", function() {
  document.getElementById("tab_meeting").classList.add("is-active");
  document.getElementById("tab_meeting_content").classList.remove("is-hidden");
  document.getElementById("tab_files").classList.remove("is-active");
  document.getElementById("tab_stream_content").classList.add("is-hidden");
  document.getElementById("tab_stream").classList.remove("is-active");
  document.getElementById("tab_files_content").classList.add("is-hidden");
 });

 document.getElementById("copy_shareurl").addEventListener("click", function() {
  navigator.clipboard.writeText(document.getElementById("shareurl").value);
  bulmaToast.toast({ message: "Copied to clipboard", type: "is-info", position: "bottom-left" });
 });

 document.getElementById("copy_viewerurl").addEventListener("click", function() {
  navigator.clipboard.writeText(document.getElementById("viewerurl").value);
  bulmaToast.toast({ message: "Copied to clipboard", type: "is-info", position: "bottom-left" });
 });

 document.getElementById("copy_meetingurl").addEventListener("click", function() {
  navigator.clipboard.writeText(document.getElementById("meetingurl").value);
  bulmaToast.toast({ message: "Copied to clipboard", type: "is-info", position: "bottom-left" });
 });

 Array.from(document.getElementsByClassName("close_pause")).forEach((el) => {
  el.addEventListener("click", () => {
    document.getElementById("overlay_pause").style.visibility = "hidden";
    document.querySelector("video").play();
  });
});

document.getElementById("enableCropping").addEventListener("change", function() {
  if (this.checked === false)  return;
  if (typeof MediaStreamTrackProcessor === 'undefined' ||
    typeof MediaStreamTrackGenerator === 'undefined') {
  alert('Your browser does not support the MediaStreamTrack API for Insertable Streams of Media.');
  return;
  }
});

document.getElementById("enableResizing").addEventListener("change", function() {
  if (this.checked === false)  return;
  if (typeof MediaStreamTrackProcessor === 'undefined' ||
    typeof MediaStreamTrackGenerator === 'undefined') {
  alert('Your browser does not support the MediaStreamTrack API for Insertable Streams of Media.');
  return;
  }
  setWidthHeight();
});

document.getElementById("res").addEventListener("change", function() {
  if (this.checked === false)  return;
  setWidthHeight();
});

document.getElementById("ratio").addEventListener("change", function() {
  if (this.checked === false)  return;
  setWidthHeight();
});

function setWidthHeight() {
  const ratio = document.getElementById("ratio").value;
  const res = document.getElementById("res").value;
  const width = document.getElementById("width");
  const height = document.getElementById("height");

  height.value = Number(res);

  if (ratio === "16:9") width.value = Math.round(16 / 9 * Number(height.value));
  if (ratio === "16:10") width.value = Math.round(16 / 10 * Number(height.value));
  if (ratio === "4:3") width.value = Math.round(4 / 3 * Number(height.value));
}

function stopStream(stream) {
  if (stream instanceof MediaStream)  {
    stream.getTracks().forEach(track => track.stop());
  }
}

Array.from(document.getElementsByClassName("close-modal")).forEach((el) => {
  el.addEventListener("click", () => {
    el.closest(".modal").classList.remove("is-active");
  });
});

document.getElementById("openSettings").addEventListener("click", () => {
  document.getElementById("settingsModal").classList.add("is-active");
});

document.getElementById("saveSettings").addEventListener("click", () => {
  document.getElementById("startStreaming").click();
});

document.getElementById("startmeetingbutton").addEventListener("click", () => {
  setMeetingLink();

  const meetingName = document.getElementById("meetingname").value;
  const meetingDescription = document.getElementById("meetingdesc").value;
  const instantMeeting = document.getElementById("instantmeeting").checked;
  const scheduledMeeting = document.getElementById("schedulemeeting").checked;
  const voiceOnly = document.getElementById("voiceonly").checked;
  const enableChat = document.getElementById("enablechat").checked;
  //const enableSharing = document.getElementById("enablesharing").checked;
  const enableRecording = document.getElementById("recording").checked;
  const muted = document.getElementById("muted").checked;
  const cameraOff = document.getElementById("camoff").checked;
  const maxCamResolution = document.getElementById("camres").value;

  let meetingDate = document.getElementById("meetingdate").value;

  if (meetingDate === "" || instantMeeting) meetingDate = new Date().getTime();
  if (meetingDate !== "" && scheduledMeeting) meetingDate = new Date(meetingDate).getTime();


  const settings = {
    meetingName: meetingName,
    meetingDescription: meetingDescription,
    instantMeeting: instantMeeting,
    scheduledMeeting: scheduledMeeting,
    meetingDate: meetingDate,
    voiceOnly: voiceOnly,
    enableChat: enableChat,
    //enableSharing: enableSharing,
    enableRecording: enableRecording,
    muted: muted,
    cameraOff: cameraOff,
    maxCamResolution: maxCamResolution
  };
  host.createMeeting(settings);
});