const config = require('../config/config');
const express = require("express");
const { Role, User, Channel, UserRole, UserRoleChannel, ChannelMembers } = require('../db/model');
const writeQueue = require('../db/writeQueue');
const {
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
} = require('../db/roleHelpers');
const { verifyAuthEither } = require('../middleware/sessionAuth');

const roleRoutes = express.Router();

// Middleware to check if user is authenticated (supports both session and HMAC auth)
const requireAuth = (req, res, next) => {
    const userUuid = req.userId || req.session.uuid;
    if (!userUuid) {
        return res.status(401).json({ error: 'Unauthorized' });
    }
    // Ensure req.session.uuid is set for compatibility with existing code
    if (!req.session.uuid && req.userId) {
        req.session.uuid = req.userId;
    }
    next();
};

// Middleware to check if user has specific permission
const requirePermission = (permission) => {
    return async (req, res, next) => {
        try {
            const hasPermission = await hasServerPermission(req.session.uuid, permission);
            if (!hasPermission) {
                return res.status(403).json({ error: 'Forbidden: Insufficient permissions' });
            }
            next();
        } catch (error) {
            console.error('Permission check error:', error);
            res.status(500).json({ error: 'Permission check failed' });
        }
    };
};

// GET /api/user/roles - Get current user's roles
roleRoutes.get('/user/roles', verifyAuthEither, requireAuth, async (req, res) => {
    try {
        const userId = req.session.uuid;
        
        // Get server roles
        const serverRoles = await getUserServerRoles(userId);
        
        // Get all channel roles for user
        const user = await User.findByPk(userId, {
            include: [{
                model: Role,
                as: 'ChannelRoles',
                through: {
                    attributes: ['channelId']
                },
                where: {
                    scope: ['channelWebRtc', 'channelSignal']
                },
                required: false
            }]
        });
        
        // Get channels where user is owner (for both WebRTC and Signal channels)
        const ownedChannels = await Channel.findAll({
            where: { owner: userId },
            attributes: ['uuid']
        });
        
        const ownedChannelIds = new Set(ownedChannels.map(c => c.uuid));
        
        // Group channel roles by channelId
        const channelRoles = {};
        if (user && user.ChannelRoles) {
            for (const role of user.ChannelRoles) {
                const channelId = role.UserRoleChannel.channelId;
                if (!channelRoles[channelId]) {
                    channelRoles[channelId] = [];
                }
                channelRoles[channelId].push({
                    uuid: role.uuid,
                    name: role.name,
                    description: role.description,
                    scope: role.scope,
                    permissions: role.permissions,
                    standard: role.standard,
                    createdAt: role.createdAt,
                    updatedAt: role.updatedAt
                });
            }
        }
        
        // Add ownership info for channels user owns but may not have explicit roles in
        for (const channelId of ownedChannelIds) {
            if (!channelRoles[channelId]) {
                channelRoles[channelId] = [];
            }
        }
        
        res.json({
            serverRoles: serverRoles.map(r => ({
                uuid: r.uuid,
                name: r.name,
                description: r.description,
                scope: r.scope,
                permissions: r.permissions,
                standard: r.standard,
                createdAt: r.createdAt,
                updatedAt: r.updatedAt
            })),
            channelRoles: channelRoles,
            ownedChannelIds: Array.from(ownedChannelIds) // New field: list of channel IDs user owns
        });
    } catch (error) {
        console.error('Error fetching user roles:', error);
        res.status(500).json({ error: 'Failed to fetch user roles' });
    }
});

