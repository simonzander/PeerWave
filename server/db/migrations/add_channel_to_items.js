/**
 * Migration: Add 'channel' column to Items table
 * 
 * This migration adds the 'channel' column to the Items table.
 * For 1:1 messages, channel is ALWAYS NULL.
 * Group messages use the separate GroupItem table.
 * 
 * This field exists for database schema consistency and filtering.
 */

const { Sequelize } = require('sequelize');

async function migrate() {
    const sequelize = new Sequelize({
        dialect: 'sqlite',
        storage: './db/peerwave.sqlite',
        logging: console.log
    });

    try {
        await sequelize.authenticate();
        console.log('✓ Connected to database');

        // Check if column already exists
        const [results] = await sequelize.query(`PRAGMA table_info(Items);`);
        const hasChannel = results.some(col => col.name === 'channel');

        if (hasChannel) {
            console.log('✓ Column "channel" already exists in Items table');
        } else {
            console.log('Adding column "channel" to Items table...');
            
            // Add column with default NULL
            await sequelize.query(`
                ALTER TABLE Items 
                ADD COLUMN channel TEXT DEFAULT NULL;
            `);
            
            console.log('✓ Column "channel" added to Items table');
        }

        // Verify the column exists
        const [verifyResults] = await sequelize.query(`PRAGMA table_info(Items);`);
        const channelCol = verifyResults.find(col => col.name === 'channel');
        
        if (channelCol) {
            console.log('✓ Migration successful');
            console.log(`  Column details:`, channelCol);
        } else {
            console.error('✗ Migration failed - column not found after addition');
        }

        await sequelize.close();
    } catch (error) {
        console.error('✗ Migration error:', error);
        process.exit(1);
    }
}

// Run migration if called directly
if (require.main === module) {
    migrate().then(() => {
        console.log('Migration completed');
        process.exit(0);
    }).catch(error => {
        console.error('Migration failed:', error);
        process.exit(1);
    });
}

module.exports = migrate;
