/* global io, bulmaToast */
import { Client } from '/class.js';

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
const client = new Client(socket, config, "fileshare", document.getElementById("room").value, document.getElementById("max_peers_files").value);

client.toastCallback = function(message, type) {
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

client.statsCallback = function(stats) {
  let uploadSpeed = "0 bit/s";
  let downloadSpeed = "0 bit/s";
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

  switch (true) {
    case (stats.sumDownloadSpeed <= 1000 * 1000):
      downloadSpeed = `${(stats.sumDownloadSpeed / 1000).toFixed(2)} kbit/s`;
      break;
    case (stats.sumDownloadSpeed <= (1000 * 1000 * 1000)):
      downloadSpeed = `${(stats.sumDownloadSpeed / 1000 / 1000).toFixed(2)} Mbit/s`;
      break;
    case (stats.sumDownloadSpeed <= (1000 * 1000 * 1000 * 1000)):
      downloadSpeed = `${(stats.sumDownloadSpeed / 1000 / 1000 / 1000).toFixed(2)} Gbit/s`;
      break;
    default:
      downloadSpeed = `${(stats.sumDownloadSpeed).toFixed(2)} bit/s`;
  }

  document.getElementById("upload_speed_files").innerHTML = `${uploadSpeed}`;
  document.getElementById("download_speed_files").innerHTML = `${downloadSpeed}`;
};

client.progressUploadCallback = function(filename, sum, max) {
  document.getElementById(`${filename}-upload`).value = sum;
  document.getElementById(`${filename}-upload`).max = max;
};

function getFiles(files) {
    document.getElementById("filecontent").innerHTML = "";
    for (const [key, value] of Object.entries(files)) {
      let file = {name: key, size: value.size, seeders: value.seeders};
      displayFile(file);
    }
}

client.getFilesCallback = getFiles;

window.client = client;

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
        <div class="column"><progress id="${file.name}-download" max="${file.size}" value="0"></progress></div>
        <div class="column"><progress id="${file.name}-upload" max="${file.size}" value="0"></progress></div>
        <div class="column">${Math.round(file.size / 1024 / 1024)} MB</div>
        <div class="column">${file.seeders.length}</div>
        <div class="column"><i class="fa fa-download" onclick="client.downloadFile('${file.name}')"></i></div>
      </div>
    `;
    document.getElementById("filecontent").append(entry);
}

document.getElementById("shareurl").value = window.location.origin + "/share/" + document.getElementById("room").value;

document.getElementById("copy_shareurl").addEventListener("click", function() {
  navigator.clipboard.writeText(document.getElementById("shareurl").value);
  bulmaToast.toast({ message: "Copied to clipboard", type: "is-info", position: "bottom-left" });
 });

document.getElementById("max_peers_files").addEventListener("change", (e) => {
    if (e.target.value < 1) e.target.value = 1;
    if (isNaN(e.target.value)) e.target.value = parseInt(e.target.value);
    client.setSlots(e.target.value);
});