// GET /api/roles - Get all roles by scope
roleRoutes.get('/roles', verifyAuthEither, requireAuth, async (req, res) => {
    try {
        const { scope } = req.query;
        
        if (!scope || !['server', 'channelWebRtc', 'channelSignal'].includes(scope)) {
            return res.status(400).json({ error: 'Valid scope parameter required' });
        }
        
        const roles = await getRolesByScope(scope);
        
        res.json({
            roles: roles.map(r => ({
                uuid: r.uuid,
                name: r.name,
                description: r.description,
                scope: r.scope,
                permissions: r.permissions,
                standard: r.standard,
                createdAt: r.createdAt,
                updatedAt: r.updatedAt
            }))
        });
    } catch (error) {
        console.error('Error fetching roles by scope:', error);
        res.status(500).json({ error: 'Failed to fetch roles' });
    }
});

// POST /api/roles - Create new role (admin only)
roleRoutes.post('/roles', verifyAuthEither, requireAuth, requirePermission('role.create'), async (req, res) => {
    try {
        const { name, description, scope, permissions } = req.body;
        
        if (!name || !scope || !permissions) {
            return res.status(400).json({ error: 'Name, scope, and permissions are required' });
        }
        
        if (!['server', 'channelWebRtc', 'channelSignal'].includes(scope)) {
            return res.status(400).json({ error: 'Invalid scope' });
        }
        
        if (!Array.isArray(permissions)) {
            return res.status(400).json({ error: 'Permissions must be an array' });
        }
        
        const role = await createRole({
            name,
            description: description || '',
            scope,
            permissions,
            standard: false
        });
        
        res.status(201).json({
            role: {
                uuid: role.uuid,
                name: role.name,
                description: role.description,
                scope: role.scope,
                permissions: role.permissions,
                standard: role.standard,
                createdAt: role.createdAt,
                updatedAt: role.updatedAt
            }
        });
    } catch (error) {
        console.error('Error creating role:', error);
        res.status(500).json({ error: error.message || 'Failed to create role' });
    }
});

// PUT /api/roles/:roleId - Update role (admin only, not standard roles)
roleRoutes.put('/roles/:roleId', verifyAuthEither, requireAuth, requirePermission('role.edit'), async (req, res) => {
    try {
        const { roleId } = req.params;
        const { name, description, permissions } = req.body;
        
        const updates = {};
        if (name !== undefined) updates.name = name;
        if (description !== undefined) updates.description = description;
        if (permissions !== undefined) {
            if (!Array.isArray(permissions)) {
                return res.status(400).json({ error: 'Permissions must be an array' });
            }
            updates.permissions = permissions;
        }
        
        const role = await updateRole(roleId, updates);
        
        res.json({
            role: {
                uuid: role.uuid,
                name: role.name,
                description: role.description,
                scope: role.scope,
                permissions: role.permissions,
                standard: role.standard,
                createdAt: role.createdAt,
                updatedAt: role.updatedAt
            }
        });
    } catch (error) {
        console.error('Error updating role:', error);
        res.status(500).json({ error: error.message || 'Failed to update role' });
    }
});

// DELETE /api/roles/:roleId - Delete role (admin only, not standard roles)
roleRoutes.delete('/roles/:roleId', verifyAuthEither, requireAuth, requirePermission('role.delete'), async (req, res) => {
    try {
        const { roleId } = req.params;
        
        await deleteRole(roleId);
        
        res.json({ message: 'Role deleted successfully' });
    } catch (error) {
        console.error('Error deleting role:', error);
        res.status(500).json({ error: error.message || 'Failed to delete role' });
    }
});

// POST /api/users/:userId/roles - Assign server role to user
roleRoutes.post('/users/:userId/roles', verifyAuthEither, requireAuth, requirePermission('role.assign'), async (req, res) => {
    try {
        const { userId } = req.params;
        const { roleId } = req.body;
        
        if (!roleId) {
            return res.status(400).json({ error: 'roleId is required' });
        }
        
        // Verify user exists
        const user = await User.findByPk(userId);
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        
        // Verify role exists and is a server role
        const role = await Role.findByPk(roleId);
        if (!role) {
            return res.status(404).json({ error: 'Role not found' });
        }
        if (role.scope !== 'server') {
            return res.status(400).json({ error: 'Can only assign server roles through this endpoint' });
        }
        
        await assignServerRole(userId, roleId);
        
        res.json({ message: 'Server role assigned successfully' });
    } catch (error) {
        console.error('Error assigning server role:', error);
        res.status(500).json({ error: error.message || 'Failed to assign server role' });
    }
});

