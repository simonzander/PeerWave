const cron = require('node-cron');
const { Op } = require('sequelize');
const config = require('../config/config');
const { User, Client, Item, GroupItem } = require('../db/model');
const writeQueue = require('../db/writeQueue');

/**
 * Mark users as inactive if no client has been updated in the last X days
 */
async function markInactiveUsers() {
    try {
        const daysAgo = new Date();
        daysAgo.setDate(daysAgo.getDate() - config.cleanup.inactiveUserDays);
        
        console.log(`[CLEANUP] Checking for inactive users (no client update since ${daysAgo.toISOString()})...`);
        
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
                console.log(`[CLEANUP] User ${user.uuid} (${user.displayName}) is inactive - no client updates since ${daysAgo.toISOString()}`);
                
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
        
        console.log(`[CLEANUP] ✓ Marked ${markedCount} users as inactive`);
        return markedCount;
    } catch (error) {
        console.error('[CLEANUP] ❌ Error marking inactive users:', error);
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
        
        console.log(`[CLEANUP] Deleting system messages older than ${systemDaysAgo.toISOString()}...`);
        
        const systemDeleted = await writeQueue.enqueue(
            () => Item.destroy({
                where: {
                    type: { [Op.in]: systemMessageTypes },
                    createdAt: { [Op.lt]: systemDaysAgo }
                }
            }),
            'deleteOldSystemMessages'
        );
        console.log(`[CLEANUP] ✓ Deleted ${systemDeleted} old system messages (>${config.cleanup.deleteSystemMessagesDays} days)`);
        totalDeleted += systemDeleted;
        
        // 2. Delete regular messages (message, file) after 7 days
        const regularDaysAgo = new Date(now);
        regularDaysAgo.setDate(regularDaysAgo.getDate() - config.cleanup.deleteRegularMessagesDays);
        
        console.log(`[CLEANUP] Deleting regular messages older than ${regularDaysAgo.toISOString()}...`);
        
        const regularDeleted = await writeQueue.enqueue(
            () => Item.destroy({
                where: {
                    type: { [Op.in]: ['message', 'file'] },
                    createdAt: { [Op.lt]: regularDaysAgo }
                }
            }),
            'deleteOldRegularMessages'
        );
        console.log(`[CLEANUP] ✓ Deleted ${regularDeleted} old regular messages (>${config.cleanup.deleteRegularMessagesDays} days)`);
        totalDeleted += regularDeleted;
        
        // 3. Delete old group messages after 30 days
        const groupDaysAgo = new Date(now);
        groupDaysAgo.setDate(groupDaysAgo.getDate() - config.cleanup.deleteGroupMessagesDays);
        
        console.log(`[CLEANUP] Deleting group messages older than ${groupDaysAgo.toISOString()}...`);
        
        const groupDeleted = await writeQueue.enqueue(
            () => GroupItem.destroy({
                where: {
                    createdAt: { [Op.lt]: groupDaysAgo }
                }
            }),
            'deleteOldGroupMessages'
        );
        console.log(`[CLEANUP] ✓ Deleted ${groupDeleted} old group messages (>${config.cleanup.deleteGroupMessagesDays} days)`);
        totalDeleted += groupDeleted;
        
        console.log(`[CLEANUP] ✓ Total items deleted: ${totalDeleted}`);
        return { systemDeleted, regularDeleted, groupDeleted, totalDeleted };
    } catch (error) {
        console.error('[CLEANUP] ❌ Error deleting old items:', error);
        throw error;
    }
}

/**
 * Clean up expired P2P files from file registry
 */
async function cleanupFileRegistry() {
    try {
        console.log('[CLEANUP] Cleaning up file registry...');
        
        const fileRegistry = require('../store/fileRegistry');
        const stats = fileRegistry.cleanup();
        
        console.log(`[CLEANUP] ✓ File registry cleanup complete:`);
        console.log(`[CLEANUP]   - Files removed: ${stats.filesRemoved}`);
        console.log(`[CLEANUP]   - Users removed: ${stats.usersRemoved}`);
        console.log(`[CLEANUP]   - Total files: ${stats.totalFiles}`);
        console.log(`[CLEANUP]   - Total users: ${stats.totalUsers}`);
        
        return stats;
    } catch (error) {
        console.error('[CLEANUP] ❌ Error cleaning file registry:', error);
        throw error;
    }
}

/**
 * Run all cleanup tasks
 */
async function runCleanup() {
    console.log('[CLEANUP] ========================================');
    console.log('[CLEANUP] Starting cleanup job...');
    console.log(`[CLEANUP] Config: Inactive users after ${config.cleanup.inactiveUserDays} days`);
    console.log(`[CLEANUP] Config: Delete items after ${config.cleanup.deleteOldItemsDays} days`);
    console.log('[CLEANUP] ========================================');
    
    try {
        // Mark inactive users
        await markInactiveUsers();
        
        // Delete old items
        await deleteOldItems();
        
        // Clean up file registry
        await cleanupFileRegistry();
        
        console.log('[CLEANUP] ✓ Cleanup job completed successfully');
    } catch (error) {
        console.error('[CLEANUP] ❌ Cleanup job failed:', error);
    }
}

/**
 * Initialize cleanup cronjob
 */
function initCleanupJob() {
    console.log(`[CLEANUP] Initializing cleanup cronjob with schedule: ${config.cleanup.cronSchedule}`);
    
    // Schedule cronjob (default: every day at 2:00 AM)
    cron.schedule(config.cleanup.cronSchedule, () => {
        runCleanup();
    });
    
    console.log('[CLEANUP] ✓ Cleanup cronjob initialized');
}

module.exports = {
    initCleanupJob,
    runCleanup,
    markInactiveUsers,
    deleteOldItems,
    cleanupFileRegistry
};
