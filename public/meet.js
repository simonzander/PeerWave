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

const flexMeeting = document.getElementById('attendees');

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
      handleEmote(message);
      break;
    case 'leave':
      // Handle leave message
      delete participants[id];
      divAttendee.remove();
      adjustChildSizes();
      break;
    case 'join':
      bulmaToast.toast({ message: `${name} joined the meeting`, type: "is-info", position: "bottom-left"});
      break;
    case 'screenshare':
      console.log("SCREEN SHARE ON", message);
      participants[id].screenshareId = message;
      break;
    case 'screenshareoff':
      participants[id].screenshareId = null;
      participants[id].hideScreenShare();
      adjustChildSizes();
      break;
    case 'mediaDevice':
      console.log("MEDIA DEVICE", message);
      participants[id].mediaDeviceId = message;
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

const openEmojiSmile = document.getElementById('openemojismile');
const openEmojiCat = document.getElementById('openemojicat');
const openEmojiTransport = document.getElementById('openemojitransport');
const openEmojioffice = document.getElementById('openemojioffice');
const openEmojiAnimals = document.getElementById('openemojianimals');

  // Create a class for each participant
  class Participant {
    constructor(participant, muted = false) {
      /*if (!(stream instanceof MediaStream)) {
        console.error("stream is not an instance of MediaStream", stream);
        return; // Optionally, handle this case more gracefully
      }*/
      this.name = participant.name;
      this.id = participant.id;
      this.streams = participant.streams;
      this.tracks = participant.tracks;
      this.peerConnection = participant.peerConnection;

      this.mediaDeviceId = this.streams[0].id;

      this.muted = muted;

      //this.streams = [];

      //this.streams.push(stream);

      //console.log(stream, stream.getVideoTracks(), stream.getAudioTracks(), stream.getTracks());

      /*Object.values(stream).forEach(stream => {
        this.pushStream(stream);
      });*/

      //console.log("STREAMS", this.streams, stream.getVideoTracks());

      this.hasVideo = this.streams[0].getVideoTracks().length > 0;
      this.hasAudio = this.streams[0].getAudioTracks().length > 0;

      this.color = colors[Math.floor(Math.random() * colors.length)];
      /*streams[0].onaddtrack = (event) => {
        console.log("TRACK ADDED", event, event.track);
      };*/
      //this.hasVideo = this.peerConnection.getReceivers().find(receiver => receiver.track.kind === 'video');
      //this.hasAudio = this.peerConnection.getReceivers().find(receiver => receiver.track.kind === 'audio');
    }

    update(participant) {
      this.name = participant.name;
      this.id = participant.id;
      this.streams = participant.streams;
      this.tracks = participant.tracks;
      this.peerConnection = participant.peerConnection;

      let indexMediaDevice = this.streams.findIndex(s => s.id === this.mediaDeviceId);
      let indexScreenShare = this.streams.findIndex(s => s.id === this.screenshareId);

      this.hasVideo = this.streams[indexMediaDevice].getVideoTracks().length > 0;
      this.hasAudio = this.streams[indexMediaDevice].getAudioTracks().length > 0;

      console.log("INDEXES", indexMediaDevice, indexScreenShare, this.screenshareId, this.streams);
      if (indexScreenShare !== -1) {
        this.showScreenShare(indexScreenShare);
      }

      if (indexMediaDevice !== -1) {
        if (this.hasVideo) {
          this.cameraOn(indexMediaDevice);
        } else {
          this.cameraOff(indexMediaDevice);
        }
      }

      console.log("PARTICIPANT CLASS STREAMS", this.streams);
    }

    pushStream(stream) {
      this.streams.push(stream);
      console.log(stream.getTracks());
      /*if (!this.streams.some(s => s.id === stream.id)) {
        this.streams.push(stream);
      }
      for (let i = 0; i < this.streams.length; i++) {
        if (this.streams[i].id === stream.id) {
          this.streams[i] = stream;
        }
      }*/
      const indexMediaDevice = this.streams.findIndex(s => s.id === this.mediaDeviceId);
      const indexScreenShare = this.streams.findIndex(s => s.id === this.screenshareId);

      console.log("INDEXES", indexMediaDevice, indexScreenShare);
      if (indexScreenShare !== -1) this.showScreenShare(indexScreenShare);
      if (indexMediaDevice !== -1) this.cameraOn(indexMediaDevice);
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

      /*const divName = document.createElement("div");
      divName.classList.add("attendee-name");
      divName.innerHTML = `${this.name}`;
      divAttendee.appendChild(divName);*/
    }

    showScreenShare(index = 1) {
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
      console.log(this.streams[1].getVideoTracks(), meet.peerConnections);
      videoElement.srcObject = this.streams[index];
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
      //audioElement.srcObject = this.streams[0];
      audioElement.autoplay = true;
      audioElement.muted = this.muted;
      divAttendee.innerHTML = `<span><p class="p-center">${this.name.charAt(0)}</p></span>`;
      divAttendee.appendChild(audioElement);
     }

     const divName = document.createElement("div");
     divName.classList.add("attendee-name");
     divName.innerHTML = `<span id="${this.id}-mute"></span><span id="${this.id}-hand"></span><span>${this.name}</span>`;
     divAttendee.appendChild(divName);
      
      /*const audioCtx = new AudioContext();
      const source = audioCtx.createMediaStreamSource(this.streams[0]);
      const analyser = audioCtx.createAnalyser();
      analyser.fftSize = 256;

      const bufferLength = analyser.frequencyBinCount;
      const dataArray = new Uint8Array(bufferLength);

      source.connect(analyser);*/
      //analyser.connect(audioCtx.destination);

      /*const canvas = document.getElementById("canvastest");
      const canvasCtx = canvas.getContext("2d");*/

      /*const visualize = async () => {
        if (divAttendee.classList.contains("attendee-video")) divAttendee.classList.remove("speak-animation-video");
        if (divAttendee.classList.contains("attendee-novideo")) divAttendee.firstChild.classList.remove("speak-animation-novideo");

        requestAnimationFrame(visualize);

        /*canvasCtx.fillStyle = "rgb(0, 0, 0)";
        canvasCtx.fillRect(0, 0, 250, 250);*/

       /* analyser.getByteFrequencyData(dataArray);

        /*const barWidth = (250 / bufferLength) * 2.5;
        let x = 0;*/

       /* for (let i = 0; i < bufferLength; i++) {
          /*const barHeight = dataArray[i];

          canvasCtx.fillStyle = "rgb(" + (barHeight + 100) + ",50,50)";
          canvasCtx.fillRect(
            x,
            250 - barHeight / 2,
            barWidth,
            barHeight / 2
          );

          x += barWidth + 1;*/

         /* if (dataArray[i] > 128 && divAttendee.classList.contains("attendee-video")) divAttendee.classList.add("speak-animation-video");
          if (dataArray[i] > 128 && divAttendee.classList.contains("attendee-novideo")) divAttendee.firstChild.classList.add("speak-animation-novideo");

        
        }

      }; */

      //visualize();
      
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
        const audioStream = new MediaStream([audi  if (Object.prototype.hasOwnProperty.call(participants, participant.id)) {eam;
        audioElement.autoplay = true;
        divAttendee.innerHTML = `
        <span><p class="p-center">${this.name.charAt(0)}</p></span>
      `;
        divAttendee.appendChild(audioElement);
      }*/
      div.appendChild(divAttendee);
    }
  }

meet.callbackParticipantJoined = function(participant) {
  console.log("PARTICIPANT JOINED", participant);
  if (Object.prototype.hasOwnProperty.call(participants, participant.id)) {
    participants[participant.id].update(participant);
    //participants[participant.id].pushStream(stream);
    //participants[participant.id].streams.push(streams[0]);
    /*console.log("got new stream", streams, typeof streams);
    streams.forEach(stream => {
      console.log(stream.getVideoTracks());
      if (!participants[participant.id].streams.some(s => s.id === stream.id)) {
        participants[participant.id].pushStream(stream);
      }

    });*/
    /*if (participants[participant.id].streams[0].id !== streams[0].id) {
      participants[participant.id].showScreenShare(streams[0]);
    }*/
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
  console.log(new Date(settings.meetingDate).toUTCString());
  document.getElementById("meetingname").innerText = settings.meetingName;
  document.getElementById("meetingdescription").innerText = settings.meetingDescription;
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
  .then(stream => {
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
    console.log('Error :', error);
  });
}

selectCamera.addEventListener('change', event => {
    selectPostCamera.value = selectCamera.value;
    setConstraints(selectCamera.value, selectMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
});
selectPostCamera.addEventListener('change', async event => {
  await setConstraints(selectPostCamera.value, selectPostMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
  selectPostCamera.parentElement.parentElement.classList.add('is-hidden');
  selectPostCamera.parentElement.parentElement.parentElement.classList.add('is-hidden');
  //meet.join(document.getElementById("name").value, getParticipants);
});
selectSoundOutput.addEventListener('change', event => {
    setConstraints(selectCamera.value, selectMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
});
selectMicrophone.addEventListener('change', event => {
    selectMicrophone.value = selectPostMicrophone.value;
    setConstraints(selectCamera.value, selectMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
});
selectPostMicrophone.addEventListener('change', async event => {
  await setConstraints(selectPostCamera.value, selectPostMicrophone.value, selectSoundOutput.value, !settings.voiceOnly);
  selectPostMicrophone.parentElement.parentElement.classList.add('is-hidden');
  selectPostMicrophone.parentElement.parentElement.parentElement.classList.add('is-hidden');
  //meet.join(document.getElementById("name").value, getParticipants);
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
      me.update({name: meet.name, id: meet.id, streams: [meet.stream], tracks: meet.stream.getTracks()});
      me.hideScreenShare();
      meet.screenShareStream.getTracks().forEach(track => track.stop());
      meet.sendMessage('screenshareoff', me.screenshareId);
      meet.setScreenShareStream(null); // Assuming this method also handles cleanup
    }
  } else {
    screenShareButton.classList.add('is-warning');
    const screenShareStream = await navigator.mediaDevices.getDisplayMedia({
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
    me.update({name: meet.name, id: meet.id, streams: [meet.stream, screenShareStream], tracks: [...meet.stream.getTracks(), ...screenShareStream.getTracks()]});
    meet.setScreenShareStream(screenShareStream);
    screenShareStream.getVideoTracks()[0].addEventListener('ended', () => {
      me.screenshareId = null;
      me.update({name: meet.name, id: meet.id, streams: [meet.stream], tracks: meet.stream.getTracks()});
      me.hideScreenShare();
      meet.screenShareStream.getTracks().forEach(track => track.stop());
      screenShareButton.classList.remove('is-warning');
      meet.sendMessage('screenshareoff', me.screenshareId);
      // Handle the stop action here, e.g., clean up or UI update
    });
    meet.join(document.getElementById("name").value, getParticipants);
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
