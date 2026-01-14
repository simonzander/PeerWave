/**
 * Migration: Remove foreign key constraints from AbuseReport table
 * 
 * PURPOSE:
 * Abuse reports must be preserved for legal/compliance reasons even after
 * users are deleted. This migration removes foreign key constraints while
 * keeping the UUID fields as regular data columns.
 * 
 * CHANGES:
 * - reporter_uuid: Remove FK constraint to Users
 * - reported_uuid: Remove FK constraint to Users
 * - resolved_by: Remove FK constraint to Users
 */

const { sequelize } = require('../db/model');

async function up() {
  const queryInterface = sequelize.getQueryInterface();

  // Helper: Check if table exists
  const tableExists = async (tableName) => {
    const tables = await queryInterface.showAllTables();
    return tables.includes(tableName);
  };

  // Check if AbuseReport table exists
  if (!(await tableExists('abuse_reports'))) {
    console.log('ℹ AbuseReport table does not exist yet - skipping migration');
    return;
  }

  // Check if table has foreign keys by examining CREATE TABLE statement
  const [results] = await sequelize.query(
    "SELECT sql FROM sqlite_master WHERE type='table' AND name='abuse_reports'"
  );
  
  if (results.length === 0) {
    console.log('ℹ AbuseReport table not found - skipping migration');
    return;
  }

  const createStatement = results[0].sql;
  const hasForeignKeys = createStatement.includes('FOREIGN KEY') || createStatement.includes('REFERENCES');

  if (!hasForeignKeys) {
    console.log('✓ AbuseReport table already has no foreign keys - skipping migration');
    return;
  }

  console.log('→ Removing foreign key constraints from abuse_reports...');

  // SQLite doesn't support ALTER TABLE DROP FOREIGN KEY
  // We need to recreate the table without foreign keys
  
  // 1. Create new table without foreign keys
  await queryInterface.createTable('abuse_reports_new', {
    id: {
      type: sequelize.Sequelize.INTEGER,
      primaryKey: true,
      autoIncrement: true
    },
    report_uuid: {
      type: sequelize.Sequelize.UUID,
      allowNull: false,
      unique: true,
      defaultValue: sequelize.Sequelize.UUIDV4
    },
    reporter_uuid: {
      type: sequelize.Sequelize.UUID,
      allowNull: false
      // No foreign key - preserve reports after user deletion
    },
    reported_uuid: {
      type: sequelize.Sequelize.UUID,
      allowNull: false
      // No foreign key - preserve reports after user deletion
    },
    description: {
      type: sequelize.Sequelize.TEXT,
      allowNull: false
    },
    photos: {
      type: sequelize.Sequelize.TEXT,
      allowNull: true
    },
    status: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      defaultValue: 'pending'
    },
    admin_notes: {
      type: sequelize.Sequelize.TEXT,
      allowNull: true
    },
    resolved_by: {
      type: sequelize.Sequelize.UUID,
      allowNull: true
      // No foreign key - preserve reports after user deletion
    },
    resolved_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: true
    },
    created_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
    }
  });

  // 2. Copy all data from old table to new table
  await sequelize.query(`
    INSERT INTO abuse_reports_new 
    (id, report_uuid, reporter_uuid, reported_uuid, description, photos, status, admin_notes, resolved_by, resolved_at, created_at)
    SELECT id, report_uuid, reporter_uuid, reported_uuid, description, photos, status, admin_notes, resolved_by, resolved_at, created_at
    FROM abuse_reports
  `);

  // 3. Drop old table
  await queryInterface.dropTable('abuse_reports');

  // 4. Rename new table to original name
  await sequelize.query('ALTER TABLE abuse_reports_new RENAME TO abuse_reports');

  // 5. Recreate indexes
  await queryInterface.addIndex('abuse_reports', ['reporter_uuid'], {
    name: 'abuse_reports_reporter_uuid'
  });
  
  await queryInterface.addIndex('abuse_reports', ['reported_uuid'], {
    name: 'abuse_reports_reported_uuid'
  });
  
  await queryInterface.addIndex('abuse_reports', ['status'], {
    name: 'abuse_reports_status'
  });
  
  await queryInterface.addIndex('abuse_reports', ['report_uuid'], {
    name: 'abuse_reports_report_uuid',
    unique: true
  });

  console.log('✓ Removed foreign key constraints from abuse_reports');
  console.log('✓ Abuse reports will now be preserved when users are deleted');
}

async function down() {
  // Rolling back would re-add foreign keys, which could cause data loss
  // if users have already been deleted. Not recommended.
  console.log('⚠ Rollback not supported - would require re-adding foreign keys');
  console.log('⚠ Manual intervention required if rollback is needed');
}

module.exports = { up, down };

// Auto-run migration if executed directly
if (require.main === module) {
  up()
    .then(() => {
      console.log('Migration completed successfully');
      process.exit(0);
    })
    .catch(err => {
      console.error('Migration failed:', err);
      process.exit(1);
    });
}
