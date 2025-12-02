const { sequelize } = require('../db/model');

async function up() {
  const queryInterface = sequelize.getQueryInterface();

  // Create ServerSettings table
  await queryInterface.createTable('ServerSettings', {
    id: {
      type: sequelize.Sequelize.INTEGER,
      primaryKey: true,
      autoIncrement: true
    },
    server_name: {
      type: sequelize.Sequelize.STRING,
      allowNull: true,
      defaultValue: 'PeerWave Server'
    },
    server_picture: {
      type: sequelize.Sequelize.TEXT,
      allowNull: true
    },
    registration_mode: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      defaultValue: 'open' // 'open', 'email_suffix', 'invitation_only'
    },
    allowed_email_suffixes: {
      type: sequelize.Sequelize.TEXT, // JSON array stored as text
      allowNull: true,
      defaultValue: '[]'
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

  // Insert default settings row
  await queryInterface.bulkInsert('ServerSettings', [{
    id: 1,
    server_name: 'PeerWave Server',
    server_picture: null,
    registration_mode: 'open',
    allowed_email_suffixes: '[]',
    created_at: new Date(),
    updated_at: new Date()
  }]);

  // Create Invitations table
  await queryInterface.createTable('Invitations', {
    id: {
      type: sequelize.Sequelize.INTEGER,
      primaryKey: true,
      autoIncrement: true
    },
    email: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      unique: false // Allow multiple invitations for same email (if previous expired)
    },
    token: {
      type: sequelize.Sequelize.STRING(6),
      allowNull: false,
      unique: true
    },
    created_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
    },
    expires_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false
    },
    used: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    used_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: true
    },
    invited_by: {
      type: sequelize.Sequelize.STRING,
      allowNull: false
    }
  });

  // Create indexes for Invitations
  await queryInterface.addIndex('Invitations', ['email']);
  await queryInterface.addIndex('Invitations', ['token'], { unique: true });
  await queryInterface.addIndex('Invitations', ['expires_at']);

  console.log('✓ ServerSettings and Invitations tables created');
}

async function down() {
  const queryInterface = sequelize.getQueryInterface();
  
  await queryInterface.dropTable('Invitations');
  await queryInterface.dropTable('ServerSettings');
  
  console.log('✓ ServerSettings and Invitations tables dropped');
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
