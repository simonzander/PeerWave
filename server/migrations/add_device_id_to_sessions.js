/**
 * Migration: Add device_id column to client_sessions table
 * 
 * This allows the server to know which device a client session belongs to,
 * enabling proper multi-device support with HMAC authentication.
 */

async function up({ sequelize, tableExists, columnExists }) {
  // Skip if table doesn't exist yet (fresh database)
  if (!(await tableExists('client_sessions'))) {
    return;
  }
  
  // Skip if column already exists
  if (await columnExists('client_sessions', 'device_id')) {
    return;
  }
  
  // Add device_id column
  await sequelize.query(`
    ALTER TABLE client_sessions 
    ADD COLUMN device_id INTEGER
  `);
  console.log('✓ device_id column added to client_sessions');
}

async function down() {
  console.log('Removing device_id column from client_sessions table...');
  
  try {
    // SQLite doesn't support DROP COLUMN directly, need to recreate table
    await sequelize.query(`
      CREATE TABLE client_sessions_backup AS SELECT 
        client_id, session_secret, user_id, expires_at, 
        device_info, last_used, created_at 
      FROM client_sessions
    `);
    
    await sequelize.query('DROP TABLE client_sessions');
    
    await sequelize.query(`
      CREATE TABLE client_sessions (
        client_id VARCHAR(255) PRIMARY KEY,
        session_secret VARCHAR(255) NOT NULL,
        user_id VARCHAR(255) NOT NULL,
        expires_at DATETIME,
        device_info TEXT,
        last_used DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    `);
    
    await sequelize.query(`
      INSERT INTO client_sessions 
      SELECT * FROM client_sessions_backup
    `);
    
    await sequelize.query('DROP TABLE client_sessions_backup');
    
    console.log('✓ device_id column removed from client_sessions');
  } catch (error) {
    console.error('✗ Error removing device_id column:', error);
    throw error;
  }
}

module.exports = { up, down };
