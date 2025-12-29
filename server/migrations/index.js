/**
 * Migration Runner
 * Automatically runs database migrations on server startup
 */

const fs = require('fs');
const path = require('path');

class MigrationRunner {
  constructor() {
    this.migrationsDir = __dirname;
    this.migrations = [];
    this.loadMigrations();
  }

  loadMigrations() {
    const files = fs.readdirSync(this.migrationsDir)
      .filter(file => file.endsWith('.js') && file !== 'index.js')
      .sort();

    this.migrations = files.map(file => {
      const migrationPath = path.join(this.migrationsDir, file);
      const migration = require(migrationPath);
      return {
        name: file,
        up: migration.up,
        down: migration.down
      };
    });

    console.log(`[MIGRATIONS] Loaded ${this.migrations.length} migration(s)`);
  }

  async runAll() {
    console.log('[MIGRATIONS] Running all pending migrations...');
    
    for (const migration of this.migrations) {
      try {
        console.log(`[MIGRATIONS] Running: ${migration.name}`);
        await migration.up();
        console.log(`[MIGRATIONS] ✓ Completed: ${migration.name}`);
      } catch (error) {
        console.error(`[MIGRATIONS] ✗ Failed: ${migration.name}`, error);
        // Continue with other migrations even if one fails
      }
    }
    
    console.log('[MIGRATIONS] All migrations completed');
  }

  async rollbackLast() {
    if (this.migrations.length === 0) {
      console.log('[MIGRATIONS] No migrations to rollback');
      return;
    }

    const migration = this.migrations[this.migrations.length - 1];
    
    try {
      console.log(`[MIGRATIONS] Rolling back: ${migration.name}`);
      await migration.down();
      console.log(`[MIGRATIONS] ✓ Rollback completed: ${migration.name}`);
    } catch (error) {
      console.error(`[MIGRATIONS] ✗ Rollback failed: ${migration.name}`, error);
      throw error;
    }
  }
}

module.exports = new MigrationRunner();
