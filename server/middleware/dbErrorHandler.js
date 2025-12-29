/**
 * Database Error Handler Middleware
 * Catches SQLite BUSY errors and returns HTTP 503 with Retry-After header
 */

function dbErrorHandler(err, req, res, next) {
  // Check if error is related to database lock/timeout
  const isDatabaseBusy = 
    err.name === 'SequelizeTimeoutError' ||
    err.name === 'SequelizeDatabaseError' ||
    err.message?.includes('SQLITE_BUSY') ||
    err.message?.includes('database is locked') ||
    err.original?.code === 'SQLITE_BUSY';

  if (isDatabaseBusy) {
    console.warn('[DB ERROR HANDLER] Database busy, returning 503:', err.message);
    
    // Return 503 Service Unavailable with Retry-After header
    return res.status(503)
      .set('Retry-After', '2') // Client should retry after 2 seconds
      .json({
        error: 'Database temporarily busy',
        message: 'The server is experiencing high load. Please try again in a moment.',
        retryAfter: 2,
        code: 'DATABASE_BUSY'
      });
  }

  // Check for other database errors
  if (err.name?.startsWith('Sequelize')) {
    console.error('[DB ERROR HANDLER] Database error:', err.name, err.message);
    
    return res.status(500).json({
      error: 'Database error',
      message: 'An error occurred while processing your request.',
      code: err.name
    });
  }

  // Pass to next error handler if not a database error
  next(err);
}

module.exports = dbErrorHandler;
