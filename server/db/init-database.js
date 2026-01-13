#!/usr/bin/env node

/**
 * Database Initialization System
 * 
 * This script runs BEFORE the server starts to:
 * 1. Run all migrations (idempotent - safe to re-run)
 * 2. Create/update tables from model definitions
 * 3. Ensure proper table creation order
 * 
 * Usage:
 *   node db/init-database.js
 * 
 * Called automatically by Docker entrypoint and build scripts.
 */

const path = require('path');
const fs = require('fs').promises;
const { Sequelize } = require('sequelize');
const logger = require('../utils/logger');

// Resolve absolute path to database (same as model.js)
const dbPath = process.env.DB_PATH || path.join(__dirname, '../data/peerwave.sqlite');

// Create sequelize instance (same config as model.js)
const sequelize = new Sequelize({
    dialect: 'sqlite',
    storage: dbPath,
    logging: false,
    pool: {
        max: 1,
        min: 0,
        acquire: 30000,
        idle: 10000
    }
});

/**
 * Helper: Check if table exists
 */
async function tableExists(tableName) {
  try {
    const [results] = await sequelize.query(
      `SELECT name FROM sqlite_master WHERE type='table' AND name='${tableName}'`
    );
    return results.length > 0;
  } catch (error) {
    logger.error(`Error checking if table ${tableName} exists:`, error);
    return false;
  }
}

/**
 * Helper: Check if column exists
 */
async function columnExists(tableName, columnName) {
  try {
    const [results] = await sequelize.query(
      `PRAGMA table_info(${tableName})`
    );
    return results.some(col => col.name === columnName);
  } catch (error) {
    return false;
  }
}

/**
 * Step 1: Run all migrations
 */
async function runMigrations() {
  const migrationsDir = path.join(__dirname, '../migrations');
  
  try {
    // Get all migration files
    const files = await fs.readdir(migrationsDir);
    const migrationFiles = files
      .filter(f => f.endsWith('.js') && f !== 'migrate.js' && f !== 'index.js' && !f.startsWith('_'))
      .sort(); // Alphabetical order

    if (migrationFiles.length === 0) {
      logger.info('   No migration files found');
      return;
    }

    logger.info(`   Found ${migrationFiles.length} migration files`);

    for (const file of migrationFiles) {
      const migrationName = file.replace('.js', '');
      
      try {
        const migration = require(path.join(migrationsDir, file));
        
        // Run migration (migrations should be idempotent)
        if (migration.up) {
          await migration.up({ sequelize, tableExists, columnExists });
        } else if (migration.migrate) {
          await migration.migrate({ sequelize, tableExists, columnExists });
        }
        
        logger.info(`   ✓ ${migrationName}`);
      } catch (error) {
        // Log error but continue - migrations might fail if already applied
        if (error.message.includes('already exists') || 
            error.message.includes('duplicate column') ||
            error.message.includes('no such table')) {
          logger.debug(`   ⊚ ${migrationName} (already applied or not needed)`);
        } else {
          logger.warn(`   ⚠ ${migrationName}:`, error.message);
        }
      }
    }
  } catch (error) {
    logger.error('❌ Migration error:', error);
    throw error;
  }
}

/**
 * Step 2: Ensure model tables exist with proper structure
 * This syncs model definitions to database
 */
async function syncModelTables() {
  logger.info('📊 Syncing model tables...');
  
  try {
    // Import model to register all table definitions
    const { sequelize: modelSequelize } = require('./model');
    
    // Sync models to database using the model's sequelize instance
    // alter: true - updates existing tables to match models
    // This is safe because migrations have already run
    await modelSequelize.sync({ alter: true });
    
    logger.info('✓ Model tables synced\n');
  } catch (error) {
    logger.error('❌ Model sync error:', error);
    throw error;
  }
}

/**
 * Step 3: Set SQLite optimizations
 */
async function setSQLiteOptimizations() {
  logger.info('⚙️  Setting SQLite optimizations...');
  
  try {
    await sequelize.query("PRAGMA journal_mode=WAL");
    await sequelize.query("PRAGMA busy_timeout=5000");
    await sequelize.query("PRAGMA synchronous=NORMAL");
    await sequelize.query("PRAGMA cache_size=-64000");
    await sequelize.query("PRAGMA temp_store=MEMORY");
    
    logger.info('✓ SQLite optimized\n');
  } catch (error) {
    logger.warn('⚠ Could not set all SQLite optimizations:', error.message);
  }
}

/**
 * Main initialization function
 */
async function initializeDatabase() {
  logger.info('═'.repeat(70));
  logger.info('DATABASE INITIALIZATION');
  logger.info('═'.repeat(70));
  logger.info('');

  try {
    // Connect to database
    await sequelize.authenticate();
    logger.info('✓ Database connection established\n');

    // Step 1: Run migrations first (before models)
    await runMigrations();

    // Step 2: Sync model tables (creates missing tables, updates existing)
    await syncModelTables();

    // Step 3: Apply SQLite optimizations
    await setSQLiteOptimizations();

    logger.info('═'.repeat(70));
    logger.info('✅ DATABASE INITIALIZATION COMPLETE');
    logger.info('═'.repeat(70));
    logger.info('');

    await sequelize.close();
    process.exit(0);
  } catch (error) {
    logger.error('═'.repeat(70));
    logger.error('❌ DATABASE INITIALIZATION FAILED');
    logger.error('═'.repeat(70));
    logger.error(error);
    await sequelize.close();
    process.exit(1);
  }
}

// Run if called directly
if (require.main === module) {
  initializeDatabase();
}

module.exports = { initializeDatabase, runMigrations, tableExists, columnExists };
