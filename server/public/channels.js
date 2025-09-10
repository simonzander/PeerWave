document.getElementById('add-channel').addEventListener('click', () => {
    const createchannelmodal = document.getElementById('createchannelmodal');
    createchannelmodal.classList.add('is-active');
  });

document.getElementById('addchannelform').addEventListener('submit', (event) => {
    event.preventDefault();

    const formData = new FormData(event.target);
    const name = formData.get('name');
    const description = formData.get('description');
    const isPrivate = formData.get('isPrivate');
    const type = formData.get('type');

    console.log({ name, description, isPrivate, type });

    console.log(event);
    // Perform further actions with the form data
    fetch('/channels/create', {
        method: 'POST',
        body: JSON.stringify({ name, description, isPrivate, type }),
        headers: {
            'Content-Type': 'application/json'
        }
    })
        .then(response => response.json())
        .then(result => {
            event.target.parentElement.parentElement.classList.remove('is-active');
            window.location.assign(`/channel/${result.name}`);
        })
        .catch(error => {
            // Handle any errors here
            console.error(error);
        });
});
if (document.getElementById('addthread')) {
    document.getElementById('addthread').addEventListener('submit', (event) => {
        event.preventDefault();

        const formData = new FormData(event.target);
        const message = formData.get('message');
        const channel = formData.get('channel');

        console.log(event);
        // Perform further actions with the form data
        fetch(`/channel/${channel}/post`, {
            method: 'POST',
            body: JSON.stringify({ message, channel }),
            headers: {
                'Content-Type': 'application/json'
            }
        })
            .then(response => response.json())
            .then(result => {
                window.location.reload();
            })
            .catch(error => {
                // Handle any errors here
                console.error(error);
            });
    });
}

document.getElementById('usersettings-button').addEventListener('click', () => {
    const usersettingsmodal = document.getElementById('usersettings-modal');
    usersettingsmodal.classList.add('is-active');
});

document.getElementById('usersettings-form').addEventListener('submit', async (event) => {
    event.preventDefault();

    const formData = new FormData(event.target);
    const pictureFile = formData.get('picture');
    const displayname = formData.get('displayname');

    if (pictureFile && pictureFile.type.startsWith('image/')) {
        const thumbnail = await createThumbnail(pictureFile);
        sendFormData({ picture: thumbnail, displayname });
    } else {
        sendFormData({ picture: null, displayname });
    }
});

document.getElementById('profile-picture-input').addEventListener('change', (event) => {
    const file = event.target.files[0];
    console.log(file);
    createThumbnail(file);
});

async function createThumbnail(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = (event) => {
            const img = new Image();
            img.onload = () => {
                const canvas = document.createElement('canvas');
                const ctx = canvas.getContext('2d');

                // Set the desired width and height for the thumbnail
                const width = 28;
                const height = 28;

                // Resize and crop the image
                canvas.width = width;
                canvas.height = height;
                ctx.drawImage(img, 0, 0, width, height);

                // Convert the canvas content to a base64-encoded string
                const thumbnail = canvas.toDataURL('image/jpeg');
                const profilePictureContainer = document.getElementById('profile-picture-container');
                profilePictureContainer.innerHTML = '';

                const thumbnailImage = document.createElement('img');
                thumbnailImage.style = 'border-radius: 50%; width: 28px; height: 28px; margin-right: 10px;';
                thumbnailImage.src = thumbnail;
                profilePictureContainer.appendChild(thumbnailImage);
                resolve(thumbnail);
            };
            img.src = event.target.result;
        };
        reader.onerror = (error) => reject(error);
        reader.readAsDataURL(file);
    });
}

function sendFormData(data) {
    fetch('/usersettings', {
        method: 'POST',
        body: JSON.stringify(data),
        headers: {
            'Content-Type': 'application/json'
        }
    })
    .then(response => response.json())
    .then(result => {
        window.location.reload();
    })
    .catch(error => {
        console.error(error);
    });
}

document.getElementById('reply-button').addEventListener('click', (event) => {
    const replymodal = document.getElementById('reply-modal');
    const replyForm = document.getElementById('reply-form');
    const threadId = event.target.getAttribute('data-thread-id');

    replymodal.classList.add('is-active');
    replyForm.setAttribute('data-thread-id', threadId);

    fetch('/thread/' + threadId, {
        method: 'GET',
        headers: {
            'Content-Type': 'application/json'
        }
    })
    .then(response => response.json())
    .then(data => {
        console.log(data);
        const divThread = document.createElement('div');
        divThread.classList.add('thread');
        divThread.innerHTML = `
            <div class="thread-header">
                <div class="thread-user">
                    <img src="${data.user.picture}" alt="Profile picture" class="profile-picture">
                    <span>${data.user.displayName}</span>
                </div>
                <div class="thread-timestamp">${data.createdAt}</div>
            </div>
            <div class="thread-message">${data.message}</div>
        `;
        replymodal.getElementsByClassName('modal-card-body')[0].appendChild(divThread);
    })
    .catch(error => {
        console.error(error);
    });
});