// Helper functions for URL-safe base64 encoding and decoding
function base64UrlEncode(buffer) {
    return btoa(String.fromCharCode(...new Uint8Array(buffer)))
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/, '');
}

function base64UrlDecode(base64) {
    base64 = base64
        .replace(/-/g, '+')
        .replace(/_/g, '/');
    // Pad with '=' to make the length a multiple of 4
    while (base64.length % 4) {
        base64 += '=';
    }
    return Uint8Array.from(atob(base64), c => c.charCodeAt(0)).buffer;
}


document.getElementById('addkey').addEventListener('click', async function() {
    //try {
        // Step 1: Fetch registration challenge from the server
        const challengeResponse = await fetch('/webauthn/register-challenge', {
            method: 'POST',
            credentials: 'include',
            headers: {
            'Accept': 'application/json'
            }
        });
        const challenge = await challengeResponse.json();

        console.log(challenge);

        // Step 2: Convert challenge to ArrayBuffer
        challenge.challenge = base64UrlDecode(challenge.challenge);
        challenge.user.id = base64UrlDecode(challenge.user.id);

        // Step 3: Create a new credential
        const credential = await navigator.credentials.create({ publicKey: challenge });
        console.log(credential);
        // Step 4: Convert credential response to JSON
        const attestation = {
            id: credential.id,
            rawId: base64UrlEncode(credential.rawId),
            response: {
                attestationObject: base64UrlEncode(credential.response.attestationObject),
                clientDataJSON: base64UrlEncode(credential.response.clientDataJSON)
            },
            type: credential.type
        };

        // Step 5: Send registration response to the server
        const registerResponse = await fetch('/webauthn/register', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            credentials: 'include',
            body: JSON.stringify({ username: challenge.user.name, attestation })
        });

        /*const result = await registerResponse.json();
        if (result.status === 'ok') {
            alert('Registration successful!');
        } else {
            alert('Registration failed!');
        }*/
    /*} catch (error) {
        console.error('Error during registration:', error);
        alert('Registration failed!');
    }*/
});