const config = require('../config/config');
const { Role, User } = require('./model');
const { assignServerRole } = require('./roleHelpers');

/**
 * Automatically assign roles to a user based on configuration
 * - Admin role if email is in config.admin array
 * - Default "User" role for all verified users
 * 
 * Called on:
 * 1. User verification (OTP)
 * 2. WebAuthn authentication (if verified + in config.admin)
 * 3. Magic link verification (if verified + in config.admin)
 * 4. Client login (if verified + in config.admin)
 * 
 * Note: Uses findOrCreate, so roles won't be duplicated if already assigned
 * 
 * @param {string} userEmail - User's email address
 * @param {string} userId - User's UUID
 */
async function autoAssignRoles(userEmail, userId) {
    try {
        const isAdmin = config.admin && config.admin.includes(userEmail);
        
        if (isAdmin) {
            // Assign Administrator role
            const adminRole = await Role.findOne({
                where: { name: 'Administrator', scope: 'server' }
            });
            
            if (adminRole) {
                const [userRole, created] = await assignServerRole(userId, adminRole.uuid);
                if (created) {
                    console.log(`✓ Administrator role assigned to user: ${userEmail}`);
                } else {
                    console.log(`ℹ Administrator role already assigned to: ${userEmail}`);
                }
            } else {
                console.error('Administrator role not found in database');
            }
        } else {
            // Assign default User role
            const userRole = await Role.findOne({
                where: { name: 'User', scope: 'server' }
            });
            
            if (userRole) {
                const [role, created] = await assignServerRole(userId, userRole.uuid);
                if (created) {
                    console.log(`✓ User role assigned to user: ${userEmail}`);
                } else {
                    console.log(`ℹ User role already assigned to: ${userEmail}`);
                }
            } else {
                console.error('User role not found in database');
            }
        }
    } catch (error) {
        console.error(`Error auto-assigning roles for ${userEmail}:`, error);
        // Don't throw - role assignment failure shouldn't block verification
    }
}

module.exports = { autoAssignRoles };
