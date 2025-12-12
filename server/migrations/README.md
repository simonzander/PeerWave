# Database Migrations

## Overview

Database migrations are now **manual** and run separately from server startup to avoid race conditions and startup failures.

## Running Migrations

### Using the build script (recommended)

```bash
.\build-and-start.ps1
```

The build script automatically runs migrations on the host machine after starting Docker containers.

### Manual execution (recommended approach)

Run migrations on the host machine (the SQLite database is mounted from the host):

```bash
cd server
node migrations/migrate.js
```

### Inside Docker container (not recommended)

You can also run migrations inside the container, but it's better to run on the host:

```bash
docker-compose exec server node migrations/migrate.js
```

## Migration Files

Migrations are located in `server/migrations/` and run in this order:

1. **add_hmac_auth.js** - Creates HMAC session authentication tables
   - `client_sessions` - Client session storage with HMAC secrets
   - `nonce_cache` - Replay attack prevention
   - Indexes for performance

2. **add_meetings_system.js** - Creates meetings and participants tables
   - `meetings` - Meeting metadata (scheduled + instant calls)
   - `meeting_participants` - Meeting participant roles
   - Indexes for queries

3. **add_server_settings.js** - Server configuration tables
   - `ServerSettings` - Server name, registration mode, etc.
   - `Invitations` - Email invitations for closed registration

4. **update_meetings_hybrid_storage.js** - Migrates to hybrid storage model
   - Adds `invited_participants` JSON column to meetings
   - Removes runtime-only columns (`status`, `max_participants`, etc.)
   - Drops `meeting_participants` table (moved to memory)

## Special Cases

### ExternalSessions Table

The `ExternalSessions` table is **in-memory only** (created by `temporaryStorage` on server startup). 

Changes to ExternalSession schema should be made in:
- `server/db/model.js` - Update the Sequelize model definition

**Do NOT** create migrations for ExternalSessions as the table doesn't persist between restarts.

### Migration Files NOT Run

These files exist but are excluded from the migration runner:

- `001_external_session_boolean_admitted.js` - ExternalSession is in-memory only
- `add_device_id_to_sessions.js` - Already handled by add_hmac_auth.js
- `add_meeting_invitations.js` - Duplicate of add_meetings_system.js functionality
- `run_hybrid_storage_migration.js.standalone` - Standalone test script
- `index.js` - Old auto-runner (deprecated)

## Creating New Migrations

1. Create a new file in `server/migrations/`
2. Export an `up()` and optional `down()` function:

```javascript
const { sequelize } = require('../db/model');

async function up() {
  const queryInterface = sequelize.getQueryInterface();
  
  // Check if table/column/index exists first
  const tableExists = async (tableName) => {
    const tables = await queryInterface.showAllTables();
    return tables.includes(tableName);
  };
  
  if (!(await tableExists('my_table'))) {
    await queryInterface.createTable('my_table', {
      // ... column definitions
    });
  }
}

async function down() {
  // Optional rollback logic
}

module.exports = { up, down };
```

3. Add to `server/migrations/migrate.js` runner
4. Test with `node server/migrations/migrate.js`

## Best Practices

✅ **DO:**
- Check if table/column/index exists before creating
- Use `CREATE TABLE IF NOT EXISTS`
- Use `CREATE INDEX IF NOT EXISTS`
- Make migrations idempotent (safe to run multiple times)
- Test rollback logic if provided

❌ **DON'T:**
- Run migrations automatically on server startup
- Assume tables/columns don't exist
- Create migrations for in-memory tables (temporaryStorage)
- Modify old migrations after they've been run in production

## Troubleshooting

**"Table already exists" error:**
- Migration is not idempotent
- Add existence checks before creating tables/indexes

**"Column doesn't exist" error:**
- Another migration removed the column
- Add column existence check before creating indexes on it

**Migration fails in Docker:**
- Check Docker container logs: `docker-compose logs server`
- Run migration manually: `docker-compose exec server node migrations/migrate.js`
- Verify database file permissions

**ExternalSession migration fails:**
- This is expected - ExternalSession is in-memory only
- Make schema changes in `server/db/model.js` instead
