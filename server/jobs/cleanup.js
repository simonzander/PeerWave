const cron = require('node-cron');
const { Op } = require('sequelize');
const config = require('../config/config');
const { User, Client, Item } = require('../db/model');
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
 * Delete old items (messages, receipts, etc.) older than X days
 */
async function deleteOldItems() {
    try {
        const daysAgo = new Date();
        daysAgo.setDate(daysAgo.getDate() - config.cleanup.deleteOldItemsDays);
        
        console.log(`[CLEANUP] Deleting items older than ${daysAgo.toISOString()}...`);
        
        // Delete items older than X days using writeQueue
        const deletedCount = await writeQueue.enqueue(
            () => Item.destroy({
                where: {
                    createdAt: {
                        [Op.lt]: daysAgo
                    }
                }
            }),
            'deleteOldItems'
        );
        
        console.log(`[CLEANUP] ✓ Deleted ${deletedCount} old items`);
        return deletedCount;
    } catch (error) {
        console.error('[CLEANUP] ❌ Error deleting old items:', error);
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
    deleteOldItems
};
