const config = require('../config/config');
const express = require("express");
const { Role, User, Channel, UserRole, UserRoleChannel } = require('../db/model');
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

const roleRoutes = express.Router();

// Middleware to check if user is authenticated
const requireAuth = (req, res, next) => {
    if (!req.session.authenticated || !req.session.uuid) {
        return res.status(401).json({ error: 'Unauthorized' });
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
roleRoutes.get('/user/roles', requireAuth, async (req, res) => {
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
            channelRoles: channelRoles
        });
    } catch (error) {
        console.error('Error fetching user roles:', error);
        res.status(500).json({ error: 'Failed to fetch user roles' });
    }
});

// GET /api/roles - Get all roles by scope
roleRoutes.get('/roles', requireAuth, async (req, res) => {
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
roleRoutes.post('/roles', requireAuth, requirePermission('role.create'), async (req, res) => {
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
roleRoutes.put('/roles/:roleId', requireAuth, requirePermission('role.edit'), async (req, res) => {
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
roleRoutes.delete('/roles/:roleId', requireAuth, requirePermission('role.delete'), async (req, res) => {
    try {
        const { roleId } = req.params;
        
        await deleteRole(roleId);
        
        res.json({ message: 'Role deleted successfully' });
    } catch (error) {
        console.error('Error deleting role:', error);
        res.status(500).json({ error: error.message || 'Failed to delete role' });
    }
});

// POST /api/users/:userId/channels/:channelId/roles - Assign channel role
roleRoutes.post('/users/:userId/channels/:channelId/roles', requireAuth, async (req, res) => {
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
roleRoutes.delete('/users/:userId/channels/:channelId/roles/:roleId', requireAuth, async (req, res) => {
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
roleRoutes.get('/channels/:channelId/members', requireAuth, async (req, res) => {
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
        
        const userRoles = await UserRoleChannel.findAll({
            where: { channelId },
            include: [
                {
                    model: User,
                    attributes: ['uuid', 'displayName', 'email']
                },
                {
                    model: Role,
                    attributes: ['uuid', 'name', 'description', 'scope', 'permissions', 'standard']
                }
            ]
        });
        
        for (const ur of userRoles) {
            if (!ur.User) continue;
            
            const userId = ur.User.uuid;
            if (!usersMap.has(userId)) {
                usersMap.set(userId, {
                    userId: userId,
                    displayName: ur.User.displayName || ur.User.email,
                    email: ur.User.email,
                    roles: []
                });
            }
            
            if (ur.Role) {
                usersMap.get(userId).roles.push({
                    id: ur.Role.id,
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
