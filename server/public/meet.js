/* global io, bulmaToast */
import { Meet } from '/class.js';
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

let screenShareStream;

const participants = {};

const meet = new Meet(socket, config, document.getElementById("room").value);

meet.toastCallback = function(message, type) {
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

const flexMeeting = document.getElementById('attendees');

const adjustChildSizes = () => {

  const divWidth = flexMeeting.offsetWidth;
  const divHeight = flexMeeting.offsetHeight;

  const windowWidth = window.innerWidth;

  // Determine the smallest width and height among children
  const children = Array.from(flexMeeting.children);
  const childrenCount = children.length;

  children.forEach(child => {
        switch (true) {
          case childrenCount === 1 && windowWidth === divWidth:
            child.style.width = `calc(${divWidth}px - 64px)`;
            child.style.height = `calc(${divHeight}px - 64px)`;
            break;
          case childrenCount === 2 && windowWidth === divWidth:
            child.style.width = `calc(${divWidth / 2}px - 64px)`;
            child.style.height = `calc(${divHeight}px - 64px)`;
            break;
          case (childrenCount === 3 || childrenCount === 4) && windowWidth === divWidth:
            child.style.width = `calc(${divWidth / 2}px - 64px)`;
            child.style.height = `calc(${divHeight / 2}px - 64px)`;
            break;
          case childrenCount >= 5 && childrenCount <= 12 && windowWidth === divWidth:
            child.style.width = `calc(${divWidth / 4}px - 64px)`;
            child.style.height = `calc(${divHeight / 3}px - 64px)`;
            break;
          case childrenCount <= 3 && windowWidth !== divWidth:
            child.style.width = `calc(${divWidth}px - 64px)`;
            child.style.height = `calc(${divHeight / 3}px - 64px)`;
            break;
          case childrenCount >= 4 && windowWidth !== divWidth:
            child.style.width = `calc(${divWidth / 2}px - 64px)`;
            child.style.height = `calc(${divHeight / 4}px - 64px)`;
            break;
          default:
            child.style.width = `calc(${divWidth / 4}px - 64px)`;
            child.style.height = `calc(${divHeight / 4}px - 64px)`;
            break;
        }
  });
};

window.addEventListener('resize', adjustChildSizes);

meet.callbackMessage = function(id, name, type, message) {
  if (id === meet.id) return;
  const divAttendee = document.querySelector(`[data-id="${id}"]`);
  const muteSpan = document.getElementById(`${id}-mute`);
  const handSpan = document.getElementById(`${id}-hand`);
  const chatContent = document.getElementById('chatcontent');
  const messageElement = document.createElement('p');
  const participantColor = participants[id].color || colors[Math.floor(Math.random() * colors.length)];
  const currentTime = new Date().toLocaleTimeString();

  switch (type) {
    case 'chat':
      // Handle chat message
      messageElement.innerHTML = `<span style="color: ${participantColor}">${name}:</span> ${message} <span style="color:grey">${currentTime}</span>`;
      chatContent.appendChild(messageElement);
      bulmaToast.toast({ message: `${name}: ${message}`, type: "has-background-grey", position: "bottom-right"});
      break;
    case 'mute':
      muteSpan.innerHTML = `<i class="fa fa-microphone" style="color: red; margin-right: 0.5rem"></i>`;
      break;
    case 'unmute':
      muteSpan.innerHTML = ``;
      break;
    case 'camoff':
      participants[id].cameraOff();
      break;
    case 'camon':
      participants[id].cameraOn();
      break;
    case 'raisehand':
      // Handle raise hand message
      handSpan.innerHTML = `<i class="fa fa-hand-paper-o" style="color: hsla(42deg,100%,53%,1); margin-right: 0.5rem"></i>`;
      break;
    case 'lowerhand':
      // Handle lower hand message
      handSpan.innerHTML = ``;
      break;
    case 'emote':
      // Handle emote message
      handleEmote(message);
      break;
    case 'leave':
      // Handle leave message
      participants[id].hideScreenShare();
      delete participants[id];
      divAttendee.remove();
      adjustChildSizes();
      break;
    case 'join':
      bulmaToast.toast({ message: `${name} joined the meeting`, type: "is-info", position: "bottom-left"});
      break;
    case 'screenshare':
      if (meet.screenShareStream) {
        screenShareStream.getTracks().forEach(track => track.stop());
        screenShareStream = null;
        meet.sendMessage('screenshareoff', me.screenshareId);
        me.hideScreenShare();
        meet.setScreenShareStream(null);
        screenShareButton.click();
      }
      participants[id].updateScreenShare(message);
      break;
    case 'screenshareoff':
      participants[id].screenshareId = null;
      participants[id].hideScreenShare();
      adjustChildSizes();
      break;
    case 'mediaDevice':
      participants[id].updateMediaDevice(message);
      break;
  }
};

meet.getMeetingSettings(getMeetingSettings);

let me, settings;

const colors = [
  "hsl(171, 100%, 41%)",
  "hsl(217, 71%, 53%)",
  "hsl(204, 86%, 53%)",
  "hsl(141, 71%, 48%)",
  "hsl(48, 100%, 67%)",
  "hsl(348, 100%, 61%)",
  "#64A2DE",
  "#64C8DE",
  "#64DEA2",
  "#647BDE",
  "#D100D1",
  "#524929",
  "#D1CE00",
  "#D13D00",
  "#011526",
  "#F2B872",
  "#A65F21",
  "#D9A87E",
  "#593825"
];

const videoButton = document.getElementById('videobutton');
const videoSelectButton = document.getElementById('videoselectbutton');
const preVideoButton = document.getElementById('prevideobutton');
const audioButton = document.getElementById('audiobutton');
const audioSelectButton = document.getElementById('audioselectbutton');
const preAudioButton = document.getElementById('preaudiobutton');
const leaveMeetingButton = document.getElementById('leavemeetingbutton');
const raiseHandButton = document.getElementById('raisehandbutton');
const chatInput = document.getElementById('chatinput');
const chatClose = document.getElementById('closechat');
const chatOpen = document.getElementById('chatopenbutton');
const openEmoji = document.getElementById('openemoji');
const openSubtitle = document.getElementById('opensubtitle');

const openEmojiSmile = document.getElementById('openemojismile');
const openEmojiCat = document.getElementById('openemojicat');
const openEmojiTransport = document.getElementById('openemojitransport');
const openEmojioffice = document.getElementById('openemojioffice');
const openEmojiAnimals = document.getElementById('openemojianimals');

  // Create a class for each participant
  class Participant {
    constructor(participant, muted = false) {

      this.name = participant.name;
      this.id = participant.id;
      this.streams = participant.streams;
      this.screenshareStreams = participant.screenshareStreams || [];
      this.screenshareTracks = participant.screenshareTracks || [];
      this.tracks = participant.tracks;
      this.peerConnection = participant.peerConnection;

      this.mediaDeviceId = this.streams[0].id;
      if (participant.screenshareStreams !== undefined) {
        this.screenshareId = participant.screenshareStreams.length > 0 ? participant.screenshareStreams[0].id : null;
      }

      this.muted = muted;

      this.hasVideo = this.streams[0].getVideoTracks().length > 0;
      this.hasAudio = this.streams[0].getAudioTracks().length > 0;

      this.color = colors[Math.floor(Math.random() * colors.length)];

    }

    updateScreenShare(streamId) {
      this.screenshareId = streamId;

      if (this.screenshareStreams.length > 0) {
        this.showScreenShare(this.screenshareStreams.length - 1);
      }
    }

    updateMediaDevice(streamId) {
      this.mediaDeviceId = streamId;

      if (this.streams.length > 0) {
        this.hasVideo = this.streams[this.streams.length - 1].getVideoTracks().length > 0;
        this.hasAudio = this.streams[this.streams.length - 1].getAudioTracks().length > 0;
        if (this.hasVideo) {
          this.cameraOn(this.streams.length - 1);
        } else {
          this.cameraOff(this.streams.length - 1);
        }
      }
    }

    update(participant) {
      this.name = participant.name;
      this.id = participant.id;
      this.streams = participant.streams;

      this.tracks = participant.tracks;
      this.peerConnection = participant.peerConnection;
      this.pcScreenshare = participant.pcScreenshare;
      this.screenshareStreams = participant.screenshareStreams;
      this.screenshareTracks = participant.screenshareTracks;

      if (this.screenshareStreams.length > 0) {
        this.screenshareId = this.screenshareStreams[this.screenshareStreams.length - 1].id;
      }

      if (this.streams.length > 0) {
        this.mediaDeviceId = this.streams[this.streams.length - 1].id;
      }

      if (this.streams.length > 0) {
        this.hasVideo = this.streams[this.streams.length - 1].getVideoTracks().length > 0;
        this.hasAudio = this.streams[this.streams.length - 1].getAudioTracks().length > 0;
        if (this.hasVideo) {
          this.cameraOn(this.streams.length - 1);
        } else {
          this.cameraOff(this.streams.length - 1);
        }
      } else {
        this.hasVideo = false;
        this.hasAudio = false;
      }

      if (this.screenshareStreams.length > 0) {
        this.showScreenShare(this.screenshareStreams.length - 1);
      }
    }

    cameraOff(arrayId = 0) {
      const div = document.getElementById("attendees");
      let divAttendee = div.querySelector(`[data-id="${this.id}"]`);
      if (!divAttendee) {
        divAttendee = document.createElement("div");
        divAttendee.setAttribute("data-id", this.id);
      }
      divAttendee.classList.add('attendee-novideo');
      divAttendee.classList.remove('attendee-video');
      divAttendee.innerHTML = ``;
      const audioElement = document.createElement("audio");
      audioElement.srcObject = this.streams[arrayId];
      audioElement.autoplay = true;
      audioElement.muted = this.muted;

      divAttendee.innerHTML = `<span style="background-color: ${this.color}"><p class="p-center">${this.name.charAt(0)}</p></span>`;
      divAttendee.appendChild(audioElement);
      div.appendChild(divAttendee);

      const divName = document.createElement("div");
      divName.classList.add("attendee-name");
      divName.innerHTML = `<span id="${this.id}-mute"></span><span id="${this.id}-hand"></span><span>${this.name}</span>`;
      divAttendee.appendChild(divName);
    }

    showScreenShare(index = 0) {
      const div = document.getElementById("spotlight");
      const attendees = document.getElementById("attendees");
      div.style.display = "block";
      attendees.style.width = "20vw";
      let divSpotlight = div.querySelector(`[data-id="${this.id}-screenshare"]`);
      if (divSpotlight !== null) divSpotlight.remove();
      divSpotlight = document.createElement("div");
      divSpotlight.setAttribute("data-id", this.id + "-screenshare");
      const videoElement = document.createElement("video");
      videoElement.muted = true;
      videoElement.srcObject = this.screenshareStreams[index];
      videoElement.autoplay = true;
      divSpotlight.appendChild(videoElement);
      div.appendChild(divSpotlight);
    }

    hideScreenShare() {
      const div = document.getElementById("spotlight");
      let divSpotlight = div.querySelector(`[data-id="${this.id}-screenshare"]`);
      if (divSpotlight !== null) divSpotlight.remove();
      if (div.childElementCount === 0) {
        div.style.display = "none";
        const attendees = document.getElementById("attendees");
        attendees.style.width = "100vw";
      }
    }

    cameraOn(arrayId = 0) {
      const div = document.getElementById("attendees");
      let divAttendee = div.querySelector(`[data-id="${this.id}"]`);
      if (!divAttendee) {
        divAttendee = document.createElement("div");
        divAttendee.setAttribute("data-id", this.id);
      }
      divAttendee.classList.remove('attendee-novideo');
      divAttendee.classList.add('attendee-video');
      divAttendee.innerHTML = ``;
      const videoElement = document.createElement("video");
      videoElement.muted = this.muted;
      videoElement.srcObject = this.streams[arrayId];
      videoElement.autoplay = true;
      divAttendee.appendChild(videoElement);
      div.appendChild(divAttendee);

      const divName = document.createElement("div");
      divName.classList.add("attendee-name");
      divName.innerHTML = `<span id="${this.id}-mute"></span><span id="${this.id}-hand"></span><span>${this.name}</span>`;
      divAttendee.appendChild(divName);
    }

    addToDOM() {
     if (this.hasVideo) {
      this.cameraOn();
     }
     if (this.hasAudio && !this.hasVideo) {
      this.cameraOff();
     }

      const div = document.getElementById("attendees");
      const divAttendee = div.querySelector(`[data-id="${this.id}"]`);

      const audioCtx = new AudioContext();
      const source = audioCtx.createMediaStreamSource(this.streams[this.streams.length - 1]);
      const analyser = audioCtx.createAnalyser();
      analyser.fftSize = 256;

      const bufferLength = analyser.frequencyBinCount;
      const dataArray = new Uint8Array(bufferLength);

      source.connect(analyser);

      const visualize = async () => {
        if (divAttendee.classList.contains("attendee-video")) divAttendee.classList.remove("speak-animation-video");
        if (divAttendee.classList.contains("attendee-novideo")) divAttendee.firstChild.classList.remove("speak-animation-novideo");

        requestAnimationFrame(visualize);

       analyser.getByteFrequencyData(dataArray);

        for (let i = 0; i < bufferLength; i++) {
          if (dataArray[i] > 128 && divAttendee.classList.contains("attendee-video")) divAttendee.classList.add("speak-animation-video");
          if (dataArray[i] > 128 && divAttendee.classList.contains("attendee-novideo")) divAttendee.firstChild.classList.add("speak-animation-novideo");
        }
      };

      visualize();

    }
  }

meet.callbackParticipantJoined = function(participant) {

  if (videoButton.classList.contains('is-disabled')) meet.sendMessage("camoff", meet.stream.id);
  if (audioButton.classList.contains('is-disabled')) meet.sendMessage("mute", meet.stream.id);

  if (Object.prototype.hasOwnProperty.call(participants, participant.id)) {
    participants[participant.id].update(participant);
  } else {
    // Create a new Participant instance and add it to the DOM
    participants[participant.id] = new Participant(participant);
    participants[participant.id].addToDOM();
  }
};

document.addEventListener('DOMContentLoaded', () => {

  const observer = new MutationObserver((mutations) => {
    mutations.forEach((mutation) => {
        if (mutation.type === 'childList') {
            adjustChildSizes();
        }
    });
  });

  // Start observing the target node for configured mutations
    observer.observe(flexMeeting, { childList: true });
});




function getMeetingSettings(res) {
  if (res.message === "Meeting not found") {
    bulmaToast.toast({ message: "Meeting not found. You leave this page in 5 sec", type: "is-danger", position: "bottom-left"});
    setTimeout(() => {
      window.location.href = "/";
    }, 5000);
    return;
  }
  settings = res.settings;
  document.getElementById("meetingname").innerText = settings.meetingName;
  document.getElementById("meetingdescription").innerText = settings.meetingDescription;
  document.getElementById("moremeetingname").innerText = settings.meetingName;
  document.getElementById("moremeetingdescription").innerText = settings.meetingDescription;

  const url = window.location.href;
  const meetingid = url.substring(url.lastIndexOf('/') + 1);

  document.getElementById("moremeetingid").innerText = meetingid;
  document.getElementById("moremeetinglink").innerText = url;

  if (!settings.enableChat) {
    document.getElementById("chatopenbutton").remove();
    document.getElementById("chat").remove();
  }


  getUserMedia(true, !settings.voiceOnly);
  if (settings.voiceOnly) {
    videoButton.classList.add("is-disabled");
    videoButton.disabled = true;
    preVideoButton.classList.add("is-disabled");
    preVideoButton.disabled = true;
    document.getElementById("camera").disabled = true;
    const info = document.createElement("p");
    info.innerText = "The organisator of this meeting has disabled the video. You can only join with audio.";
    document.getElementById("joininfo").appendChild(info);
  }
}

function buildLayout() {
  const div = document.getElementById("attendees");
  div.innerHTML = "";
  me = new Participant({name: meet.name, id: meet.id, streams: [meet.stream], tracks: meet.stream.getTracks()}, true);
  me.addToDOM();
  me.mediaDeviceId = meet.stream.id;
  me.screenshareId = null;

  if (!me.hasAudio || preAudioButton.classList.contains("is-disabled")) {
    audioButton.classList.add("is-disabled");
    me.muted = true;
    meet.stream.getAudioTracks().forEach(track => {
      track.enabled = !track.enabled;
    });
    meet.sendMessage("mute", meet.stream.id);
  } else {
    audioButton.classList.remove("is-disabled");
  }
  if (!me.hasVideo || preVideoButton.classList.contains("is-disabled")) {
    videoButton.classList.add("is-disabled");
    me.cameraOff();
    meet.sendMessage("camoff", meet.stream.id);
  } else {
    videoButton.classList.remove("is-disabled");
  }

  if (settings.muted) preAudioButton.click();
  if (settings.cameraOff) preVideoButton.click();
}

function getParticipants(res) {
  bulmaToast.toast({ message: res.message, type: "is-info", position: "bottom-left"});
  buildLayout();
  document.getElementById("joinmeetingmodal").classList.remove("is-active");
}

document.getElementById("joinmeeting").addEventListener("click", function() {
  testaudio.pause();
  meet.join(document.getElementById("name").value, getParticipants);
  document.getElementById('videoPreview').srcObject = null;

});

const selectMicrophone = document.getElementById('microphone');
const selectPostMicrophone = document.getElementById('postmicrophone');
const selectSoundOutput = document.getElementById('soundoutput');
const selectCamera = document.getElementById('camera');
const selectPostCamera = document.getElementById('postcamera');
const testsound = document.getElementById('testsound');
const screenShareButton = document.getElementById('screensharebutton');
const nameInput = document.getElementById('name');

let audioContext;
const testaudio = new Audio("/741364__universfield__emotional-piano-and-violin.mp3");

testsound.addEventListener('click', playTestSound);

function playTestSound() {
  if (audioContext === undefined) {
    audioContext = new AudioContext();
    const sourceNode = audioContext.createMediaElementSource(testaudio);
    const gainNode = audioContext.createGain();
    sourceNode.connect(gainNode);
    gainNode.connect(audioContext.destination);
  }
  testaudio.play();
  testsound.removeEventListener('click', playTestSound);
  testsound.addEventListener('click', stopTestSound);
}

function stopTestSound() {
  testaudio.pause();
  testsound.addEventListener('click', playTestSound);
  testsound.removeEventListener('click', stopTestSound);
}
function getUserMedia(audio = true, video = true) {
  navigator.mediaDevices.getUserMedia({audio: audio, video: video})
  .then(() => {
    let startDate = new Date(settings.meetingDate);
    document.getElementById("meetingdate").innerText = startDate.toUTCString();
    if (startDate > new Date(new Date().getTime() + 30 * 60000)) {
      const info = document.createElement("p");
      info.innerText = "You can join this meeting 30 minutes before the start.";
      document.getElementById("joininfo").appendChild(info);
    }
    if (settings.instantMeeting && nameInput.value !== "") document.getElementById("joinmeeting").removeAttribute("disabled");
    if (settings.scheduledMeeting && nameInput.value !== "") {
      if (startDate < new Date(new Date().getTime() + 30 * 60000)) {
        document.getElementById("joinmeeting").removeAttribute("disabled");
      }
    }
    navigator.mediaDevices.enumerateDevices().then(devices => {
      devices.forEach(device => {
          if (device.kind === 'audioinput') {
            const option = document.createElement('option');
            option.value = device.deviceId;
            option.text = device.label;
            selectMicrophone.appendChild(option);
          }
          if (device.kind === 'audiooutput') {
            const option = document.createElement('option');
            option.value = device.deviceId;
            option.text = device.label;
            selectSoundOutput.appendChild(option);
          }
          if (device.kind === 'videoinput') {
            const option = document.createElement('option');
            option.value = device.deviceId;
            option.text = device.label;
            selectCamera.appendChild(option);
          }
          selectPostMicrophone.innerHTML = selectMicrophone.innerHTML;
          selectPostCamera.innerHTML = selectCamera.innerHTML;
      });
      /*stream.getTracks().forEach(track => {
          track.stop();
        });*/
        setConstraints(selectCamera.value, selectMicrophone.value, selectSoundOutput.value, video);
    });
  })
  .catch(error => {
    console.error('Error :', error);
  });
}

selectCamera.addEventListener('change', () => {
    selectPostCamera.value = selectCamera.value;
    setConstraints(selectCamera.value, selectMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
});
selectPostCamera.addEventListener('change', async () => {
  await setConstraints(selectPostCamera.value, selectPostMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
  selectPostCamera.parentElement.parentElement.classList.add('is-hidden');
  selectPostCamera.parentElement.parentElement.parentElement.classList.add('is-hidden');
});
selectSoundOutput.addEventListener('change', () => {
    setConstraints(selectCamera.value, selectMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
});
selectMicrophone.addEventListener('change', () => {
    selectMicrophone.value = selectPostMicrophone.value;
    setConstraints(selectCamera.value, selectMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
});
selectPostMicrophone.addEventListener('change', async () => {
  await setConstraints(selectPostCamera.value, selectPostMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
  selectPostMicrophone.parentElement.parentElement.classList.add('is-hidden');
  selectPostMicrophone.parentElement.parentElement.parentElement.classList.add('is-hidden');
});

async function setConstraints(camera, microphone, soundoutput, video = true) {
  let newConstraints;
  if (video) {
    newConstraints = {
        audio: {deviceId: microphone ? {exact: microphone} : undefined},
        video: {deviceId: camera ? {exact: camera} : undefined}
      };
  } else {
    newConstraints = {
      audio: {deviceId: microphone ? {exact: microphone} : undefined},
      video: false
    };
  }
      if ("setSinkId" in AudioContext.prototype && soundoutput !== 'default') {
        await audioContext.setSinkId(soundoutput);
      }
      navigator.mediaDevices.getUserMedia(newConstraints)
      .then(gotStream)
      .catch(error => {
         console.error('Error :', error);
      });
}

function gotStream(stream) {
    if (typeof me !== 'undefined') {
      me.streams = [stream];
      if (!videoButton.classList.contains('is-disabled')) {
        me.cameraOn();
      }
    }
    const video = document.getElementById('videoPreview');
    meet.setStream(stream);
    video.srcObject = stream;
    video.muted = true;
    video.onloadedmetadata = function() {
        video.play();
    };
}

videoButton.addEventListener('click', () => {
  if (videoButton.classList.contains('is-disabled')) {
    videoButton.classList.remove('is-disabled');
    meet.stream.getVideoTracks().forEach(track => {
      track.enabled = true;
    });
    me.cameraOn();
    meet.sendMessage("camon", meet.stream.id);
  } else {
    videoButton.classList.add('is-disabled');
    meet.stream.getVideoTracks().forEach(track => {
      track.enabled = !track.enabled;
    });
    me.cameraOff();
    meet.sendMessage("camoff", meet.stream.id);
  }
});

preVideoButton.addEventListener('click', () => {
  if (preVideoButton.classList.contains('is-disabled')) {
    preVideoButton.classList.remove('is-disabled');
    videoButton.classList.remove('is-disabled');
    meet.stream.getVideoTracks().forEach(track => {
      track.enabled = true;
    });
    me.cameraOn();
    meet.sendMessage("camon", meet.stream.id);
  } else {
    preVideoButton.classList.add('is-disabled');
    videoButton.classList.add('is-disabled');
    meet.stream.getVideoTracks().forEach(track => {
      track.enabled = !track.enabled;
    });
    me.cameraOff();
    meet.sendMessage("camoff", meet.stream.id);
  }
});

audioSelectButton.addEventListener('click', () => {
  const postMediaSettings = document.getElementById('postmediasettings');
  const controlPostMicrophone = document.getElementById('controlpostmicrophone');
  const controlPosCamera = document.getElementById('controlpostcamera');
  const emojiPanel = document.getElementById('emojipanel');
  if (postMediaSettings.classList.contains('is-hidden')) {
    postMediaSettings.classList.remove('is-hidden');
    controlPostMicrophone.classList.remove('is-hidden');
    controlPosCamera.classList.add('is-hidden');
    emojiPanel.classList.add('is-hidden');
  } else {
    postMediaSettings.classList.add('is-hidden');
    controlPostMicrophone.classList.add('is-hidden');
    controlPosCamera.classList.add('is-hidden');
    emojiPanel.classList.add('is-hidden');
  }
});

videoSelectButton.addEventListener('click', () => {
  const postMediaSettings = document.getElementById('postmediasettings');
  const controlPostMicrophone = document.getElementById('controlpostmicrophone');
  const controlPosCamera = document.getElementById('controlpostcamera');
  const emojiPanel = document.getElementById('emojipanel');
  if (postMediaSettings.classList.contains('is-hidden')) {
    postMediaSettings.classList.remove('is-hidden');
    controlPosCamera.classList.remove('is-hidden');
    controlPostMicrophone.classList.add('is-hidden');
    emojiPanel.classList.add('is-hidden');
  } else {
    postMediaSettings.classList.add('is-hidden');
    controlPosCamera.classList.add('is-hidden');
    controlPostMicrophone.classList.add('is-hidden');
    emojiPanel.classList.add('is-hidden');
  }
});

openEmoji.addEventListener('click', () => {
  const postMediaSettings = document.getElementById('postmediasettings');
  const emojiPanel = document.getElementById('emojipanel');
  const controlPosCamera = document.getElementById('controlpostcamera');
  const controlPostMicrophone = document.getElementById('controlpostmicrophone');
  if (emojiPanel.classList.contains('is-hidden')) {
    postMediaSettings.classList.add('is-hidden');
    controlPosCamera.classList.add('is-hidden');
    controlPostMicrophone.classList.add('is-hidden');
    emojiPanel.classList.remove('is-hidden');
  } else {
    postMediaSettings.classList.add('is-hidden');
    controlPosCamera.classList.add('is-hidden');
    controlPostMicrophone.classList.add('is-hidden');
    emojiPanel.classList.add('is-hidden');
  }
});

audioButton.addEventListener('click', () => {
  if (audioButton.classList.contains('is-disabled')) {
    audioButton.classList.remove('is-disabled');
    meet.stream.getAudioTracks().forEach(track => {
      track.enabled = true;
    });
    meet.sendMessage("unmute", meet.stream.id);
  } else {
    audioButton.classList.add('is-disabled');
    meet.stream.getAudioTracks().forEach(track => {
      track.enabled = !track.enabled;
    });
    meet.sendMessage("mute", meet.stream.id);
  }
});

preAudioButton.addEventListener('click', () => {
  if (preAudioButton.classList.contains('is-disabled')) {
    preAudioButton.classList.remove('is-disabled');
    audioButton.classList.remove('is-disabled');
    meet.stream.getAudioTracks().forEach(track => {
      track.enabled = true;
    });
    meet.sendMessage("unmute", meet.stream.id);
  } else {
    preAudioButton.classList.add('is-disabled');
    audioButton.classList.add('is-disabled');
    meet.stream.getAudioTracks().forEach(track => {
      track.enabled = !track.enabled;
    });
    meet.sendMessage("mute", meet.stream.id);
  }
});

leaveMeetingButton.addEventListener('click', () => {
  window.location.reload();
});

raiseHandButton.addEventListener('click', () => {
  if (raiseHandButton.classList.contains('is-warning')) {
    raiseHandButton.classList.remove('is-warning');
    meet.sendMessage("lowerhand");
  } else {
    raiseHandButton.classList.add('is-warning');
    meet.sendMessage("raisehand");
  }
});

chatInput.addEventListener('keydown', (event) => {
  const chatContent = document.getElementById('chatcontent');
  const messageElement = document.createElement('p');
  const participantColor = me.color;
  const currentTime = new Date().toLocaleTimeString();

  if (event.key === 'Enter') {
    // Handle the chat input here
    const message = chatInput.value;
    const sanMessage = document.createTextNode(message);
    // Do something with the message
    meet.sendMessage('chat', sanMessage.textContent);

    const nameElement = document.createElement('span');
    nameElement.style.color = participantColor;
    nameElement.textContent = me.name;
    messageElement.appendChild(nameElement);

    messageElement.append(` ${sanMessage.textContent} `);

    const timeElement = document.createElement('span');
    timeElement.style.color = 'grey';
    timeElement.textContent = currentTime;
    messageElement.appendChild(timeElement);

    chatContent.appendChild(messageElement);
    // Clear the chat input
    chatInput.value = '';
  }
});

chatInput.addEventListener('click', () => {
  if (chatInput.value === '') return;
  const chatContent = document.getElementById('chatcontent');
  const messageElement = document.createElement('p');
  const participantColor = me.color;
  const currentTime = new Date().toLocaleTimeString();

  const message = chatInput.value;
  const sanMessage = document.createTextNode(message);
  meet.sendMessage('chat', sanMessage.textContent);

  const nameElement = document.createElement('span');
  nameElement.style.color = participantColor;
  nameElement.textContent = me.name;
  messageElement.appendChild(nameElement);

  messageElement.append(` ${sanMessage.textContent} `);

  const timeElement = document.createElement('span');
  timeElement.style.color = 'grey';
  timeElement.textContent = currentTime;
  messageElement.appendChild(timeElement);

  chatContent.appendChild(messageElement);
  // Clear the chat input
  chatInput.value = '';
});

chatClose.addEventListener('click', () => {
  const chatDiv = document.getElementById('chat');
  chatDiv.style.transition = 'transform 1s ease';
  chatDiv.style.transform = 'translateX(100%)';
  setTimeout(() => {
    chatDiv.style.display = 'none';
  }, 1000);
});

chatOpen.addEventListener('click', () => {
  const chatDiv = document.getElementById('chat');
  chatDiv.style.display = 'block';
  chatDiv.style.transform = 'translateX(0)';
});

document.querySelectorAll('.emoji').forEach(emoji => {
  emoji.addEventListener('click', () => {
    // Handle emoji click event here
    handleEmote(emoji.innerHTML);
    meet.sendMessage('emote', emoji.innerHTML);
  });
});

const handleEmote = (emote) => {
  const showEmoji = document.createElement('div');
  showEmoji.classList.add('emote');
  showEmoji.innerHTML = emote;
  document.body.appendChild(showEmoji);
  setTimeout(() => {
    showEmoji.remove();
  }, 5500);
};

openEmojiSmile.addEventListener('click', () => {
  const emojiSmile = document.getElementById('emojismile');
  const emojiCat = document.getElementById('emojicat');
  const emojiTransport = document.getElementById('emojitransport');
  const emojioffice = document.getElementById('emojioffice');
  const emojiAnimals = document.getElementById('emojianimals');

  emojiSmile.classList.remove('is-hidden');
  emojiCat.classList.add('is-hidden');
  emojiTransport.classList.add('is-hidden');
  emojioffice.classList.add('is-hidden');
  emojiAnimals.classList.add('is-hidden');
});

openEmojiCat.addEventListener('click', () => {
  const emojiSmile = document.getElementById('emojismile');
  const emojiCat = document.getElementById('emojicat');
  const emojiTransport = document.getElementById('emojitransport');
  const emojioffice = document.getElementById('emojioffice');
  const emojiAnimals = document.getElementById('emojianimals');

  emojiSmile.classList.add('is-hidden');
  emojiCat.classList.remove('is-hidden');
  emojiTransport.classList.add('is-hidden');
  emojioffice.classList.add('is-hidden');
  emojiAnimals.classList.add('is-hidden');
});

openEmojiTransport.addEventListener('click', () => {
  const emojiSmile = document.getElementById('emojismile');
  const emojiCat = document.getElementById('emojicat');
  const emojiTransport = document.getElementById('emojitransport');
  const emojioffice = document.getElementById('emojioffice');
  const emojiAnimals = document.getElementById('emojianimals');

  emojiSmile.classList.add('is-hidden');
  emojiCat.classList.add('is-hidden');
  emojiTransport.classList.remove('is-hidden');
  emojioffice.classList.add('is-hidden');
  emojiAnimals.classList.add('is-hidden');
});

openEmojioffice.addEventListener('click', () => {
  const emojiSmile = document.getElementById('emojismile');
  const emojiCat = document.getElementById('emojicat');
  const emojiTransport = document.getElementById('emojitransport');
  const emojioffice = document.getElementById('emojioffice');
  const emojiAnimals = document.getElementById('emojianimals');

  emojiSmile.classList.add('is-hidden');
  emojiCat.classList.add('is-hidden');
  emojiTransport.classList.add('is-hidden');
  emojioffice.classList.remove('is-hidden');
  emojiAnimals.classList.add('is-hidden');
});

openEmojiAnimals.addEventListener('click', () => {
  const emojiSmile = document.getElementById('emojismile');
  const emojiCat = document.getElementById('emojicat');
  const emojiTransport = document.getElementById('emojitransport');
  const emojioffice = document.getElementById('emojioffice');
  const emojiAnimals = document.getElementById('emojianimals');

  emojiSmile.classList.add('is-hidden');
  emojiCat.classList.add('is-hidden');
  emojiTransport.classList.add('is-hidden');
  emojioffice.classList.add('is-hidden');
  emojiAnimals.classList.remove('is-hidden');
}
);

screenShareButton.addEventListener('click', async () => {
  if (screenShareButton.classList.contains('is-warning')) {
    screenShareButton.classList.remove('is-warning');
    if (meet.screenShareStream) {
      me.screenshareId = null;
      me.update({name: meet.name, id: meet.id, streams: [meet.stream], screenshareStreams: [], tracks: meet.stream.getTracks() , screenshareTracks: []});
      me.hideScreenShare();
      meet.screenShareStream.getTracks().forEach(track => track.stop());
      meet.sendMessage('screenshareoff', me.screenshareId);
      meet.setScreenShareStream(null); // Assuming this method also handles cleanup
    }
  } else {
    screenShareButton.classList.add('is-warning');
    screenShareStream = await navigator.mediaDevices.getDisplayMedia({
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
    me.screenshareId = screenShareStream.id;
    me.update({name: meet.name, id: meet.id, streams: [meet.stream], screenshareStreams: [screenShareStream], tracks: meet.stream.getTracks(), screenshareTracks: screenShareStream.getTracks()});
    meet.setScreenShareStream(screenShareStream);
    meet.sendMessage('screenshare', me.screenshareId);
    screenShareStream.getVideoTracks()[0].addEventListener('ended', () => {
      me.screenshareId = null;
      me.update({name: meet.name, id: meet.id, streams: [meet.stream], screenshareStreams: [],  tracks: meet.stream.getTracks(), screenshareTracks: []});
      me.hideScreenShare();
      meet.screenShareStream.getTracks().forEach(track => track.stop());
      screenShareButton.classList.remove('is-warning');
      meet.sendMessage('screenshareoff', me.screenshareId);
      // Handle the stop action here, e.g., clean up or UI update
    });
  }
});

nameInput.addEventListener('input', () => {
  if (settings.instantMeeting && nameInput.value !== "") document.getElementById("joinmeeting").removeAttribute("disabled");
    if (settings.scheduledMeeting && nameInput.value !== "") {
      let startDate = new Date(settings.meetingDate);
      if (startDate < new Date(new Date().getTime() + 30 * 60000)) {
        document.getElementById("joinmeeting").removeAttribute("disabled");
      }
    }
    if (nameInput.value === "") document.getElementById("joinmeeting").setAttribute("disabled", "disabled");
});

openSubtitle.addEventListener('click', () => {
  const subtitle = document.getElementById('subtitlemodal');
    subtitle.classList.add('is-active');
});

document.getElementById('closesubtitlemodal').addEventListener('click', () => {
  const subtitle = document.getElementById('subtitlemodal');
  subtitle.classList.remove('is-active');
});

document.getElementById('closemoreoptions').addEventListener('click', () => {
  const subtitle = document.getElementById('moreoptions');
  subtitle.classList.remove('is-active');
});

document.getElementById('opencaptionwindows').addEventListener('click', event => {
  const opencaption = document.getElementById('opencaption');
  Array.from(opencaption.children).forEach(li => {
    li.classList.remove('is-active');
  });
  event.target.parentElement.classList.add('is-active');

  const captionDescElements = document.querySelectorAll('.captiondesc');
  captionDescElements.forEach(element => {
    element.classList.add('is-hidden');
  });

  document.getElementById('captionwindows').classList.remove('is-hidden');
});

document.getElementById('opencaptionchrome').addEventListener('click', event => {
  const opencaption = document.getElementById('opencaption');
  Array.from(opencaption.children).forEach(li => {
    li.classList.remove('is-active');
  });
  event.target.parentElement.classList.add('is-active');

  const captionDescElements = document.querySelectorAll('.captiondesc');
  captionDescElements.forEach(element => {
    element.classList.add('is-hidden');
  });

  document.getElementById('captionchrome').classList.remove('is-hidden');
});

document.getElementById('opencaptionsafari').addEventListener('click', event => {
  const opencaption = document.getElementById('opencaption');
  Array.from(opencaption.children).forEach(li => {
    li.classList.remove('is-active');
  });
  event.target.parentElement.classList.add('is-active');

  const captionDescElements = document.querySelectorAll('.captiondesc');
  captionDescElements.forEach(element => {
    element.classList.add('is-hidden');
  });

  document.getElementById('captionsafari').classList.remove('is-hidden');
});

document.getElementById('opencaptionfirefox').addEventListener('click', event => {
  const opencaption = document.getElementById('opencaption');
  Array.from(opencaption.children).forEach(li => {
    li.classList.remove('is-active');
  });
  event.target.parentElement.classList.add('is-active');

  const captionDescElements = document.querySelectorAll('.captiondesc');
  captionDescElements.forEach(element => {
    element.classList.add('is-hidden');
  });

  document.getElementById('captionfirefox').classList.remove('is-hidden');
});

document.getElementById('opencaptionedge').addEventListener('click', event => {
  const opencaption = document.getElementById('opencaption');
  Array.from(opencaption.children).forEach(li => {
    li.classList.remove('is-active');
  });
  event.target.parentElement.classList.add('is-active');

  const captionDescElements = document.querySelectorAll('.captiondesc');
  captionDescElements.forEach(element => {
    element.classList.add('is-hidden');
  });

  document.getElementById('captionedge').classList.remove('is-hidden');
});

document.getElementById('openmoreoptions').addEventListener('click', () => {
  const moreoptions = document.getElementById('moreoptions');
  moreoptions.classList.add('is-active');
});