// DELETE /api/users/:userId/roles/:roleId - Remove server role from user
roleRoutes.delete('/users/:userId/roles/:roleId', verifyAuthEither, requireAuth, requirePermission('role.assign'), async (req, res) => {
    try {
        const { userId, roleId } = req.params;
        
        // Verify role is a server role
        const role = await Role.findByPk(roleId);
        if (!role) {
            return res.status(404).json({ error: 'Role not found' });
        }
        if (role.scope !== 'server') {
            return res.status(400).json({ error: 'Can only remove server roles through this endpoint' });
        }
        
        await removeServerRole(userId, roleId);
        
        res.json({ message: 'Server role removed successfully' });
    } catch (error) {
        console.error('Error removing server role:', error);
        res.status(500).json({ error: error.message || 'Failed to remove server role' });
    }
});

// GET /api/users - Get all users (for user management)
roleRoutes.get('/users', verifyAuthEither, requireAuth, requirePermission('user.manage'), async (req, res) => {
    try {
        const users = await User.findAll({
            attributes: ['uuid', 'email', 'displayName', 'verified', 'active', 'createdAt'],
            order: [['displayName', 'ASC']]
        });
        
        res.json({ users });
    } catch (error) {
        console.error('Error fetching users:', error);
        res.status(500).json({ error: 'Failed to fetch users' });
    }
});

// PATCH /api/users/:userId/deactivate - Deactivate a user
roleRoutes.patch('/users/:userId/deactivate', verifyAuthEither, requireAuth, requirePermission('user.manage'), async (req, res) => {
    try {
        const { userId } = req.params;
        
        // Prevent deactivating yourself
        if (userId === req.session.uuid) {
            return res.status(400).json({ error: 'Cannot deactivate yourself' });
        }
        
        const user = await User.findByPk(userId);
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        
        await writeQueue.enqueue(
            () => user.update({ active: false }),
            'deactivateUser'
        );
        
        res.json({ message: 'User deactivated successfully' });
    } catch (error) {
        console.error('Error deactivating user:', error);
        res.status(500).json({ error: 'Failed to deactivate user' });
    }
});

// PATCH /api/users/:userId/activate - Activate a user
roleRoutes.patch('/users/:userId/activate', verifyAuthEither, requireAuth, requirePermission('user.manage'), async (req, res) => {
    try {
        const { userId } = req.params;
        
        const user = await User.findByPk(userId);
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        
        await writeQueue.enqueue(
            () => user.update({ active: true }),
            'activateUser'
        );
        
        res.json({ message: 'User activated successfully' });
    } catch (error) {
        console.error('Error activating user:', error);
        res.status(500).json({ error: 'Failed to activate user' });
    }
});

// DELETE /api/users/:userId - Delete a user
roleRoutes.delete('/users/:userId', verifyAuthEither, requireAuth, requirePermission('user.manage'), async (req, res) => {
    try {
        const { userId } = req.params;
        
        // Prevent deleting yourself
        if (userId === req.session.uuid) {
            return res.status(400).json({ error: 'Cannot delete yourself' });
        }
        
        const user = await User.findByPk(userId);
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        
        await writeQueue.enqueue(
            async () => {
                // Remove all user roles
                await UserRole.destroy({ where: { userId } });
                await UserRoleChannel.destroy({ where: { userId } });
                
                // Delete the user
                await user.destroy();
            },
            'deleteUser'
        );
        
        res.json({ message: 'User deleted successfully' });
    } catch (error) {
        console.error('Error deleting user:', error);
        res.status(500).json({ error: 'Failed to delete user' });
    }
});

