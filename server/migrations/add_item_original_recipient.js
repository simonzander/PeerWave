/**
 * Migration: Add originalRecipient to Items table
 * 
 * Purpose: Preserve the actual recipient when syncing messages to sender's other devices
 * 
 * Use case: When Alice sends to Bob, the message is encrypted for:
 * 1. Bob's devices: sender=Alice, receiver=Bob
 * 2. Alice's other devices: sender=Alice, receiver=Alice, originalRecipient=Bob
 * 
 * Without originalRecipient, Alice's other devices would show the message as "Alice -> Alice"
 * instead of "Alice -> Bob"
 */

const { sequelize, DataTypes } = require('../db/model');
const logger = require('../utils/logger');

async function up() {
  const queryInterface = sequelize.getQueryInterface();

  // Helper: Check if column exists
  const columnExists = async (tableName, columnName) => {
    try {
      const tableInfo = await queryInterface.describeTable(tableName);
      return columnName in tableInfo;
    } catch (error) {
      return false;
    }
  };

  try {
    // Check if originalRecipient column already exists
    if (await columnExists('Items', 'originalRecipient')) {
      logger.info('[MIGRATION] originalRecipient column already exists in Items table - skipping');
      return;
    }

    logger.info('[MIGRATION] Adding originalRecipient column to Items table...');

    // Add the column
    await queryInterface.addColumn('Items', 'originalRecipient', {
      type: DataTypes.UUID,
      allowNull: true,
      references: {
        model: 'Users',
        key: 'uuid'
      },
      comment: 'For multi-device sync: when sender device syncs to other sender devices, this preserves the original recipient'
    });

    logger.info('[MIGRATION] ✅ originalRecipient column added successfully');

  } catch (error) {
    logger.error('[MIGRATION] Failed to add originalRecipient column:', error);
    throw error;
  }
}

async function down() {
  const queryInterface = sequelize.getQueryInterface();

  // Helper: Check if column exists
  const columnExists = async (tableName, columnName) => {
    try {
      const tableInfo = await queryInterface.describeTable(tableName);
      return columnName in tableInfo;
    } catch (error) {
      return false;
    }
  };

  try {
    if (!(await columnExists('Items', 'originalRecipient'))) {
      logger.info('[MIGRATION ROLLBACK] originalRecipient column does not exist - skipping');
      return;
    }

    logger.info('[MIGRATION ROLLBACK] Removing originalRecipient column from Items table...');

    await queryInterface.removeColumn('Items', 'originalRecipient');

    logger.info('[MIGRATION ROLLBACK] ✅ originalRecipient column removed successfully');

  } catch (error) {
    logger.error('[MIGRATION ROLLBACK] Failed to remove originalRecipient column:', error);
    throw error;
  }
}

module.exports = { up, down };
