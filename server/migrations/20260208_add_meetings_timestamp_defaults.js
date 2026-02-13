const { sequelize } = require('../db/model');

/**
 * Ensure meetings table has DEFAULT CURRENT_TIMESTAMP on created_at/updated_at
 * and a trigger to auto-bump updated_at on UPDATE.
 * Idempotent and safe to run multiple times.
 */
async function up() {
  const queryInterface = sequelize.getQueryInterface();

  const tableExists = async (tableName) => {
    const tables = await queryInterface.showAllTables();
    return tables.includes(tableName);
  };

  const columnInfo = async (tableName) => {
    const [rows] = await sequelize.query(`PRAGMA table_info(${tableName})`);
    return rows;
  };

  const indexExists = async (indexName) => {
    const [rows] = await sequelize.query(
      `SELECT name FROM sqlite_master WHERE type='index' AND name=?`,
      { replacements: [indexName] }
    );
    return rows.length > 0;
  };

  const triggerExists = async (triggerName) => {
    const [rows] = await sequelize.query(
      `SELECT name FROM sqlite_master WHERE type='trigger' AND name=?`,
      { replacements: [triggerName] }
    );
    return rows.length > 0;
  };

  const normalizeDefault = (val) => {
    if (val === null || val === undefined) return null;
    return String(val).replace(/\(|\)/g, '').trim().toUpperCase();
  };

  if (!(await tableExists('meetings'))) {
    console.log('✓ meetings table not found, skipping');
    return;
  }

  const info = await columnInfo('meetings');
  const createdAtCol = info.find((c) => c.name === 'created_at');
  const updatedAtCol = info.find((c) => c.name === 'updated_at');
  const hasCreatedDefault = normalizeDefault(createdAtCol?.dflt_value) === 'CURRENT_TIMESTAMP';
  const hasUpdatedDefault = normalizeDefault(updatedAtCol?.dflt_value) === 'CURRENT_TIMESTAMP';

  // Rebuild table only if defaults are missing
  if (!hasCreatedDefault || !hasUpdatedDefault) {
    console.log('↻ Rebuilding meetings table to add timestamp defaults');
    const t = await sequelize.transaction();
    try {
      await sequelize.query('ALTER TABLE meetings RENAME TO meetings_old', { transaction: t });

      await queryInterface.createTable('meetings', {
        meeting_id: { type: sequelize.Sequelize.STRING(255), allowNull: false, primaryKey: true },
        title: { type: sequelize.Sequelize.STRING(255), allowNull: false },
        description: { type: sequelize.Sequelize.TEXT, allowNull: true },
        created_by: { type: sequelize.Sequelize.STRING(255), allowNull: false },
        start_time: { type: sequelize.Sequelize.DATE, allowNull: false },
        end_time: { type: sequelize.Sequelize.DATE, allowNull: false },
        is_instant_call: { type: sequelize.Sequelize.BOOLEAN, allowNull: false, defaultValue: false },
        allow_external: { type: sequelize.Sequelize.BOOLEAN, allowNull: false, defaultValue: false },
        invitation_token: { type: sequelize.Sequelize.STRING(255), allowNull: true },
        invited_participants: { type: sequelize.Sequelize.TEXT, allowNull: true },
        voice_only: { type: sequelize.Sequelize.BOOLEAN, allowNull: false, defaultValue: false },
        mute_on_join: { type: sequelize.Sequelize.BOOLEAN, allowNull: false, defaultValue: false },
        created_at: { type: sequelize.Sequelize.DATE, allowNull: false, defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP') },
        updated_at: { type: sequelize.Sequelize.DATE, allowNull: false, defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP') }
      }, { transaction: t });

      await sequelize.query(`
        INSERT INTO meetings (
          meeting_id, title, description, created_by, start_time, end_time,
          is_instant_call, allow_external, invitation_token, invited_participants,
          voice_only, mute_on_join, created_at, updated_at
        )
        SELECT
          meeting_id, title, description, created_by, start_time, end_time,
          is_instant_call, allow_external, invitation_token, invited_participants,
          voice_only, mute_on_join,
          COALESCE(created_at, CURRENT_TIMESTAMP),
          COALESCE(updated_at, CURRENT_TIMESTAMP)
        FROM meetings_old;
      `, { transaction: t });

      await sequelize.query('DROP TABLE meetings_old', { transaction: t });

      // Recreate indexes (if missing)
      const indexes = [
        { name: 'meetings_created_by', fields: ['created_by'] },
        { name: 'meetings_start_time', fields: ['start_time'] },
        { name: 'meetings_end_time', fields: ['end_time'] },
        { name: 'meetings_is_instant_call', fields: ['is_instant_call'] },
        { name: 'meetings_invitation_token', fields: ['invitation_token'] }
      ];

      for (const idx of indexes) {
        if (!(await indexExists(idx.name))) {
          await queryInterface.addIndex('meetings', idx.fields, { name: idx.name, transaction: t });
        }
      }

      await t.commit();
      console.log('✓ meetings table rebuilt with timestamp defaults');
    } catch (error) {
      await t.rollback();
      throw error;
    }
  } else {
    console.log('✓ meetings table already has timestamp defaults');
  }

  // Ensure trigger for updated_at
  if (!(await triggerExists('meetings_updated_at'))) {
    await sequelize.query(`
      CREATE TRIGGER meetings_updated_at
      AFTER UPDATE ON meetings
      FOR EACH ROW
      WHEN NEW.updated_at IS OLD.updated_at
      BEGIN
        UPDATE meetings SET updated_at = CURRENT_TIMESTAMP WHERE meeting_id = NEW.meeting_id;
      END;
    `);
    console.log('✓ meetings_updated_at trigger created');
  } else {
    console.log('✓ meetings_updated_at trigger already exists');
  }
}

async function down() {
  // Down migration: drop trigger only (non-destructive)
  const [rows] = await sequelize.query(
    "SELECT name FROM sqlite_master WHERE type='trigger' AND name='meetings_updated_at'"
  );
  if (rows.length > 0) {
    await sequelize.query('DROP TRIGGER meetings_updated_at');
    console.log('✓ meetings_updated_at trigger dropped');
  }
}

module.exports = { up, down };

// Allow standalone execution
if (require.main === module) {
  up()
    .then(() => { console.log('Migration completed successfully'); process.exit(0); })
    .catch((err) => { console.error('Migration failed:', err); process.exit(1); });
}
