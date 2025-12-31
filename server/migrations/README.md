# Database Migrations

## Overview

This directory contains database schema migrations for PeerWave. Migrations are run automatically on server startup and are **idempotent** (safe to run multiple times).

## Migration Strategy

### Source of Truth
- **Models (`db/model.js`)**: Define complete schema including columns, types, and indexes
- **Migrations**: Handle schema evolution for existing databases

### How It Works
1. Server starts → Migrations run first (in alphabetical order)
2. Each migration checks if changes already exist before applying
3. After migrations → `sequelize.sync({ alter: false })` creates any missing tables
4. Result: Fresh installs and migrated databases have identical schemas

### Key Principles
- ✅ Migrations must be **idempotent** - check before modifying
- ✅ Index names in migrations **must match** model definitions exactly
- ✅ Never use `sync({ alter: true })` - migrations handle all schema changes
- ✅ Test migrations on both fresh and existing databases

## Creating a New Migration

1. **Copy the template:**
   ```bash
   cp TEMPLATE.js add_my_feature.js
   ```

2. **Name your migration descriptively:**
   - `add_<table>_<column>.js` - Adding a column
   - `create_<table>.js` - Creating a new table
   - `update_<feature>.js` - Complex multi-table changes
   - Optional: Prefix with date `20251230_add_user_avatar.js`

3. **Edit the migration:**
   - Use helper functions (`tableExists`, `columnExists`, `indexExists`)
   - Always check before modifying
   - Match index names to model definitions

4. **Test thoroughly:**
   ```bash
   # Test on fresh database
   rm data/peerwave.sqlite
   npm start
   
   # Test on existing database
   npm start
   ```

5. **Update the model:**
   - Add corresponding model definition in `db/model.js`
   - Ensure index names match migration exactly

## Example Migration Flow

### Adding a new column:

**1. Create migration:** `migrations/add_user_bio.js`
```javascript
if (await tableExists('Users')) {
  if (!(await columnExists('Users', 'bio'))) {
    await queryInterface.addColumn('Users', 'bio', {
      type: sequelize.Sequelize.TEXT,
      allowNull: true
    });
  }
}
```

**2. Update model:** `db/model.js`
```javascript
const User = sequelize.define('User', {
  // ... existing fields
  bio: {
    type: DataTypes.TEXT,
    allowNull: true
  }
});
```

**3. Commit both files together**

## Running Migrations

Migrations run automatically on server startup via `db/init-database.js`.

**Manual execution (for testing):**
```bash
# Run specific migration
node migrations/add_user_bio.js

# Run all migrations
node db/init-database.js
```

## Current Migrations

No active migrations. All schema is defined in `db/model.js`.

_(Legacy migrations were removed in database cleanup - see commit 29775191b3b0158912c29e02992ef5a501a8f915)_

## Troubleshooting

### Error: Index already exists
**Cause:** Index name mismatch between migration and model  
**Fix:** Ensure index names in model match migration exactly

### Error: Column already exists
**Cause:** Migration not checking before adding column  
**Fix:** Add `columnExists` check before `addColumn`

### Different schemas on fresh vs migrated install
**Cause:** Model missing definitions that migrations create  
**Fix:** Ensure model includes ALL schema elements (especially indexes)

## Best Practices

1. **Always commit migrations with model changes**
2. **Never modify existing migrations** - create new ones
3. **Test on both fresh and existing databases**
4. **Use semantic names** that describe the change
5. **Keep migrations focused** - one logical change per file
6. **Document complex migrations** with comments

## Need Help?

- See `TEMPLATE.js` for a complete example
- Check existing migrations for patterns
- Review `db/init-database.js` for migration runner logic
