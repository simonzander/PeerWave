# Database Initialization System

## Overview

The PeerWave database system ensures proper initialization on every server start:

1. **Migrations run FIRST** - Check and apply schema updates (idempotent)
2. **Model loads SECOND** - Creates tables via `sequelize.sync({ alter: true })`

This approach works for both fresh and existing databases:

- **Fresh database**: No tables exist → migrations skip → model creates all tables in proper order
- **Existing database**: Migrations update schema → model syncs (tables already match)

## How It Works

### Initialization Flow

```
Node.js Server Start (server.js)
    ↓
1. Run Migrations (db/init-database.js)
    ├── Connect to database
    ├── Scan migrations/ folder
    ├── Run each migration (idempotent)
    │   └── Skips if already applied or not needed
    └── Complete
    ↓
2. Load Model (db/model.js)
    ├── Define all table schemas
    ├── sequelize.sync({ alter: true })
    │   ├── Creates missing tables
    │   └── Updates existing tables to match models
    ├── Apply SQLite optimizations (WAL, cache, etc.)
    └── Ready
    ↓
3. Server Starts
    └── Routes, Socket.IO, etc.
```

### Key Principle

**Migrations = Schema Updates | Model = Schema Definition**

- **Migrations**: Modify existing structures (add column, create index, etc.)
- **Model**: Defines the complete schema (sync creates/updates tables)

On fresh install: Migrations have nothing to do, model creates everything
On update: Migrations update schema, model syncs the rest

### File Structure

```
server/
├── server.js                ← Runs migrations, then loads model
├── db/
│   ├── init-database.js     ← Migration runner (exported for server.js)
│   └── model.js             ← Defines schema, runs sync({ alter: true })
└── migrations/
    ├── *.js                 ← Idempotent migration files
    └── migrate.js           ← Deprecated standalone runner
```

## Key Components

### 1. server.js

Initialization happens at the top of server.js:

```javascript
// Database initialization - MUST happen before loading model
(async () => {
  console.log('DATABASE INITIALIZATION');
  
  // Step 1: Run migrations
  const { runMigrations } = require('./db/init-database');
  await runMigrations();
  
  console.log('✓ Migrations completed');
})();

// Step 2: Load model (will sync/create tables)
const { User, Channel, ... } = require('./db/model');
```

### 2. db/init-database.js

Exports `runMigrations()` function:

```javascript
async function runMigrations() {
  // Scan migrations/ folder
  // Run each migration (skip if already applied)
  // Idempotent - safe to re-run
}

module.exports = { runMigrations };
```

### 3. db/model.js

Creates tables after migrations:

```javascript
sequelize.authenticate().then(async () => {
  // Sync creates missing tables, updates existing
  await sequelize.sync({ alter: true });
  
  // Apply SQLite optimizations
  await sequelize.query("PRAGMA journal_mode=WAL");
  // ... more optimizations
});
```

### 2. Migration Files

All migrations are idempotent and check for existing changes:

```javascript
// Example migration structure
module.exports = {
  async up({ sequelize, tableExists, columnExists }) {
    // Skip if source table doesn't exist
    if (!(await tableExists('users'))) {
      console.log('   Users table not created yet, skipping migration');
      return;
    }
    
    // Add column only if needed
    if (!(await columnExists('users', 'new_column'))) {
      await sequelize.query(`ALTER TABLE users ADD COLUMN new_column TEXT`);
      console.log('   Added new_column to users');
    }
  }
};
```

**Best Practices:**
- Check `tableExists()` first - skip if base table doesn't exist
- Check `columnExists()` before ADD COLUMN
- Check `indexExists()` before CREATE INDEX  
- Return early if nothing to do
- Use descriptive names (e.g., `003_add_user_presence.js`)

### 3. Docker Integration

**No special Docker configuration needed** - everything runs in Node.js:

```dockerfile
# Standard Docker CMD
CMD [ "node", "server.js" ]
```

Server.js handles initialization automatically on start.

## Usage

### Normal Operation

Just start the server - initialization is automatic:

```bash
# Development
.\build-and-start.ps1

# Production
docker-compose up -d

# Direct
node server.js
```

### Manual Migration Test

```bash
# Test migrations without starting server
node db/init-database.js
```

## Migration Development

### Creating New Migrations

1. Create file in `server/migrations/`:
   ```
   server/migrations/add_new_feature.js
   ```

2. Implement idempotent up() function:
   ```javascript
   module.exports = {
     async up({ sequelize, tableExists, columnExists }) {
       // Check before creating
       if (!(await tableExists('new_feature'))) {
         await sequelize.query(`
           CREATE TABLE new_feature (
             id INTEGER PRIMARY KEY,
             name TEXT NOT NULL
           )
         `);
       }
     }
   };
   ```

3. Test locally:
   ```bash
   node db/init-database.js
   ```

4. Build and deploy:
   ```powershell
   .\build-and-start.ps1
   ```

### Migration Naming Convention

Use numbered prefixes for clear ordering:

```
001_initial_schema.js
002_add_user_presence.js
003_add_meetings_system.js
...
```

## Troubleshooting

### Check Server Startup Logs

```bash
# View server logs
docker logs peerwave-server

# Look for initialization sequence:
# ═══════════════════════════════════════
# DATABASE INITIALIZATION
# ═══════════════════════════════════════
#    Found X migration files
#    ✓ migration_name
#    ...
# ✓ Migrations completed
# ✓ Model connected to database
# ✓ Database schema synced
# ✓ SQLite optimizations applied
```

### Common Issues

**Issue: "no such table" error**
- Migrations run but table not created
- **Solution**: Check model.js - ensure table is defined and sync() is enabled

**Issue: "UNIQUE constraint failed"**
- Race condition on table insert
- **Solution**: Use `INSERT OR REPLACE` or check existence before INSERT

**Issue: Migration error on startup**
- Migration failing prevents server start
- **Solution**: Check migration logic, ensure idempotent, test standalone

### Manual Database Check

```bash
# Check table structure
docker exec peerwave-server sqlite3 db/peerwave.sqlite ".schema user_presence"

# Check all tables
docker exec peerwave-server sqlite3 db/peerwave.sqlite ".tables"
```

### Reset Database (Development Only)

```bash
# Stop containers
docker-compose -f docker-compose.dev.yml down

# Delete database file
rm server/db/peerwave.sqlite*

# Rebuild - fresh database will be created
.\build-and-start.ps1
```

## Benefits

✅ **Simple** - Migrations run automatically in server.js  
✅ **Fast** - Skip already-applied migrations instantly  
✅ **Safe** - Idempotent migrations prevent duplicate work  
✅ **Reliable** - Model sync creates tables in proper order  
✅ **Clean** - No external scripts, all in Node.js  
✅ **Fresh install friendly** - Works with no database file

## Migration Strategy

### Fresh Database (No Tables)

```
1. Migrations run → check tableExists() → false → skip
2. Model loads → sync() → creates ALL tables
3. Server starts with complete schema
```

### Existing Database (With Updates)

```
1. Migrations run → check needed → apply updates
2. Model loads → sync() → tables already exist → connects
3. Server starts with updated schema
```

This is much cleaner than the old system!