// GET /api/users/:userId/roles - Get all roles for a specific user
roleRoutes.get('/users/:userId/roles', verifyAuthEither, requireAuth, requirePermission('user.manage'), async (req, res) => {
    try {
        const { userId } = req.params;
        
        // Verify user exists
        const user = await User.findByPk(userId);
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        
        // Get server roles
        const serverRoles = await getUserServerRoles(userId);
        
        res.json({
            serverRoles: serverRoles.map(r => ({
                uuid: r.uuid,
                name: r.name,
                description: r.description,
                scope: r.scope,
                permissions: r.permissions,
                standard: r.standard,
                createdAt: r.createdAt,
                updatedAt: r.updatedAt
            }))
        });
    } catch (error) {
        console.error('Error fetching user roles:', error);
        res.status(500).json({ error: 'Failed to fetch user roles' });
    }
});

// POST /api/users/:userId/channels/:channelId/roles - Assign channel role
roleRoutes.post('/users/:userId/channels/:channelId/roles', verifyAuthEither, requireAuth, async (req, res) => {
    try {
        const { userId, channelId } = req.params;
        const { roleId } = req.body;
        
        if (!roleId) {
            return res.status(400).json({ error: 'roleId is required' });
        }
        
        // Check if current user has permission to assign roles in this channel
        const canAssign = await hasChannelPermission(req.session.uuid, channelId, 'role.assign');
        if (!canAssign) {
            return res.status(403).json({ error: 'Forbidden: Cannot assign roles in this channel' });
        }
        
        await assignChannelRole(userId, roleId, channelId);
        
        res.json({ message: 'Role assigned successfully' });
    } catch (error) {
        console.error('Error assigning channel role:', error);
        res.status(500).json({ error: error.message || 'Failed to assign role' });
    }
});

// DELETE /api/users/:userId/channels/:channelId/roles/:roleId - Remove channel role
roleRoutes.delete('/users/:userId/channels/:channelId/roles/:roleId', verifyAuthEither, requireAuth, async (req, res) => {
    try {
        const { userId, channelId, roleId } = req.params;
        
        // Check if current user has permission to remove roles in this channel
        const canRemove = await hasChannelPermission(req.session.uuid, channelId, 'role.assign');
        if (!canRemove) {
            return res.status(403).json({ error: 'Forbidden: Cannot remove roles in this channel' });
        }
        
        await removeChannelRole(userId, roleId, channelId);
        
        res.json({ message: 'Role removed successfully' });
    } catch (error) {
        console.error('Error removing channel role:', error);
        res.status(500).json({ error: error.message || 'Failed to remove role' });
    }
});

