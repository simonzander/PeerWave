/**
 * Run hybrid storage migration
 */

const migration = require('./update_meetings_hybrid_storage');

async function runMigration() {
  try {
    console.log('='.repeat(60));
    console.log('Starting Hybrid Storage Migration');
    console.log('='.repeat(60));
    
    await migration.up();
    
    console.log('='.repeat(60));
    console.log('Migration completed successfully!');
    console.log('='.repeat(60));
    
    process.exit(0);
  } catch (error) {
    console.error('='.repeat(60));
    console.error('Migration failed:', error);
    console.error('='.repeat(60));
    process.exit(1);
  }
}

runMigration();
