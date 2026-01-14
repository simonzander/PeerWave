const cron = require('node-cron');
const { Op } = require('sequelize');
const config = require('../config/config');
const { User, Client, Item, GroupItem, RefreshToken } = require('../db/model');
const writeQueue = require('../db/writeQueue');
const logger = require('../utils/logger');

/**
 * Mark users as inactive if no client has been updated in the last X days
 */
async function markInactiveUsers() {
    try {
        const daysAgo = new Date();
        daysAgo.setDate(daysAgo.getDate() - config.cleanup.inactiveUserDays);
        
        logger.info('[CLEANUP] Checking for inactive users', { since: daysAgo.toISOString() });
        
        // Find users where the most recent client update is older than X days
        const inactiveUsers = await User.findAll({
            include: [{
                model: Client,
                as: 'Clients',  // Sequelize default plural alias with capital C
                attributes: ['updatedAt'],
                required: true
            }],
            where: {
                // Only check active users
                '$Clients.updatedAt$': {
                    [Op.lt]: daysAgo
                }
            }
        });
        
        let markedCount = 0;
        for (const user of inactiveUsers) {
            // Check if ALL clients are inactive
            const hasActiveClient = user.Clients.some(client => {
                return new Date(client.updatedAt) > daysAgo;
            });
            
            if (!hasActiveClient) {
                // Mark user as inactive
                logger.info('[CLEANUP] User is inactive', { uuid: user.uuid, displayName: user.displayName, since: daysAgo.toISOString() });
                
                // Set active to false
                await writeQueue.enqueue(
                    () => User.update(
                        { active: false },
                        { where: { uuid: user.uuid } }
                    ),
                    'markUserInactive'
                );
                
                markedCount++;
            }
        }
        
        logger.info('[CLEANUP] Marked users as inactive', { count: markedCount });
        return markedCount;
    } catch (error) {
        logger.error('[CLEANUP] Error marking inactive users', error);
        throw error;
    }
}

/**
 * Delete old items (messages, receipts, etc.) with separate retention periods
 */
async function deleteOldItems() {
    try {
        const now = new Date();
        let totalDeleted = 0;
        
        // 1. Delete system messages (read_receipt, etc.) after 1 day
        const systemMessageTypes = [
            'read_receipt', 
            'senderKeyRequest', 
            'senderKeyDistribution', 
            'fileKeyRequest', 
            'fileKeyResponse', 
            'delivery_receipt'
        ];
        const systemDaysAgo = new Date(now);
        systemDaysAgo.setDate(systemDaysAgo.getDate() - config.cleanup.deleteSystemMessagesDays);
        
        logger.info('[CLEANUP] Deleting system messages', { olderThan: systemDaysAgo.toISOString() });
        
        const systemDeleted = await writeQueue.enqueue(
            () => Item.destroy({
                where: {
                    type: { [Op.in]: systemMessageTypes },
                    createdAt: { [Op.lt]: systemDaysAgo }
                }
            }),
            'deleteOldSystemMessages'
        );
        logger.info('[CLEANUP] Deleted old system messages', { count: systemDeleted, days: config.cleanup.deleteSystemMessagesDays });
        totalDeleted += systemDeleted;
        
        // 2. Delete regular messages (message, file) after 7 days
        const regularDaysAgo = new Date(now);
        regularDaysAgo.setDate(regularDaysAgo.getDate() - config.cleanup.deleteRegularMessagesDays);
        
        logger.info('[CLEANUP] Deleting regular messages', { olderThan: regularDaysAgo.toISOString() });
        
        const regularDeleted = await writeQueue.enqueue(
            () => Item.destroy({
                where: {
                    type: { [Op.in]: ['message', 'file'] },
                    createdAt: { [Op.lt]: regularDaysAgo }
                }
            }),
            'deleteOldRegularMessages'
        );
        logger.info('[CLEANUP] Deleted old regular messages', { count: regularDeleted, days: config.cleanup.deleteRegularMessagesDays });
        totalDeleted += regularDeleted;
        
        // 3. Delete old group messages after 30 days
        const groupDaysAgo = new Date(now);
        groupDaysAgo.setDate(groupDaysAgo.getDate() - config.cleanup.deleteGroupMessagesDays);
        
        logger.info('[CLEANUP] Deleting group messages', { olderThan: groupDaysAgo.toISOString() });
        
        const groupDeleted = await writeQueue.enqueue(
            () => GroupItem.destroy({
                where: {
                    createdAt: { [Op.lt]: groupDaysAgo }
                }
            }),
            'deleteOldGroupMessages'
        );
        logger.info('[CLEANUP] Deleted old group messages', { count: groupDeleted, days: config.cleanup.deleteGroupMessagesDays });
        totalDeleted += groupDeleted;
        
        logger.info('[CLEANUP] Total items deleted', { count: totalDeleted });
        return { systemDeleted, regularDeleted, groupDeleted, totalDeleted };
    } catch (error) {
        logger.error('[CLEANUP] Error deleting old items', error);
        throw error;
    }
}

