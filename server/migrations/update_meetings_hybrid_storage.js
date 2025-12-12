const { sequelize } = require('../db/model');

/**
 * Migration: Update meetings table for hybrid storage (DB + Memory)
 * 
 * This migration:
 * 1. Adds invited_participants JSON field for scheduled meetings
 * 2. Removes runtime-only fields (status, max_participants, source_*)
 * 3. Drops meeting_participants table (moved to memory)
 * 
 * Philosophy:
 * - Database: Persistent scheduled meetings
 * - Memory: All runtime state + instant calls
 */

async function up() {
  const queryInterface = sequelize.getQueryInterface();

  console.log('[Migration] Starting hybrid storage migration...');

  try {
    // 1. Add invited_participants column (JSON array of UUIDs and emails)
    const tableInfo = await sequelize.query(
      "PRAGMA table_info(meetings)",
      { type: sequelize.QueryTypes.SELECT }
    );
    const hasInvitedParticipants = tableInfo.some(col => col.name === 'invited_participants');
    
    if (!hasInvitedParticipants) {
      await queryInterface.addColumn('meetings', 'invited_participants', {
        type: sequelize.Sequelize.TEXT, // SQLite stores JSON as TEXT
        allowNull: true,
        defaultValue: '[]',
        comment: 'JSON array of invited user UUIDs and email addresses'
      });
      console.log('[Migration] ✓ Added invited_participants column');
    } else {
      console.log('[Migration] - invited_participants column already exists');
    }

    // 2. Remove runtime-only columns
    const columnsToRemove = ['status', 'max_participants', 'source_channel_id', 'source_user_id'];
    
    for (const column of columnsToRemove) {
      try {
        await queryInterface.removeColumn('meetings', column);
        console.log(`[Migration] ✓ Removed ${column} column`);
      } catch (error) {
        console.log(`[Migration] - ${column} column doesn't exist or already removed`);
      }
    }

    // 3. Drop meeting_participants table
    try {
      await queryInterface.dropTable('meeting_participants');
      console.log('[Migration] ✓ Dropped meeting_participants table');
    } catch (error) {
      console.log('[Migration] - meeting_participants table doesn\'t exist or already dropped');
    }

    console.log('[Migration] ✅ Hybrid storage migration completed successfully');

  } catch (error) {
    console.error('[Migration] ❌ Error during migration:', error);
    throw error;
  }
}

async function down() {
  const queryInterface = sequelize.getQueryInterface();

  console.log('[Migration] Rolling back hybrid storage migration...');

  try {
    // Remove invited_participants
    await queryInterface.removeColumn('meetings', 'invited_participants');

    // Restore runtime columns
    await queryInterface.addColumn('meetings', 'status', {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      defaultValue: 'scheduled'
    });

    await queryInterface.addColumn('meetings', 'max_participants', {
      type: sequelize.Sequelize.INTEGER,
      allowNull: true
    });

    await queryInterface.addColumn('meetings', 'source_channel_id', {
      type: sequelize.Sequelize.STRING,
      allowNull: true
    });

    await queryInterface.addColumn('meetings', 'source_user_id', {
      type: sequelize.Sequelize.STRING,
      allowNull: true
    });

    // Recreate meeting_participants table
    await queryInterface.createTable('meeting_participants', {
      participant_id: {
        type: sequelize.Sequelize.INTEGER,
        primaryKey: true,
        autoIncrement: true
      },
      meeting_id: {
        type: sequelize.Sequelize.STRING,
        allowNull: false
      },
      user_id: {
        type: sequelize.Sequelize.STRING,
        allowNull: false
      },
      role: {
        type: sequelize.Sequelize.STRING,
        allowNull: false,
        defaultValue: 'meeting_member'
      },
      status: {
        type: sequelize.Sequelize.STRING,
        allowNull: false,
        defaultValue: 'invited'
      },
      created_at: {
        type: sequelize.Sequelize.DATE,
        allowNull: false,
        defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
      }
    });

    console.log('[Migration] ✅ Rollback completed');

  } catch (error) {
    console.error('[Migration] ❌ Error during rollback:', error);
    throw error;
  }
}

module.exports = { up, down };
