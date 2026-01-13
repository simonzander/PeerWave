/**
 * Logger Utility with winston
 * 
 * Provides environment-aware logging:
 * - Development: Logs everything (debug, info, warn, error) with colors
 * - Production: Logs only warnings and errors
 * 
 * Usage:
 *   const logger = require('./utils/logger');
 *   logger.info('Server started');
 *   logger.debug('Debug info', { userId: 123 });
 *   logger.warn('Warning message');
 *   logger.error('Error occurred', error);
 * 
 * For user-controlled values, use with sanitizeForLog:
 *   const { sanitizeForLog } = require('./utils/logSanitizer');
 *   logger.info(`User ${sanitizeForLog(userId)} performed action`);
 */

const winston = require('winston');
const path = require('path');

// Determine environment - default to 'production' for safety
const isProduction = process.env.NODE_ENV === 'production';
const isDevelopment = process.env.NODE_ENV === 'development';

// Set log level based on environment
// Production: info, warn, error (skips debug)
// Development: debug, info, warn, error (everything)
const logLevel = isProduction ? 'info' : 'debug';

// Custom format for console output
const consoleFormat = winston.format.combine(
  winston.format.colorize(),
  winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
  winston.format.printf(({ timestamp, level, message, ...meta }) => {
    let msg = `${timestamp} [${level}]: ${message}`;
    
    // Add metadata if present
    if (Object.keys(meta).length > 0) {
      // Filter out winston's internal properties
      const cleanMeta = Object.fromEntries(
        Object.entries(meta).filter(([key]) => !['timestamp', 'level', 'message'].includes(key))
      );
      if (Object.keys(cleanMeta).length > 0) {
        msg += ` ${JSON.stringify(cleanMeta)}`;
      }
    }
    
    return msg;
  })
);

// File format (JSON for production, easier to parse)
const fileFormat = winston.format.combine(
  winston.format.timestamp(),
  winston.format.json()
);

// Create the logger instance
const logger = winston.createLogger({
  level: logLevel,
  format: fileFormat,
  transports: [
    // Console transport - always enabled
    new winston.transports.Console({
      format: consoleFormat
    })
  ],
  // Prevent unhandled exceptions from crashing the app
  exitOnError: false
});

// In production, also log to files
if (isProduction) {
  logger.add(new winston.transports.File({ 
    filename: path.join(__dirname, '../logs/error.log'),
    level: 'error',
    format: fileFormat
  }));
  logger.add(new winston.transports.File({ 
    filename: path.join(__dirname, '../logs/combined.log'),
    level: 'info',
    format: fileFormat
  }));
}

// Log startup configuration
logger.info(`Logger initialized in ${isProduction ? 'PRODUCTION' : isDevelopment ? 'DEVELOPMENT' : 'DEFAULT'} mode`);
logger.info(`Log level: ${logLevel.toUpperCase()}`);

module.exports = logger;