// GET /api/channels/:channelId/members - Get channel members with roles
roleRoutes.get('/channels/:channelId/members', verifyAuthEither, requireAuth, async (req, res) => {
    try {
        const { channelId } = req.params;
        
        // Check if user has permission to view channel members
        const canView = await hasChannelPermission(req.session.uuid, channelId, 'member.view');
        if (!canView) {
            return res.status(403).json({ error: 'Forbidden: Cannot view channel members' });
        }
        
        // Get channel
        const channel = await Channel.findByPk(channelId, {
            include: [{
                model: Role,
                as: 'Roles',
                through: {
                    attributes: ['userId']
                },
                include: [{
                    model: User,
                    as: 'ChannelUsers',
                    attributes: ['uuid', 'displayName', 'email'],
                    through: {
                        attributes: []
                    }
                }]
            }]
        });
        
        if (!channel) {
            return res.status(404).json({ error: 'Channel not found' });
        }
        
        // Get all users with roles in this channel
        const usersMap = new Map();
        
        // Add channel owner first
        const owner = await User.findByPk(channel.owner, {
            attributes: ['uuid', 'displayName', 'email', 'profilePicture']
        });
        
        if (owner) {
            usersMap.set(owner.uuid, {
                userId: owner.uuid,
                displayName: owner.displayName || owner.email,
                email: owner.email,
                profilePicture: owner.profilePicture,
                isOwner: true,
                roles: []
            });
        }
        
        // Get all channel members (even those without roles)
        const channelMembers = await ChannelMembers.findAll({
            where: { channelId },
            include: [{
                model: User,
                attributes: ['uuid', 'displayName', 'email', 'profilePicture']
            }]
        });
        
        // Add all members to the map
        for (const member of channelMembers) {
            if (!member.User) continue;
            
            const userId = member.User.uuid;
            if (!usersMap.has(userId)) {
                usersMap.set(userId, {
                    userId: userId,
                    displayName: member.User.displayName || member.User.email,
                    email: member.User.email,
                    profilePicture: member.User.profilePicture,
                    isOwner: userId === channel.owner,
                    roles: []
                });
            }
        }
        
        // Now get all role assignments
        const userRoles = await UserRoleChannel.findAll({
            where: { channelId },
            include: [
                {
                    model: User,
                    as: 'User',
                    attributes: ['uuid', 'displayName', 'email', 'profilePicture']
                },
                {
                    model: Role,
                    as: 'Role',
                    attributes: ['uuid', 'name', 'description', 'scope', 'permissions', 'standard']
                }
            ]
        });
        
        // Add roles to existing members
        for (const ur of userRoles) {
            if (!ur.User || !ur.Role) continue;
            
            const userId = ur.User.uuid;
            if (usersMap.has(userId)) {
                usersMap.get(userId).roles.push({
                    id: ur.Role.id,
                    uuid: ur.Role.uuid,
                    name: ur.Role.name,
                    description: ur.Role.description,
                    scope: ur.Role.scope,
                    permissions: ur.Role.permissions,
                    standard: ur.Role.standard,
                    createdAt: ur.Role.createdAt,
                    updatedAt: ur.Role.updatedAt
                });
            }
        }
        
        res.json({
            members: Array.from(usersMap.values())
        });
    } catch (error) {
        console.error('Error fetching channel members:', error);
        res.status(500).json({ error: 'Failed to fetch channel members' });
    }
});

// POST /api/channels/:channelId/members - Add user to channel
roleRoutes.post('/channels/:channelId/members', verifyAuthEither, requireAuth, async (req, res) => {
    try {
        const { channelId } = req.params;
        const { userId, roleId } = req.body;
        
        console.log('[ADD_MEMBER] Request received - channelId:', channelId, 'userId:', userId, 'roleId:', roleId);
        console.log('[ADD_MEMBER] req.session.uuid:', req.session.uuid);
        
        if (!userId) {
            return res.status(400).json({ error: 'userId is required' });
        }
        
        // Check if user has permission to add members
        const canAdd = await hasChannelPermission(req.session.uuid, channelId, 'user.add');
        console.log('[ADD_MEMBER] canAdd:', canAdd);
        if (!canAdd) {
            return res.status(403).json({ error: 'Forbidden: Cannot add members to this channel' });
        }
        
        // Verify channel exists
        const channel = await Channel.findByPk(channelId);
        if (!channel) {
            return res.status(404).json({ error: 'Channel not found' });
        }
        
        // Verify user exists
        const user = await User.findByPk(userId);
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        
        // Check if user is already a member
        const existingMember = await ChannelMembers.findOne({
            where: { userId, channelId }
        });
        
        if (existingMember) {
            return res.status(400).json({ error: 'User is already a member of this channel' });
        }
        
        // Add user to channel
        await ChannelMembers.create({
            userId,
            channelId,
            permission: 'member'
        });
        
        // If roleId is provided, assign that role to the user
        if (roleId) {
            const role = await Role.findByPk(roleId);
            if (!role) {
                return res.status(400).json({ error: 'Invalid role ID' });
            }
            
            // Verify role scope matches channel type
            const expectedScope = channel.type === 'webrtc' ? 'channelWebRtc' : 'channelSignal';
            if (role.scope !== expectedScope) {
                return res.status(400).json({ 
                    error: `Role scope '${role.scope}' does not match channel type '${channel.type}'` 
                });
            }
            
            await UserRoleChannel.create({
                userId,
                roleId,
                channelId
            });
        } else if (channel.defaultRoleId) {
            // Use default role if no specific role provided
            await UserRoleChannel.create({
                userId,
                roleId: channel.defaultRoleId,
                channelId
            });
        }
        
        res.status(201).json({ 
            success: true,
            message: 'User added to channel successfully' 
        });
    } catch (error) {
        console.error('[ADD_MEMBER] Error adding user to channel:', error);
        console.error('[ADD_MEMBER] Error stack:', error.stack);
        res.status(500).json({ error: 'Failed to add user to channel: ' + error.message });
    }
});

