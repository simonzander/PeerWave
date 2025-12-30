/**
 * Migration Template
 * 
 * NAMING CONVENTION:
 * - Use descriptive names: add_<table>_<column>.js, create_<table>.js, update_<feature>.js
 * - Prefix with timestamp for ordering: 20251230_add_user_avatar.js (optional)
 * - DO NOT use underscore prefix - that prevents execution
 * 
 * IMPORTANT PRINCIPLES:
 * - Migrations must be IDEMPOTENT (safe to run multiple times)
 * - Always check if changes already exist before applying
 * - Handle both fresh installs and existing databases
 * - Index names in migrations must match model definitions exactly
 * - Never use sync() or alter - migrations are the source of truth for schema changes
 */

const { sequelize } = require('../db/model');

async function up() {
  const queryInterface = sequelize.getQueryInterface();

  // Helper: Check if table exists
  const tableExists = async (tableName) => {
    const tables = await queryInterface.showAllTables();
    return tables.includes(tableName);
  };

  // Helper: Check if column exists
  const columnExists = async (tableName, columnName) => {
    try {
      const tableInfo = await queryInterface.describeTable(tableName);
      return columnName in tableInfo;
    } catch (error) {
      return false;
    }
  };

  // Helper: Check if index exists
  const indexExists = async (tableName, indexName) => {
    try {
      const [results] = await sequelize.query(
        `SELECT name FROM sqlite_master WHERE type='index' AND name='${indexName}'`
      );
      return results.length > 0;
    } catch (error) {
      return false;
    }
  };

  // Example: Create a new table
  if (!(await tableExists('NewTable'))) {
    await queryInterface.createTable('NewTable', {
      id: {
        type: sequelize.Sequelize.INTEGER,
        primaryKey: true,
        autoIncrement: true
      },
      name: {
        type: sequelize.Sequelize.STRING,
        allowNull: false
      },
      created_at: {
        type: sequelize.Sequelize.DATE,
        allowNull: false,
        defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
      },
      updated_at: {
        type: sequelize.Sequelize.DATE,
        allowNull: false,
        defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
      }
    });
    console.log('✓ Created NewTable');
  }

  // Example: Add a column to existing table
  if (await tableExists('Users')) {
    if (!(await columnExists('Users', 'avatar_url'))) {
      await queryInterface.addColumn('Users', 'avatar_url', {
        type: sequelize.Sequelize.STRING,
        allowNull: true
      });
      console.log('✓ Added avatar_url to Users');
    }
  }

  // Example: Create an index (MUST match model index name)
  if (!(await indexExists('NewTable', 'new_table_name'))) {
    await queryInterface.addIndex('NewTable', ['name'], { 
      name: 'new_table_name' // Name must match model definition
    });
    console.log('✓ Created index new_table_name');
  }

  // Example: Update data
  const [results] = await sequelize.query('SELECT COUNT(*) as count FROM NewTable');
  if (results[0].count === 0) {
    await queryInterface.bulkInsert('NewTable', [{
      name: 'Default Entry',
      created_at: new Date(),
      updated_at: new Date()
    }]);
    console.log('✓ Inserted default data');
  }

  console.log('✓ Migration completed: TEMPLATE');
}

async function down() {
  const queryInterface = sequelize.getQueryInterface();
  
  // Reverse all changes made in up()
  // Note: down() is rarely used in production but good for development
  
  await queryInterface.removeColumn('Users', 'avatar_url');
  await queryInterface.dropTable('NewTable');
  
  console.log('✓ Migration rolled back: TEMPLATE');
}

module.exports = { up, down };

// Auto-run migration if executed directly
if (require.main === module) {
  up()
    .then(() => {
      console.log('Migration completed successfully');
      process.exit(0);
    })
    .catch(err => {
      console.error('Migration failed:', err);
      process.exit(1);
    });
}
