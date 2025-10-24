/**
 * Migration: Remove 'channel' column from Items table
 * 
 * This migration removes the 'channel' column from the Items table.
 * The Item table is ONLY for 1:1 messages and does not need a channel field.
 * Group messages are stored in the separate GroupItem table.
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

        // Check if column exists
        const [results] = await sequelize.query(`PRAGMA table_info(Items);`);
        const hasChannel = results.some(col => col.name === 'channel');

        if (!hasChannel) {
            console.log('✓ Column "channel" does not exist in Items table (already removed or never added)');
        } else {
            console.log('Removing column "channel" from Items table...');
            
            // SQLite does not support DROP COLUMN directly (in older versions)
            // We need to recreate the table without the column
            
            // 1. Create new table without channel column
            await sequelize.query(`
                CREATE TABLE Items_new (
                    uuid TEXT PRIMARY KEY NOT NULL UNIQUE,
                    deviceReceiver INTEGER NOT NULL,
                    receiver TEXT NOT NULL,
                    sender TEXT NOT NULL,
                    deviceSender INTEGER NOT NULL,
                    readed INTEGER NOT NULL DEFAULT 0,
                    itemId TEXT NOT NULL,
                    type TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    cipherType INTEGER NOT NULL,
                    deliveredAt TEXT,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                );
            `);
            
            console.log('✓ Created new Items table without channel column');
            
            // 2. Copy data from old table to new table (excluding channel)
            await sequelize.query(`
                INSERT INTO Items_new 
                SELECT uuid, deviceReceiver, receiver, sender, deviceSender, readed, itemId, type, payload, cipherType, deliveredAt, createdAt, updatedAt
                FROM Items;
            `);
            
            console.log('✓ Copied data to new table');
            
            // 3. Drop old table
            await sequelize.query(`DROP TABLE Items;`);
            
            console.log('✓ Dropped old Items table');
            
            // 4. Rename new table to original name
            await sequelize.query(`ALTER TABLE Items_new RENAME TO Items;`);
            
            console.log('✓ Renamed new table to Items');
        }

        // Verify the column is gone
        const [verifyResults] = await sequelize.query(`PRAGMA table_info(Items);`);
        const channelCol = verifyResults.find(col => col.name === 'channel');
        
        if (!channelCol) {
            console.log('✓ Migration successful - channel column removed');
            console.log('  Current columns:', verifyResults.map(col => col.name).join(', '));
        } else {
            console.error('✗ Migration failed - column still exists after removal');
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
