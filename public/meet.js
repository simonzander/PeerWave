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
const participants = {};

const meet = new Meet(socket, config, document.getElementById("room").value);

meet.callbackMessage = function(id, name, type, message) {
  if (id === meet.id) return;
  const divAttendee = document.querySelector(`[data-id="${id}"]`);
  const muteSpan = document.getElementById(`${id}-mute`);
  const handSpan = document.getElementById(`${id}-hand`);
  const chatContent = document.getElementById('chatcontent');
  const messageElement = document.createElement('p');
  const participantColor = participants[id].color;
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
      break;
    case 'leave':
      // Handle leave message
      delete participants[id];
      divAttendee.remove();
      break;
    case 'join':
      bulmaToast.toast({ message: `${name} joined the meeting`, type: "is-info", position: "bottom-left"});
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

  // Create a class for each participant
  class Participant {
    constructor(participant, streams, muted = false) {
      this.name = participant.name;
      this.id = participant.id;

      this.muted = muted;

      this.streams = streams;

      this.hasVideo = streams[0].getVideoTracks().length > 0;
      this.hasAudio = streams[0].getAudioTracks().length > 0;

      this.color = colors[Math.floor(Math.random() * colors.length)];
      //this.hasVideo = this.peerConnection.getReceivers().find(receiver => receiver.track.kind === 'video');
      //this.hasAudio = this.peerConnection.getReceivers().find(receiver => receiver.track.kind === 'audio');
    }

    cameraOff() {
      const div = document.getElementById("attendees");
      let divAttendee = div.querySelector(`[data-id="${this.id}"]`);
      divAttendee.classList.add('attendee-novideo');
      divAttendee.classList.remove('attendee-video');
      divAttendee.innerHTML = ``;
      const audioElement = document.createElement("audio");
      audioElement.srcObject = this.streams[0];
      audioElement.autoplay = true;
      audioElement.muted = this.muted;
      
      divAttendee.innerHTML = `<span style="background-color: ${this.color}"><p class="p-center">${this.name.charAt(0)}</p></span>`;
      divAttendee.appendChild(audioElement);
      div.appendChild(divAttendee);

      /*const divName = document.createElement("div");
      divName.classList.add("attendee-name");
      divName.innerHTML = `${this.name}`;
      divAttendee.appendChild(divName);*/
    }

    cameraOn() {
      const div = document.getElementById("attendees");
      let divAttendee = div.querySelector(`[data-id="${this.id}"]`);
      divAttendee.classList.remove('attendee-novideo');
      divAttendee.classList.add('attendee-video');
      divAttendee.innerHTML = ``;
      const videoElement = document.createElement("video");
      videoElement.muted = this.muted;
      videoElement.srcObject = this.streams[0];
      videoElement.autoplay = true;
      divAttendee.appendChild(videoElement);
      div.appendChild(divAttendee);

      const divName = document.createElement("div");
      divName.classList.add("attendee-name");
      divName.innerHTML = `<span id="${this.id}-mute"></span><span id="${this.id}-hand"></span><span>${this.name}</span>`;
      divAttendee.appendChild(divName);
    }

    addToDOM() {
      const div = document.getElementById("attendees");
      let divAttendee = div.querySelector(`[data-id="${this.id}"]`);
      if (!divAttendee) {
        divAttendee = document.createElement("div");
        divAttendee.setAttribute("data-id", this.id);
      }
      divAttendee.innerHTML = ``;

     // console.log("STREAMS", this.streams[0].getVideoTracks(), this.streams[0].getAudioTracks());

     if (this.hasVideo) {
      divAttendee.classList.remove('attendee-novideo');
      divAttendee.classList.add('attendee-video');
      const videoElement = document.createElement("video");
      videoElement.muted = this.muted;
      videoElement.srcObject = this.streams[0];
      videoElement.autoplay = true;
      divAttendee.appendChild(videoElement);
     }
     if (this.hasAudio && !this.hasVideo) {
      divAttendee.classList.add('attendee-novideo');
      divAttendee.classList.remove('attendee-video');
      const audioElement = document.createElement("audio");
      audioElement.srcObject = this.streams[0];
      audioElement.autoplay = true;
      audioElement.muted = this.muted;
      divAttendee.innerHTML = `<span><p class="p-center">${this.name.charAt(0)}</p></span>`;
      divAttendee.appendChild(audioElement);
     }

     const divName = document.createElement("div");
     divName.classList.add("attendee-name");
     divName.innerHTML = `<span id="${this.id}-mute"></span><span id="${this.id}-hand"></span><span>${this.name}</span>`;
     divAttendee.appendChild(divName);
      
      const audioCtx = new AudioContext();
      const source = audioCtx.createMediaStreamSource(this.streams[0]);
      const analyser = audioCtx.createAnalyser();
      analyser.fftSize = 256;

      const bufferLength = analyser.frequencyBinCount;
      const dataArray = new Uint8Array(bufferLength);

      source.connect(analyser);
      //analyser.connect(audioCtx.destination);

      /*const canvas = document.getElementById("canvastest");
      const canvasCtx = canvas.getContext("2d");*/

      const visualize = async () => {
        if (divAttendee.classList.contains("attendee-video")) divAttendee.classList.remove("speak-animation-video");
        if (divAttendee.classList.contains("attendee-novideo")) divAttendee.firstChild.classList.remove("speak-animation-novideo");

        requestAnimationFrame(visualize);

        /*canvasCtx.fillStyle = "rgb(0, 0, 0)";
        canvasCtx.fillRect(0, 0, 250, 250);*/

        analyser.getByteFrequencyData(dataArray);

        /*const barWidth = (250 / bufferLength) * 2.5;
        let x = 0;*/

        for (let i = 0; i < bufferLength; i++) {
          /*const barHeight = dataArray[i];

          canvasCtx.fillStyle = "rgb(" + (barHeight + 100) + ",50,50)";
          canvasCtx.fillRect(
            x,
            250 - barHeight / 2,
            barWidth,
            barHeight / 2
          );

          x += barWidth + 1;*/

          if (dataArray[i] > 128 && divAttendee.classList.contains("attendee-video")) divAttendee.classList.add("speak-animation-video");
          if (dataArray[i] > 128 && divAttendee.classList.contains("attendee-novideo")) divAttendee.firstChild.classList.add("speak-animation-novideo");

        
        }

      };

      visualize();
      
      /*if (this.hasVideo) {
        const videoElement = document.createElement("video");
        const videoTrack = this.peerConnection.getReceivers().find(receiver => receiver.track.kind === 'video').track;
        videoElement.srcObject = videoTrack;
        videoElement.autoplay = true;
        divAttendee.appendChild(videoElement);
      }*/
      /*if (this.hasAudio && !this.hasVideo) {
        const audioElement = document.createElement("audio");
        const audioTrack = this.peerConnection.getReceivers().find(receiver => receiver.track.kind === 'audio').track;
        const audioStream = new MediaStream([audioTrack]);
        audioElement.srcObject = audioStream;
        audioElement.autoplay = true;
        divAttendee.innerHTML = `
        <span><p class="p-center">${this.name.charAt(0)}</p></span>
      `;
        divAttendee.appendChild(audioElement);
      }*/
      div.appendChild(divAttendee);
    }
  }

meet.callbackParticipantJoined = function(participant, streams) {
  // Create a new Participant instance and add it to the DOM
  participants[participant.id] = new Participant(participant, streams);
  participants[participant.id].addToDOM();
};

document.addEventListener('DOMContentLoaded', () => {

  const adjustChildSizes = () => {
    const divWidth = flexMeeting.offsetWidth;
    const divHeight = flexMeeting.offsetHeight;


    // Determine the smallest width and height among children
    const children = Array.from(flexMeeting.children);
    const childrenCount = children.length;

    children.forEach(child => {
          switch (true) {
            case childrenCount === 1:
              child.style.width = `calc(${divWidth}px - 64px)`;
              child.style.height = `calc(${divHeight}px - 64px)`;
              break;
            case childrenCount === 2:
              child.style.width = `calc(${divWidth / 2}px - 64px)`;
              child.style.height = `calc(${divHeight}px - 64px)`;
              break;
            case childrenCount === 3 || childrenCount === 4:
              child.style.width = `calc(${divWidth / 2}px - 64px)`;
              child.style.height = `calc(${divHeight / 2}px - 64px)`;
              break;
            case childrenCount >= 5 && childrenCount <= 12 :
              child.style.width = `calc(${divWidth / 4}px - 64px)`;
              child.style.height = `calc(${divHeight / 3}px - 64px)`;
              break;
            default:
              child.style.width = `calc(${divWidth / 4}px - 64px)`;
              child.style.height = `calc(${divHeight / 4}px - 64px)`;
              break;
          }
          
    });

    // Set all child elements to have this width and height
    /*Array.from(flexMeeting.children).forEach(child => {
        child.style.width = `${minWidth}px`;
        child.style.height = `${minHeight}px`;
    });*/
  };

  const flexMeeting = document.getElementById('attendees');

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
  getUserMedia(true, !settings.voiceOnly);
  if (settings.voiceOnly) {
    videoButton.classList.add("is-disabled");
    videoButton.disabled = true;
    preVideoButton.classList.add("is-disabled");
    preVideoButton.disabled = true;
    document.getElementById("camera").disabled = true;
  }
}

function buildLayout() {
  const div = document.getElementById("attendees");
  div.innerHTML = "";
  me = new Participant({name: meet.name, id: meet.id}, [meet.stream], true);
  me.addToDOM();

  if (!me.hasAudio) {
    audioButton.classList.add("is-disabled");
  } else {
    audioButton.classList.remove("is-disabled");
  }
  if (!me.hasVideo) {
    videoButton.classList.add("is-disabled");
  } else {
    videoButton.classList.remove("is-disabled");
  }


  /*Object.entries(participants).forEach(([id, participant]) => {
    console.log(participant);
    const divAttendee = document.createElement("div");
    divAttendee.classList.add("attendee-novideo");
    divAttendee.setAttribute("data-id", id);
    divAttendee.innerHTML = `
      <span><p class="p-center">${participant.name.charAt(0)}</p></span>
    `;
    div.appendChild(divAttendee);
  });*/
}

function getParticipants(res) {
  const participants = res.participants;
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
  .then(stream => {
    if (settings.instantMeeting) document.getElementById("joinmeeting").removeAttribute("disabled");
    if (settings.scheduledMeeting) {
      const startDate = new Date(settings.meetingDate);
      document.getElementById("meetingdate").innerText = startDate.toUTCString();
      console.log(startDate < new Date() + 30 * 60000, startDate, new Date() + 30 * 60000);
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
    console.log('Error :', error);
  });
}

selectCamera.addEventListener('change', event => {
    selectPostCamera.value = selectCamera.value;
    setConstraints(selectCamera.value, selectMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
});
selectPostCamera.addEventListener('change', event => {
  setConstraints(selectPostCamera.value, selectPostMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
  selectPostCamera.parentElement.parentElement.classList.add('is-hidden');
  selectPostCamera.parentElement.parentElement.parentElement.classList.add('is-hidden');
});
selectSoundOutput.addEventListener('change', event => {
    setConstraints(selectCamera.value, selectMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
});
selectMicrophone.addEventListener('change', event => {
    selectMicrophone.value = selectPostMicrophone.value;
    setConstraints(selectCamera.value, selectMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
});
selectPostMicrophone.addEventListener('change', event => {
  setConstraints(selectPostCamera.value, selectPostMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
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
      navigator.mediaDevices.getUserMedia(newConstraints).then(gotStream).catch(error => { console.error('Error :', error); });
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
    video.onloadedmetadata = function(e) {
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
    meet.sendMessage("camon");
  } else {
    videoButton.classList.add('is-disabled');
    meet.stream.getVideoTracks().forEach(track => {
      track.enabled = !track.enabled;
    });
    me.cameraOff();
    meet.sendMessage("camoff");
  }
});

audioSelectButton.addEventListener('click', () => {
  const postMediaSettings = document.getElementById('postmediasettings');
  const controlPostMicrophone = document.getElementById('controlpostmicrophone');
  const controlPosCamera = document.getElementById('controlpostcamera');
  if (postMediaSettings.classList.contains('is-hidden')) {
    postMediaSettings.classList.remove('is-hidden');
    controlPostMicrophone.classList.remove('is-hidden');
  } else {
    postMediaSettings.classList.add('is-hidden');
    controlPostMicrophone.classList.add('is-hidden');
    controlPosCamera.classList.add('is-hidden');
  }
});

videoSelectButton.addEventListener('click', () => {
  const postMediaSettings = document.getElementById('postmediasettings');
  const controlPostMicrophone = document.getElementById('controlpostmicrophone');
  const controlPosCamera = document.getElementById('controlpostcamera');
  if (postMediaSettings.classList.contains('is-hidden')) {
    postMediaSettings.classList.remove('is-hidden');
    controlPosCamera.classList.remove('is-hidden');
  } else {
    postMediaSettings.classList.add('is-hidden');
    controlPosCamera.classList.add('is-hidden');
    controlPostMicrophone.classList.add('is-hidden');
  }
});

audioButton.addEventListener('click', () => {
  if (audioButton.classList.contains('is-disabled')) {
    audioButton.classList.remove('is-disabled');
    meet.stream.getAudioTracks().forEach(track => {
      track.enabled = true;
    });
    meet.sendMessage("unmute");
  } else {
    audioButton.classList.add('is-disabled');
    meet.stream.getAudioTracks().forEach(track => {
      track.enabled = !track.enabled;
    });
    meet.sendMessage("mute");
  }
});

leaveMeetingButton.addEventListener('click', () => {
  //meet.leave();
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
    // Do something with the message
    meet.sendMessage('chat', message);
    messageElement.innerHTML = `<span style="color: ${participantColor}">${me.name}:</span> ${message} <span style="color:grey">${currentTime}</span>`;
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
  meet.sendMessage('chat', message);
  messageElement.innerHTML = `<span style="color: ${participantColor}">${me.name}:</span> ${message} <span style="color:grey">${currentTime}</span>`;
  chatContent.appendChild(messageElement);
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