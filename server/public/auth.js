// Helper functions for URL-safe base64 encoding and decoding
function base64UrlEncode(buffer) {
    return btoa(String.fromCharCode(...new Uint8Array(buffer)))
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/, '');
}

function base64UrlDecode(base64) {
    if (typeof base64 !== 'string') {
        console.error('base64UrlDecode expected a string, got:', base64, 'Type:', typeof base64);
        throw new TypeError('Expected input to be a string');
    }
    base64 = base64
        .replace(/-/g, '+')
        .replace(/_/g, '/');
    // Pad with '=' to make the length a multiple of 4
    while (base64.length % 4) {
        base64 += '=';
    }
    return Uint8Array.from(atob(base64), c => c.charCodeAt(0)).buffer;
}


// Get the login button element
const loginButton = document.getElementById('login');

// Add a click event listener to the login button
loginButton.addEventListener('click', async () => {
    try {
        // Check if WebAuthn is supported by the browser
        if (!window.PublicKeyCredential) {
            throw new Error('WebAuthn is not supported');
        }

        // Request a new WebAuthn credential from the server
        const credential = await fetch('/webauthn/authenticate-challenge', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ email: document.getElementById('email').value })
            // Add any necessary headers and body for the request
        }).then(response => response.json());

        console.log(credential);

        // Create a new PublicKeyCredential object
        credential.challenge = base64UrlDecode(credential.challenge);
        credential.allowCredentials.forEach(cred => {
            cred.id = base64UrlDecode(cred.id);
        });

        // Use the PublicKeyCredential object to perform the WebAuthn authentication
        const assertion = await navigator.credentials.get({ publicKey: credential });
        

        // Send the authentication assertion to the server for verification
        const response = await fetch('/webauthn/authenticate', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                email: document.getElementById('email').value,
                assertion: {
                    id: assertion.id,
                    rawId: base64UrlEncode(assertion.rawId),
                    type: assertion.type,
                    response: {
                        authenticatorData: base64UrlEncode(assertion.response.authenticatorData),
                        clientDataJSON: base64UrlEncode(assertion.response.clientDataJSON),
                        signature: base64UrlEncode(assertion.response.signature),
                        userHandle: assertion.response.userHandle ? base64UrlEncode(assertion.response.userHandle) : null
                    }
                } 
            })
        }).then(response => {
            if (response.redirected) {
                window.location.href = response.url;
            }
            //response.json());
        });
            

        // Handle the server response and perform any necessary actions
        // based on the authentication result

    } catch (error) {
        console.error('WebAuthn authentication failed:', error);
    }
});