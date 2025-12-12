/**
 * Migration: Convert ExternalSession admission_status to boolean admitted field
 * Date: 2025-12-12
 * 
 * Changes:
 * - Add `admitted` BOOLEAN column (null/false/true)
 * - Add `last_admission_request` DATE column
 * - Migrate data from admission_status to admitted
 * - admission_status is DEPRECATED but kept for rollback safety
 */

const { temporaryStorage } = require('../db/model');

async function up() {
  console.log('[MIGRATION] Starting ExternalSession schema migration...');
  
  try {
    // ExternalSession uses temporaryStorage (in-memory SQLite)
    // Check if columns already exist
    const [columns] = await temporaryStorage.query(`
      PRAGMA table_info(ExternalSessions);
    `);
    
    const columnNames = columns.map(col => col.name);
    const hasAdmitted = columnNames.includes('admitted');
    const hasLastAdmissionRequest = columnNames.includes('last_admission_request');
    
    if (hasAdmitted && hasLastAdmissionRequest) {
      console.log('[MIGRATION] ✓ Columns already exist, skipping migration');
      return;
    }
    
    // Add new columns if they don't exist
    if (!hasAdmitted) {
      await temporaryStorage.query(`
        ALTER TABLE ExternalSessions ADD COLUMN admitted BOOLEAN DEFAULT NULL;
      `);
      console.log('[MIGRATION] ✓ Added admitted column');
    }
    
    if (!hasLastAdmissionRequest) {
      await temporaryStorage.query(`
        ALTER TABLE ExternalSessions ADD COLUMN last_admission_request DATETIME DEFAULT NULL;
      `);
      console.log('[MIGRATION] ✓ Added last_admission_request column');
    }
    
    // Migrate existing data (if any sessions exist)
    const [sessions] = await temporaryStorage.query(`
      SELECT session_id, admission_status FROM ExternalSessions WHERE admitted IS NULL;
    `);
    
    if (sessions.length > 0) {
      console.log(`[MIGRATION] Migrating ${sessions.length} existing sessions...`);
      
      for (const session of sessions) {
        let admittedValue = null;
        
        switch (session.admission_status) {
          case 'admitted':
            admittedValue = true;
            break;
          case 'waiting':
            admittedValue = null;
            break;
          case 'declined':
            admittedValue = null; // Allow retry
            break;
          default:
            admittedValue = null;
        }
        
        await temporaryStorage.query(`
          UPDATE ExternalSessions 
          SET admitted = ? 
          WHERE session_id = ?;
        `, {
          replacements: [admittedValue, session.session_id]
        });
      }
      
      console.log(`[MIGRATION] ✓ Migrated ${sessions.length} sessions`);
    }
    
    console.log('[MIGRATION] ✓ ExternalSession migration completed successfully');
  } catch (error) {
    console.error('[MIGRATION] ✗ Migration failed:', error);
    throw error;
  }
}

async function down() {
  console.log('[MIGRATION] Rolling back ExternalSession schema migration...');
  
  try {
    // Note: SQLite doesn't support DROP COLUMN directly
    // We keep the columns but could clear the data
    await temporaryStorage.query(`
      UPDATE ExternalSessions SET admitted = NULL, last_admission_request = NULL;
    `);
    
    console.log('[MIGRATION] ✓ Rollback completed (columns retained but cleared)');
  } catch (error) {
    console.error('[MIGRATION] ✗ Rollback failed:', error);
    throw error;
  }
}

module.exports = { up, down };
