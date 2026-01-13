/**
 * Log Sanitization Utility
 * Prevents log injection attacks by sanitizing user-controlled values before logging
 * 
 * Security:
 * - Removes newlines (\n, \r) to prevent log injection
 * - Removes control characters (\x00-\x1F, \x7F)
 * - Escapes % for format string safety
 * - Limits to 1000 chars to prevent flooding
 * 
 * Usage:
 * console.log(`User ${sanitizeForLog(userId)} performed action`);
 */

function sanitizeForLog(value) {
  if (value === null || value === undefined) return 'null';
  // Convert to string, remove newlines (log injection), and escape % (format string)
  return String(value)
    .replace(/[\n\r]/g, '') // Remove newlines to prevent log injection
    .replace(/[\x00-\x1F\x7F]/g, '') // Remove control characters
    .replace(/%/g, '%%') // Escape % to prevent format string interpretation
    .substring(0, 1000); // Limit length to prevent log flooding
}

module.exports = { sanitizeForLog };
