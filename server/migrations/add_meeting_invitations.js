/**
 * Migration: Add meeting_invitations table
 * 
 * This table stores multiple invitation tokens per meeting, replacing the single
 * invitation_token column on the meetings table. Tokens are persisted across
 * server restarts and automatically deleted when the meeting is deleted.
 */

const { sequelize } = require('../db/model');

async function up() {
  const queryInterface = sequelize.getQueryInterface();
  
  console.log('Running migration: add_meeting_invitations');

  // Helper to check if table exists
  const tableExists = async (tableName) => {
    try {
      const tables = await queryInterface.showAllTables();
      return tables.includes(tableName);
    } catch (error) {
      return false;
    }
  };

    // Create meeting_invitations table
    if (!(await tableExists('meeting_invitations'))) {
      await queryInterface.createTable('meeting_invitations', {
        id: {
          type: sequelize.Sequelize.INTEGER,
          primaryKey: true,
          autoIncrement: true
        },
        meeting_id: {
          type: sequelize.Sequelize.STRING,
          allowNull: false,
          references: {
            model: 'meetings',
            key: 'meeting_id'
          },
          onDelete: 'CASCADE'
        },
        token: {
          type: sequelize.Sequelize.STRING,
          allowNull: false,
          unique: true
        },
        label: {
          type: sequelize.Sequelize.STRING,
          allowNull: true
        },
        created_by: {
          type: sequelize.Sequelize.STRING,
          allowNull: false
        },
        expires_at: {
          type: sequelize.Sequelize.DATE,
          allowNull: true
        },
        max_uses: {
          type: sequelize.Sequelize.INTEGER,
          allowNull: true
        },
        use_count: {
          type: sequelize.Sequelize.INTEGER,
          allowNull: false,
          defaultValue: 0
        },
        is_active: {
          type: sequelize.Sequelize.BOOLEAN,
          allowNull: false,
          defaultValue: true
        },
        created_at: {
          type: sequelize.Sequelize.DATE,
          allowNull: false,
          defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
        },
        updated_at: {
          type: sequelize.Sequelize.DATE,
          allowNull: false,
          defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
        }
      });

      console.log('✓ Created meeting_invitations table');

      // Add indexes
      await queryInterface.addIndex('meeting_invitations', ['meeting_id'], {
        name: 'meeting_invitations_meeting_id'
      });
      await queryInterface.addIndex('meeting_invitations', ['token'], {
        name: 'meeting_invitations_token',
        unique: true
      });
      await queryInterface.addIndex('meeting_invitations', ['is_active'], {
        name: 'meeting_invitations_is_active'
      });

      console.log('✓ Added indexes to meeting_invitations');

      // Migrate existing invitation_token from meetings table
      const [meetings] = await sequelize.query(`
        SELECT meeting_id, invitation_token, created_by
        FROM meetings
        WHERE invitation_token IS NOT NULL
      `);

      if (meetings.length > 0) {
        console.log(`Migrating ${meetings.length} existing invitation tokens...`);
        
        for (const meeting of meetings) {
          await sequelize.query(`
            INSERT INTO meeting_invitations (meeting_id, token, created_by, is_active, use_count, created_at, updated_at)
            VALUES (?, ?, ?, 1, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
          `, {
            replacements: [meeting.meeting_id, meeting.invitation_token, meeting.created_by]
          });
        }

        console.log(`✓ Migrated ${meetings.length} existing invitation tokens`);
      }
    } else {
      console.log('meeting_invitations table already exists, skipping');
    }

    console.log('✓ Migration complete: add_meeting_invitations');
}

async function down() {
    const queryInterface = sequelize.getQueryInterface();
    console.log('Rolling back migration: add_meeting_invitations');
    await queryInterface.dropTable('meeting_invitations');
    console.log('✓ Dropped meeting_invitations table');
}

module.exports = { up, down };
