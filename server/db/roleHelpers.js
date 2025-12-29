const { Role, User, Channel, UserRole, UserRoleChannel } = require('./model');
const writeQueue = require('./writeQueue');

/**
 * Assign a server role to a user
 * @param {string} userId - User UUID
 * @param {string} roleId - Role UUID
 */
async function assignServerRole(userId, roleId) {
    // Verify role has scope 'server'
    const role = await Role.findByPk(roleId);
    if (!role) {
        throw new Error('Role not found');
    }
    if (role.scope !== 'server') {
        throw new Error('Role must have scope "server" for server role assignment');
    }
    
    return await writeQueue.enqueue(
        () => UserRole.findOrCreate({
            where: { userId, roleId }
        }),
        'assignServerRole'
    );
}

/**
 * Remove a server role from a user
 * @param {string} userId - User UUID
 * @param {string} roleId - Role UUID
 */
async function removeServerRole(userId, roleId) {
    return await writeQueue.enqueue(
        () => UserRole.destroy({
            where: { userId, roleId }
        }),
        'removeServerRole'
    );
}

/**
 * Assign a channel role to a user
 * @param {string} userId - User UUID
 * @param {string} roleId - Role UUID
 * @param {string} channelId - Channel UUID
 */
async function assignChannelRole(userId, roleId, channelId) {
    // Verify role has scope 'channelWebRtc' or 'channelSignal'
    const role = await Role.findByPk(roleId);
    if (!role) {
        throw new Error('Role not found');
    }
    if (role.scope !== 'channelWebRtc' && role.scope !== 'channelSignal') {
        throw new Error('Role must have scope "channelWebRtc" or "channelSignal" for channel role assignment');
    }
    
    return await writeQueue.enqueue(
        () => UserRoleChannel.findOrCreate({
            where: { userId, roleId, channelId }
        }),
        'assignChannelRole'
    );
}

/**
 * Remove a channel role from a user
 * @param {string} userId - User UUID
 * @param {string} roleId - Role UUID
 * @param {string} channelId - Channel UUID
 */
async function removeChannelRole(userId, roleId, channelId) {
    return await writeQueue.enqueue(
        () => UserRoleChannel.destroy({
            where: { userId, roleId, channelId }
        }),
        'removeChannelRole'
    );
}

/**
 * Get all server roles for a user
 * @param {string} userId - User UUID
 */
async function getUserServerRoles(userId) {
    const user = await User.findByPk(userId, {
        include: [{
            model: Role,
            as: 'ServerRoles',
            where: { scope: 'server' }
        }]
    });
    return user ? user.ServerRoles : [];
}

/**
 * Get all channel roles for a user in a specific channel
 * @param {string} userId - User UUID
 * @param {string} channelId - Channel UUID
 */
async function getUserChannelRoles(userId, channelId) {
    const roles = await UserRoleChannel.findAll({
        where: { userId, channelId },
        include: [{
            model: Role,
            as: 'Role'
        }]
    });
    return roles.map(urc => urc.Role);
}

/**
 * Check if user has a specific permission (server-wide)
 * @param {string} userId - User UUID
 * @param {string} permission - Permission string (e.g., 'user.manage')
 */
async function hasServerPermission(userId, permission) {
    const roles = await getUserServerRoles(userId);
    
    for (const role of roles) {
        const permissions = role.permissions || [];
        if (permissions.includes('*') || permissions.includes(permission)) {
            return true;
        }
    }
    
    return false;
}

/**
 * Check if user has a specific permission in a channel
 * @param {string} userId - User UUID
 * @param {string} channelId - Channel UUID
 * @param {string} permission - Permission string (e.g., 'message.send')
 */
async function hasChannelPermission(userId, channelId, permission) {
    // Check if user is channel owner (owners have all permissions)
    const channel = await Channel.findByPk(channelId);
    if (channel && channel.owner === userId) {
        return true;
    }
    
    const roles = await getUserChannelRoles(userId, channelId);
    
    for (const role of roles) {
        const permissions = role.permissions || [];
        if (permissions.includes('*') || permissions.includes(permission)) {
            return true;
        }
    }
    
    return false;
}

/**
 * Create a new role
 * @param {object} roleData - Role data (name, description, scope, permissions)
 */
async function createRole(roleData) {
    // Validate scope
    const validScopes = ['server', 'channelWebRtc', 'channelSignal'];
    if (!validScopes.includes(roleData.scope)) {
        throw new Error(`Invalid scope. Must be one of: ${validScopes.join(', ')}`);
    }
    
    return await writeQueue.enqueue(
        () => Role.create({
            name: roleData.name,
            description: roleData.description || '',
            scope: roleData.scope,
            permissions: roleData.permissions || [],
            standard: false
        }),
        'createRole'
    );
}

/**
 * Update a role (only non-standard roles can be updated)
 * @param {string} roleId - Role UUID
 * @param {object} updates - Updated role data
 */
async function updateRole(roleId, updates) {
    const role = await Role.findByPk(roleId);
    if (!role) {
        throw new Error('Role not found');
    }
    if (role.standard) {
        throw new Error('Standard roles cannot be modified');
    }
    
    return await writeQueue.enqueue(
        () => role.update(updates),
        'updateRole'
    );
}

/**
 * Delete a role (only non-standard roles can be deleted)
 * @param {string} roleId - Role UUID
 */
async function deleteRole(roleId) {
    const role = await Role.findByPk(roleId);
    if (!role) {
        throw new Error('Role not found');
    }
    if (role.standard) {
        throw new Error('Standard roles cannot be deleted');
    }
    
    return await writeQueue.enqueue(
        async () => {
            // Remove all role assignments
            await UserRole.destroy({ where: { roleId } });
            await UserRoleChannel.destroy({ where: { roleId } });
            // Delete the role
            await role.destroy();
        },
        'deleteRole'
    );
}

/**
 * Get all roles by scope
 * @param {string} scope - Scope ('server', 'channelWebRtc', 'channelSignal')
 */
async function getRolesByScope(scope) {
    return await Role.findAll({
        where: { scope }
    });
}

module.exports = {
    assignServerRole,
    removeServerRole,
    assignChannelRole,
    removeChannelRole,
    getUserServerRoles,
    getUserChannelRoles,
    hasServerPermission,
    hasChannelPermission,
    createRole,
    updateRole,
    deleteRole,
    getRolesByScope
};
