const { sequelize } = require('../db/model');

// Adds additional per-user meeting notification settings.
// Safe to run multiple times.

async function hasColumn(tableName, columnName) {
  const [rows] = await sequelize.query(
    `PRAGMA table_info(${tableName})`
  );
  return rows.some((r) => r.name === columnName);
}

async function up() {
  try {
    const tableName = 'Users';
    
    // Check if Users table exists first
    const [tables] = await sequelize.query(
      `SELECT name FROM sqlite_master WHERE type='table' AND name='${tableName}'`
    );
    
    if (tables.length === 0) {
      console.log('⊙ Users table does not exist yet, skipping migration');
      return;
    }

    // meeting update email toggle
    if (!(await hasColumn(tableName, 'meeting_update_email_enabled'))) {
      await sequelize.query(
        `ALTER TABLE ${tableName} ADD COLUMN meeting_update_email_enabled BOOLEAN NOT NULL DEFAULT 1`
      );
      console.log('✓ Added Users.meeting_update_email_enabled');
    } else {
      console.log('- Users.meeting_update_email_enabled already exists');
    }

    // meeting cancel email toggle
    if (!(await hasColumn(tableName, 'meeting_cancel_email_enabled'))) {
      await sequelize.query(
        `ALTER TABLE ${tableName} ADD COLUMN meeting_cancel_email_enabled BOOLEAN NOT NULL DEFAULT 1`
      );
      console.log('✓ Added Users.meeting_cancel_email_enabled');
    } else {
      console.log('- Users.meeting_cancel_email_enabled already exists');
    }

    // organizer self-invite email toggle
    if (!(await hasColumn(tableName, 'meeting_self_invite_email_enabled'))) {
      await sequelize.query(
        `ALTER TABLE ${tableName} ADD COLUMN meeting_self_invite_email_enabled BOOLEAN NOT NULL DEFAULT 0`
      );
      console.log('✓ Added Users.meeting_self_invite_email_enabled');
    } else {
      console.log('- Users.meeting_self_invite_email_enabled already exists');
    }
  } catch (error) {
    // Don't throw on duplicate column errors - they mean the migration already ran
    if (error.name === 'SequelizeDatabaseError' && 
        (error.message.includes('duplicate column') || error.parent?.code === 'SQLITE_ERROR')) {
      console.log('   ⊙ Migration already applied or columns exist');
      return;
    }
    console.error('Error running meeting notification settings v2 migration:', error);
    throw error;
  }
}

async function down() {
  // SQLite cannot drop columns easily; no-op.
  console.warn('Down migration not supported for SQLite (no-op).');
}

module.exports = { up, down };
