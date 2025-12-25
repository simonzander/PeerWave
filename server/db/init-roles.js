/**
 * Initialize standard roles for the system
 * Must be called after database sync is complete
 */

async function initializeStandardRoles(Role) {
    try {
        const standardRoles = [
            // Server scope roles
            {
                name: 'Administrator',
                description: 'Full server access with all permissions',
                scope: 'server',
                permissions: ['*'],
                standard: true
            },
            {
                name: 'Moderator',
                description: 'Server moderator with limited admin permissions',
                scope: 'server',
                permissions: ['user.manage', 'channel.manage', 'message.moderate', 'role.create', 'role.edit', 'role.delete'],
                standard: false
            },
            {
                name: 'User',
                description: 'Standard user role',
                scope: 'server',
                permissions: ['channel.join', 'channel.create', 'message.send', 'message.read'],
                standard: false
            },
            // Channel WebRTC scope roles
            {
                name: 'Channel Owner',
                description: 'Owner of a WebRTC channel with full control',
                scope: 'channelWebRtc',
                permissions: ['*'],
                standard: true
            },
            {
                name: 'Channel Moderator',
                description: 'WebRTC channel moderator',
                scope: 'channelWebRtc',
                permissions: ['user.add', 'user.kick', 'user.mute', 'stream.manage', 'role.assign', 'member.view'],
                standard: false
            },
            {
                name: 'Channel Member',
                description: 'Regular member of a WebRTC channel',
                scope: 'channelWebRtc',
                permissions: ['stream.view', 'stream.send', 'chat.send', 'member.view'],
                standard: false
            },
            // Channel Signal scope roles
            {
                name: 'Channel Owner',
                description: 'Owner of a Signal channel with full control',
                scope: 'channelSignal',
                permissions: ['*'],
                standard: true
            },
            {
                name: 'Channel Moderator',
                description: 'Signal channel moderator',
                scope: 'channelSignal',
                permissions: ['user.add', 'message.delete', 'user.kick', 'user.mute', 'role.assign', 'member.view'],
                standard: false
            },
            {
                name: 'Channel Member',
                description: 'Regular member of a Signal channel',
                scope: 'channelSignal',
                permissions: ['message.send', 'message.read', 'message.react', 'member.view'],
                standard: false
            }
        ];

        for (const roleData of standardRoles) {
            await Role.findOrCreate({
                where: { 
                    name: roleData.name,
                    scope: roleData.scope
                },
                defaults: roleData
            });
        }
    } catch (error) {
        console.error('Error initializing standard roles:', error);
        throw error;
    }
}

module.exports = {
    initializeStandardRoles
};