/**
 * Clean up expired and used refresh tokens
 */
async function cleanupRefreshTokens() {
    try {
        logger.info('[CLEANUP] Cleaning up refresh tokens');
        
        const now = new Date();
        
        // Delete tokens that are:
        // 1. Expired
        // 2. Used (one-time use)
        const result = await writeQueue.enqueue(
            () => RefreshToken.destroy({
                where: {
                    [Op.or]: [
                        { expires_at: { [Op.lt]: now } },
                        { used_at: { [Op.not]: null } }
                    ]
                }
            }),
            'cleanupRefreshTokens'
        );
        
        logger.info('[CLEANUP] Refresh tokens cleaned up', { deletedCount: result });
        
        return result;
    } catch (error) {
        logger.error('[CLEANUP] Error cleaning refresh tokens', error);
        throw error;
    }
}

/**
 * Clean up expired P2P files from file registry
 */
async function cleanupFileRegistry() {
    try {
        logger.info('[CLEANUP] Cleaning up file registry');
        
        const fileRegistry = require('../store/fileRegistry');
        const stats = fileRegistry.cleanup();
        
        logger.info('[CLEANUP] File registry cleanup complete', stats);
        
        return stats;
    } catch (error) {
        logger.error('[CLEANUP] Error cleaning file registry', error);
        throw error;
    }
}

/**
 * Run all cleanup tasks
 */
async function runCleanup() {
    logger.info('[CLEANUP] ========================================');
    logger.info('[CLEANUP] Starting cleanup job');
    logger.info('[CLEANUP] Config', { inactiveUserDays: config.cleanup.inactiveUserDays, deleteOldItemsDays: config.cleanup.deleteOldItemsDays });
    logger.info('[CLEANUP] ========================================');
    
    try {
        // Mark inactive users
        await markInactiveUsers();
        
        // Delete old items
        await deleteOldItems();
        
        // Clean up refresh tokens
        await cleanupRefreshTokens();
        
        // Clean up file registry
        await cleanupFileRegistry();
        
        logger.info('[CLEANUP] Cleanup job completed successfully');
    } catch (error) {
        logger.error('[CLEANUP] Cleanup job failed', error);
    }
}

/**
 * Initialize cleanup cronjob
 */
function initCleanupJob() {
    logger.info('[CLEANUP] Initializing cleanup cronjob', { schedule: config.cleanup.cronSchedule });
    
    // Schedule cronjob (default: every day at 2:00 AM)
    cron.schedule(config.cleanup.cronSchedule, () => {
        runCleanup();
    });
    
    logger.info('[CLEANUP] Cleanup cronjob initialized');
}

module.exports = {
    initCleanupJob,
    runCleanup,
    markInactiveUsers,
    deleteOldItems,
    cleanupRefreshTokens,
    cleanupFileRegistry
};