// GET /api/channels/:channelId/available-users - Get users not in channel
roleRoutes.get('/channels/:channelId/available-users', verifyAuthEither, requireAuth, async (req, res) => {
    try {
        const { channelId } = req.params;
        const { search } = req.query;
        
        console.log('[AVAILABLE_USERS] Request - channelId:', channelId, 'search:', search);
        console.log('[AVAILABLE_USERS] req.session.uuid:', req.session.uuid);
        
        // Check if user has permission to add members
        const canAdd = await hasChannelPermission(req.session.uuid, channelId, 'user.add');
        console.log('[AVAILABLE_USERS] canAdd permission:', canAdd);
        if (!canAdd) {
            return res.status(403).json({ error: 'Forbidden: Cannot add members to this channel' });
        }
        
        // Get all users already in the channel
        const existingMembers = await ChannelMembers.findAll({
            where: { channelId },
            attributes: ['userId']
        });
        
        const existingUserIds = existingMembers.map(m => m.userId);
        console.log('[AVAILABLE_USERS] Existing member IDs:', existingUserIds);
        
        // Build query for available users
        const whereClause = {
            uuid: { [require('sequelize').Op.notIn]: existingUserIds }
        };
        
        // Add search filter if provided
        if (search) {
            const { Op } = require('sequelize');
            whereClause[Op.or] = [
                { displayName: { [Op.like]: `%${search}%` } },
                { email: { [Op.like]: `%${search}%` } }
            ];
        }
        
        console.log('[AVAILABLE_USERS] Where clause:', JSON.stringify(whereClause));
        
        const availableUsers = await User.findAll({
            where: whereClause,
            attributes: ['uuid', 'displayName', 'email'],
            limit: 50,
            order: [['displayName', 'ASC']]
        });
        
        console.log('[AVAILABLE_USERS] Found users:', availableUsers.length);
        availableUsers.forEach(u => console.log('[AVAILABLE_USERS] -', u.displayName || u.email, '(', u.uuid, ')'));
        
        res.json({
            users: availableUsers.map(u => ({
                uuid: u.uuid,
                displayName: u.displayName || u.email,
                email: u.email
            }))
        });
    } catch (error) {
        console.error('[AVAILABLE_USERS] Error fetching available users:', error);
        console.error('[AVAILABLE_USERS] Error stack:', error.stack);
        res.status(500).json({ error: 'Failed to fetch available users' });
    }
});

// POST /api/channels/:channelId/leave - Leave a channel
roleRoutes.post('/channels/:channelId/leave', verifyAuthEither, requireAuth, async (req, res) => {
    try {
        const { channelId } = req.params;
        const userId = req.session.uuid;
        
        // Verify channel exists
        const channel = await Channel.findByPk(channelId);
        if (!channel) {
            return res.status(404).json({ error: 'Channel not found' });
        }
        
        // Check if user is the channel owner
        if (channel.owner === userId) {
            return res.status(403).json({ error: 'Channel owner cannot leave the channel. Transfer ownership or delete the channel instead.' });
        }
        
        // Check if user is a member
        const membership = await ChannelMembers.findOne({
            where: { userId, channelId }
        });
        
        if (!membership) {
            return res.status(400).json({ error: 'You are not a member of this channel' });
        }
        
        // Remove user from channel
        await membership.destroy();
        
        // Remove all channel role assignments
        await UserRoleChannel.destroy({
            where: { userId, channelId }
        });
        
        res.json({ 
            success: true,
            message: 'Successfully left the channel' 
        });
    } catch (error) {
        console.error('Error leaving channel:', error);
        res.status(500).json({ error: 'Failed to leave channel' });
    }
});

