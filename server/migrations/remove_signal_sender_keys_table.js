/**
 * Migration: Remove SignalSenderKeys table
 * 
 * REASON:
 * Signal Protocol compliance - sender keys should NOT be stored on server
 * Sender keys are distributed via 1-to-1 encrypted channels between clients
 * Server only routes encrypted payloads, never sees or stores sender keys
 * 
 * This migration:
 * - Drops SignalSenderKeys table if it exists
 * - Cleans up any foreign key constraints
 * - Idempotent - safe to run multiple times
 */

const { sequelize } = require('../db/model');
const logger = require('../utils/logger');

async function up() {
  const queryInterface = sequelize.getQueryInterface();

  // Helper: Check if table exists
  const tableExists = async (tableName) => {
    const tables = await queryInterface.showAllTables();
    return tables.includes(tableName);
  };

  try {
    logger.info('[MIGRATION] Checking for SignalSenderKeys table...');

    // Check if SignalSenderKeys table exists
    const exists = await tableExists('SignalSenderKeys');

    if (exists) {
      logger.info('[MIGRATION] SignalSenderKeys table found - removing...');
      
      // SQLite automatically handles foreign key constraints when dropping table
      await queryInterface.dropTable('SignalSenderKeys');
      
      logger.info('[MIGRATION] ✅ SignalSenderKeys table removed successfully');
      logger.info('[MIGRATION] Sender keys will now be distributed via encrypted 1-to-1 channels (Signal Protocol compliant)');
    } else {
      logger.info('[MIGRATION] SignalSenderKeys table does not exist - nothing to remove');
    }

    logger.info('[MIGRATION] Migration completed successfully');
  } catch (error) {
    logger.error('[MIGRATION] Error removing SignalSenderKeys table:', error);
    throw error;
  }
}

async function down() {
  // No rollback - we don't want to recreate the table
  // If rollback is needed, the table schema would be:
  logger.warn('[MIGRATION] Rollback not implemented - SignalSenderKeys table should not be restored');
  logger.warn('[MIGRATION] Sender keys should be distributed via 1-to-1 encrypted channels per Signal Protocol');
  
  /*
  // DO NOT UNCOMMENT - For reference only
  const queryInterface = sequelize.getQueryInterface();
  await queryInterface.createTable('SignalSenderKeys', {
    id: {
      type: DataTypes.INTEGER,
      primaryKey: true,
      autoIncrement: true
    },
    channel: {
      type: DataTypes.UUID,
      allowNull: false,
      references: { model: 'Channels', key: 'uuid' }
    },
    client: {
      type: DataTypes.UUID,
      allowNull: false,
      references: { model: 'Clients', key: 'clientid' }
    },
    owner: {
      type: DataTypes.UUID,
      allowNull: false,
      references: { model: 'Users', key: 'uuid' }
    },
    sender_key: {
      type: DataTypes.TEXT,
      allowNull: false
    },
    createdAt: DataTypes.DATE,
    updatedAt: DataTypes.DATE
  });
  */
}

module.exports = { up, down };
