/**
 * Migration: Fix refresh_tokens foreign key constraint
 * 
 * Problem: The refresh_tokens table was created with a foreign key
 * referencing 'ClientSessions' (capitalized) instead of 'client_sessions'
 * (the actual table name). This causes "no such table: main.ClientSessions" errors.
 * 
 * Solution: Drop and recreate the refresh_tokens table with correct FK reference.
 */

const { sequelize } = require('../db/model');

async function up() {
  const queryInterface = sequelize.getQueryInterface();

  // Helper: Check if table exists
  const tableExists = async (tableName) => {
    const tables = await queryInterface.showAllTables();
    return tables.includes(tableName);
  };

  // Check if refresh_tokens table exists
  if (await tableExists('refresh_tokens')) {
    console.log('[MIGRATION] Fixing refresh_tokens foreign key constraint...');
    
    // SQLite doesn't support ALTER TABLE for foreign keys
    // We need to recreate the table with the correct constraint
    
    // Step 1: Backup existing data (if any)
    const [existingTokens] = await sequelize.query(
      'SELECT * FROM refresh_tokens'
    );
    
    // Step 2: Drop the table
    await queryInterface.dropTable('refresh_tokens');
    console.log('[MIGRATION] Dropped refresh_tokens table');
    
    // Step 3: Recreate with correct foreign key
    await queryInterface.createTable('refresh_tokens', {
      token: {
        type: require('sequelize').DataTypes.STRING(255),
        primaryKey: true,
        allowNull: false
      },
      client_id: {
        type: require('sequelize').DataTypes.STRING,
        allowNull: false,
        references: {
          model: 'client_sessions',  // Fixed: was 'ClientSessions'
          key: 'client_id'
        }
      },
      user_id: {
        type: require('sequelize').DataTypes.UUID,
        allowNull: false,
        references: {
          model: 'Users',
          key: 'uuid'
        }
      },
      session_id: {
        type: require('sequelize').DataTypes.STRING,
        allowNull: true
      },
      expires_at: {
        type: require('sequelize').DataTypes.DATE,
        allowNull: false
      },
      created_at: {
        type: require('sequelize').DataTypes.DATE,
        allowNull: false,
        defaultValue: require('sequelize').Sequelize.NOW
      },
      used_at: {
        type: require('sequelize').DataTypes.DATE,
        allowNull: true
      },
      rotation_count: {
        type: require('sequelize').DataTypes.INTEGER,
        allowNull: false,
        defaultValue: 0
      }
    });
    console.log('[MIGRATION] Recreated refresh_tokens table with correct FK');
    
    // Step 4: Create indexes
    await sequelize.query(`
      CREATE INDEX IF NOT EXISTS refresh_tokens_client_id ON refresh_tokens(client_id)
    `);
    await sequelize.query(`
      CREATE INDEX IF NOT EXISTS refresh_tokens_user_id ON refresh_tokens(user_id)
    `);
    await sequelize.query(`
      CREATE INDEX IF NOT EXISTS refresh_tokens_expires_at ON refresh_tokens(expires_at)
    `);
    await sequelize.query(`
      CREATE UNIQUE INDEX IF NOT EXISTS refresh_tokens_token ON refresh_tokens(token)
    `);
    console.log('[MIGRATION] Created indexes');
    
    // Step 5: Restore data (if any was valid)
    if (existingTokens.length > 0) {
      console.log(`[MIGRATION] Restoring ${existingTokens.length} refresh tokens...`);
      for (const token of existingTokens) {
        try {
          await sequelize.query(`
            INSERT INTO refresh_tokens 
            (token, client_id, user_id, session_id, expires_at, created_at, used_at, rotation_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          `, {
            replacements: [
              token.token,
              token.client_id,
              token.user_id,
              token.session_id,
              token.expires_at,
              token.created_at,
              token.used_at,
              token.rotation_count
            ]
          });
        } catch (err) {
          console.log(`[MIGRATION] Skipping invalid token: ${err.message}`);
        }
      }
    }
    
    console.log('[MIGRATION] ✓ refresh_tokens foreign key fixed');
  } else {
    console.log('[MIGRATION] refresh_tokens table does not exist yet, skipping');
  }
}

async function down() {
  // Rollback not needed - the corrected schema is the desired state
  console.log('[MIGRATION] No rollback needed for refresh_tokens FK fix');
}

module.exports = { up, down };
