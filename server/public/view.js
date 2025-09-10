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
const client = new Client(socket, config, "stream", document.getElementById("room").value, document.getElementById("max_peers_stream").value);

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

client.streamCallback = function(stream) {
  const video = document.querySelector("video");
  video.srcObject = stream;
  client.setStream(stream);
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

document.getElementById("viewerurl").value = window.location.origin + "/view/" + document.getElementById("room").value;


document.getElementById("copy_viewerurl").addEventListener("click", function() {
  navigator.clipboard.writeText(document.getElementById("viewerurl").value);
  bulmaToast.toast({ message: "Copied to clipboard", type: "is-info", position: "bottom-left" });
 });

document.getElementById("max_peers_stream").addEventListener("change", (e) => {
  if (e.target.value < 1) e.target.value = 1;
  if (isNaN(e.target.value)) e.target.value = parseInt(e.target.value);
  client.setSlots(e.target.value);
});