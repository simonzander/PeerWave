const { sequelize } = require('../db/model');

async function up() {
  const queryInterface = sequelize.getQueryInterface();

  console.log('Running migration: add_meeting_rsvps');

  const tables = await queryInterface.showAllTables();
  const tableName = tables.includes('meeting_rsvps') ? null : 'meeting_rsvps';

  if (!tableName) {
    console.log('- meeting_rsvps table already exists');
    return;
  }

  await queryInterface.createTable('meeting_rsvps', {
    id: {
      type: sequelize.Sequelize.INTEGER,
      primaryKey: true,
      autoIncrement: true,
      allowNull: false,
    },
    meeting_id: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
    },
    invitee_user_id: {
      type: sequelize.Sequelize.STRING,
      allowNull: true,
    },
    invitee_email: {
      type: sequelize.Sequelize.STRING,
      allowNull: true,
    },
    status: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      defaultValue: 'invited',
    },
    responded_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: true,
    },
    created_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP'),
    },
    updated_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP'),
    },
  });

  await queryInterface.addIndex('meeting_rsvps', ['meeting_id']);
  await queryInterface.addIndex('meeting_rsvps', ['meeting_id', 'invitee_user_id'], {
    unique: true,
    name: 'meeting_rsvps_meeting_user_unique',
  });
  await queryInterface.addIndex('meeting_rsvps', ['meeting_id', 'invitee_email'], {
    unique: true,
    name: 'meeting_rsvps_meeting_email_unique',
  });

  console.log('✓ Migration complete: add_meeting_rsvps');
}

async function down() {
  const queryInterface = sequelize.getQueryInterface();
  const tables = await queryInterface.showAllTables();
  if (tables.includes('meeting_rsvps')) {
    await queryInterface.dropTable('meeting_rsvps');
  }
}

module.exports = { up, down };
