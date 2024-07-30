const config = {};

config.domain = 'peerwave.org';
config.port = 3000;
config.db = {
    type: 'sqlite',
    path: 'db/peerwave.db'
};
config.buymeacoffee = true;
config.documentation = true;
config.quickhost = true;
config.channels = true;
config.github = true;
config.about = true;

module.exports = config;