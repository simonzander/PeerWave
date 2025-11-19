/**
 * Database migration for HMAC Session Authentication
 * Adds client_sessions and nonce_cache tables
 */

const { sequelize } = require('../db/model');

async function migrate() {
  console.log('🔄 Running HMAC Session Auth migration...');
  
  try {
    // Create client_sessions table
    await sequelize.query(`
      CREATE TABLE IF NOT EXISTS client_sessions (
        client_id VARCHAR(255) PRIMARY KEY,
        session_secret VARCHAR(255) NOT NULL,
        user_id VARCHAR(255) NOT NULL,
        expires_at DATETIME,
        device_info TEXT,
        last_used DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    `);
    console.log('✓ client_sessions table created/verified');
    
    // Create nonce_cache table
    await sequelize.query(`
      CREATE TABLE IF NOT EXISTS nonce_cache (
        nonce VARCHAR(255) PRIMARY KEY,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    `);
    console.log('✓ nonce_cache table created/verified');
    
    // Create indexes for performance
    await sequelize.query(`
      CREATE INDEX IF NOT EXISTS idx_sessions_user 
      ON client_sessions(user_id)
    `);
    
    await sequelize.query(`
      CREATE INDEX IF NOT EXISTS idx_sessions_expires 
      ON client_sessions(expires_at)
    `);
    
    await sequelize.query(`
      CREATE INDEX IF NOT EXISTS idx_nonce_created 
      ON nonce_cache(created_at)
    `);
    console.log('✓ Indexes created/verified');
    
    console.log('✅ HMAC Session Auth migration completed successfully');
  } catch (error) {
    console.error('❌ Migration failed:', error);
    throw error;
  }
}

// Run migration if called directly
if (require.main === module) {
  migrate()
    .then(() => process.exit(0))
    .catch(err => {
      console.error(err);
      process.exit(1);
    });
}

module.exports = { migrate };
