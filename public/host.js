/* global io, bulmaToast */
import { Host } from '/class.js';
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

document.getElementById("shareurl").value = "";
document.getElementById("viewerurl").value = "";

const host = new Host(socket, config, "fileshare", document.getElementsByClassName("max_peers")[0].value);

function setFileShareLink() {
  document.getElementById("shareurl").value = window.location.origin + "/share/" + host.getRoom();
}

function setStreamLink() {
  document.getElementById("viewerurl").value = window.location.origin + "/view/" + host.getRoom();
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
  entry.innerHTML = `
    <span class="panel-icon">
      <i class="fa fa-file" aria-hidden="true"></i>
    </span>
    <div class="columns" style="width: 100%">
      <div class="column">${file.name}</div>
      <div class="column"><progress id="${file.name}-upload" max="${file.size}" value="0"></progress></div>
      <div class="column">${Math.round(file.size / 1024 / 1024)} MB</div>
      <div class="column peers">1</div>
      <div class="column"><i class="fa fa-trash"></i></div>
    </div>
  `;
  document.getElementById("filecontent").append(entry);

  // Find the trash icon within the newly added entry and attach click event
  const trashIcon = entry.querySelector('.fa-trash');
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
    let stream;
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
      host.setStream(stream);
      setStreamLink();
      showStream(stream);
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
 });

 document.getElementById("tab_stream").addEventListener("click", function() {
  document.getElementById("tab_stream").classList.add("is-active");
  document.getElementById("tab_files_content").classList.add("is-hidden");
  document.getElementById("tab_files").classList.remove("is-active");
  document.getElementById("tab_stream_content").classList.remove("is-hidden");
 });

 document.getElementById("copy_shareurl").addEventListener("click", function() {
  navigator.clipboard.writeText(document.getElementById("shareurl").value);
  bulmaToast.toast({ message: "Copied to clipboard", type: "is-info", position: "bottom-left" });
 });

 document.getElementById("copy_viewerurl").addEventListener("click", function() {
  navigator.clipboard.writeText(document.getElementById("viewerurl").value);
  bulmaToast.toast({ message: "Copied to clipboard", type: "is-info", position: "bottom-left" });
 });

 Array.from(document.getElementsByClassName("close_pause")).forEach((el) => {
  el.addEventListener("click", () => {
    document.getElementById("overlay_pause").style.visibility = "hidden";
    document.querySelector("video").play();
  });
});