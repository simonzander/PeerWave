const config = {};

config.domain = 'peerwave.org';
config.port = 3000;
config.db = {
    type: 'sqlite',
    path: 'db/peerwave.db'
};
config.app = {
    name: 'PeerWave',
    url: 'https://kaylie-physiopathological-kirstie.ngrok-free.dev',
    description: 'PeerWave'
};
config.buymeacoffee = true;
config.documentation = true;
config.quickhost = true;
config.channels = true;
config.github = true;
config.about = true;
config.smtp = {
    senderadress: 'No-Reply PeerWave" <no-reply@peerwave.org>',
	host: 'smtp.strato.de',
    port: 465,
	secure: true,
    auth: {
        user: 'no-reply@peerwave.org',
        pass: 'Z2ZYXGCxxam2xND'
    }
};
config.session = {
    secret: 'your-secret-key',
    resave: false,
    saveUninitialized: true,
    cookie: { secure: false } // Set to true if using HTTPS
};

module.exports = config;