// DELETE /api/channels/:channelId/members/:userId - Kick user from channel
roleRoutes.delete('/channels/:channelId/members/:userId', verifyAuthEither, requireAuth, async (req, res) => {
    try {
        const { channelId, userId } = req.params;
        const requesterId = req.session.uuid;
        
        // Verify channel exists
        const channel = await Channel.findByPk(channelId);
        if (!channel) {
            return res.status(404).json({ error: 'Channel not found' });
        }
        
        // Check if requester is the channel owner or has user.kick permission
        const isOwner = channel.owner === requesterId;
        const hasKickPermission = await hasChannelPermission(requesterId, channelId, 'user.kick');
        
        if (!isOwner && !hasKickPermission) {
            return res.status(403).json({ error: 'Forbidden: You do not have permission to remove members from this channel' });
        }
        
        // Prevent kicking the channel owner
        if (userId === channel.owner) {
            return res.status(400).json({ error: 'Cannot kick the channel owner' });
        }
        
        // Check if user is a member
        const membership = await ChannelMembers.findOne({
            where: { userId, channelId }
        });
        
        if (!membership) {
            return res.status(400).json({ error: 'User is not a member of this channel' });
        }
        
        // Remove user from channel
        await membership.destroy();
        
        // Remove all channel role assignments
        await UserRoleChannel.destroy({
            where: { userId, channelId }
        });
        
        res.json({ 
            success: true,
            message: 'User removed from channel successfully' 
        });
    } catch (error) {
        console.error('Error removing user from channel:', error);
        res.status(500).json({ error: 'Failed to remove user from channel' });
    }
});

// DELETE /api/channels/:channelId - Delete a channel
roleRoutes.delete('/channels/:channelId', verifyAuthEither, requireAuth, async (req, res) => {
    try {
        const { channelId } = req.params;
        const userId = req.session.uuid;
        
        // Verify channel exists
        const channel = await Channel.findByPk(channelId);
        if (!channel) {
            return res.status(404).json({ error: 'Channel not found' });
        }
        
        // Only the channel owner can delete the channel
        if (channel.owner !== userId) {
            return res.status(403).json({ error: 'Forbidden: Only the channel owner can delete the channel' });
        }
        
        // Delete all channel memberships
        await ChannelMembers.destroy({
            where: { channelId }
        });
        
        // Delete all channel role assignments
        await UserRoleChannel.destroy({
            where: { channelId }
        });
        
        // Delete the channel itself
        await channel.destroy();
        
        res.json({ 
            success: true,
            message: 'Channel deleted successfully' 
        });
    } catch (error) {
        console.error('Error deleting channel:', error);
        res.status(500).json({ error: 'Failed to delete channel' });
    }
});

// POST /api/user/check-permission - Check if user has specific permission
roleRoutes.post('/user/check-permission', requireAuth, async (req, res) => {
    try {
        const { permission, channelId } = req.body;
        
        if (!permission) {
            return res.status(400).json({ error: 'permission is required' });
        }
        
        let hasPermission;
        if (channelId) {
            hasPermission = await hasChannelPermission(req.session.uuid, channelId, permission);
        } else {
            hasPermission = await hasServerPermission(req.session.uuid, permission);
        }
        
        res.json({ hasPermission });
    } catch (error) {
        console.error('Error checking permission:', error);
        res.status(500).json({ error: 'Failed to check permission' });
    }
});

module.exports = roleRoutes;
