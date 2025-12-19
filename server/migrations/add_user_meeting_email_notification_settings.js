const { sequelize } = require('../db/model');

async function up() {
  const queryInterface = sequelize.getQueryInterface();

  console.log('Running migration: add_user_meeting_email_notification_settings');

  // Helper to find actual users table name
  const getUsersTableName = async () => {
    const tables = await queryInterface.showAllTables();
    if (tables.includes('Users')) return 'Users';
    if (tables.includes('users')) return 'users';
    // Fallback (Sequelize default for User model is usually 'Users')
    return 'Users';
  };

  const tableName = await getUsersTableName();

  // SQLite column existence check
  const tableInfo = await sequelize.query(
    `PRAGMA table_info(${tableName})`,
    { type: sequelize.QueryTypes.SELECT }
  );

  const hasColumn = (name) => tableInfo.some((c) => c.name === name);

  // Add meeting invite email toggle
  if (!hasColumn('meeting_invite_email_enabled')) {
    await queryInterface.addColumn(tableName, 'meeting_invite_email_enabled', {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: true,
    });
    console.log('✓ Added Users.meeting_invite_email_enabled');
  } else {
    console.log('- Users.meeting_invite_email_enabled already exists');
  }

  // Add organizer RSVP email toggle
  if (!hasColumn('meeting_rsvp_email_to_organizer_enabled')) {
    await queryInterface.addColumn(tableName, 'meeting_rsvp_email_to_organizer_enabled', {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: true,
    });
    console.log('✓ Added Users.meeting_rsvp_email_to_organizer_enabled');
  } else {
    console.log('- Users.meeting_rsvp_email_to_organizer_enabled already exists');
  }

  console.log('✓ Migration complete: add_user_meeting_email_notification_settings');
}

async function down() {
  const queryInterface = sequelize.getQueryInterface();

  const tables = await queryInterface.showAllTables();
  const tableName = tables.includes('Users') ? 'Users' : (tables.includes('users') ? 'users' : 'Users');

  try {
    await queryInterface.removeColumn(tableName, 'meeting_invite_email_enabled');
  } catch {}
  try {
    await queryInterface.removeColumn(tableName, 'meeting_rsvp_email_to_organizer_enabled');
  } catch {}
}

module.exports = { up, down };
