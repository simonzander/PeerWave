// Fix CURRENT_TIMESTAMP strings in meetings table
const { sequelize } = require('./db/model');

(async () => {
  try {
    console.log('Fixing CURRENT_TIMESTAMP strings in meetings table...');
    
    const [results] = await sequelize.query(`
      UPDATE meetings 
      SET created_at = datetime('now'), 
          updated_at = datetime('now') 
      WHERE created_at = 'CURRENT_TIMESTAMP' 
         OR updated_at = 'CURRENT_TIMESTAMP'
    `);
    
    console.log('Successfully fixed CURRENT_TIMESTAMP strings');
    console.log('Rows affected:', results);
    
    process.exit(0);
  } catch (error) {
    console.error('Error fixing timestamps:', error);
    process.exit(1);
  }
})();
