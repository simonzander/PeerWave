#!/usr/bin/env node

/**
 * Manual Migration Runner
 * 
 * Run all migrations manually before starting the server:
 * node server/migrations/migrate.js
 * 
 * This replaces automatic migration on server startup to avoid
 * race conditions and startup failures.
 */

const path = require('path');

async function runMigrations() {
  console.log('='.repeat(60));
  console.log('DATABASE MIGRATIONS');
  console.log('='.repeat(60));
  console.log('');

  try {
    // Migration 1: HMAC Auth tables
    console.log('[1/4] HMAC Session Auth...');
    const hmacMigration = require('./add_hmac_auth');
    await hmacMigration.migrate();
    console.log('');

    // Migration 2: Meetings System (conditional - checks table existence)
    console.log('[2/4] Meetings System...');
    const meetingsMigration = require('./add_meetings_system');
    await meetingsMigration.up();
    console.log('');

    // Migration 3: Server Settings
    console.log('[3/4] Server Settings...');
    const settingsMigration = require('./add_server_settings');
    await settingsMigration.up();
    console.log('');

    // Migration 4: Hybrid Storage (conditional)
    console.log('[4/4] Hybrid Storage...');
    const hybridMigration = require('./update_meetings_hybrid_storage');
    await hybridMigration.up();
    console.log('');

    // NOTE: ExternalSession migration (001_external_session_boolean_admitted.js)
    // is NOT run here because ExternalSessions table is in-memory only
    // and is created by the model on server startup.
    // Schema changes to ExternalSession should be done in db/model.js

    console.log('='.repeat(60));
    console.log('✅ ALL MIGRATIONS COMPLETED SUCCESSFULLY');
    console.log('='.repeat(60));
    process.exit(0);
  } catch (error) {
    console.error('='.repeat(60));
    console.error('❌ MIGRATION FAILED');
    console.error('='.repeat(60));
    console.error(error);
    process.exit(1);
  }
}

// Run if called directly
if (require.main === module) {
  runMigrations();
}

module.exports = { runMigrations };
