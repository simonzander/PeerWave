const rateLimit = require('express-rate-limit');
const logger = require('../utils/logger');

/**
 * Centralized Rate Limiting Configuration
 * 
 * Protects against DoS attacks by limiting request rates
 * Different limits for different types of endpoints
 */

// General API rate limiter - applies to most endpoints
const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100, // Max 100 requests per 15 minutes per IP
  message: 'Too many requests from this IP, please try again later.',
  standardHeaders: true, // Return rate limit info in `RateLimit-*` headers
  legacyHeaders: false, // Disable `X-RateLimit-*` headers
  handler: (req, res) => {
    logger.warn('[RATE_LIMIT] API limit exceeded', { ip: req.ip, path: req.path });
    res.status(429).json({
      error: 'Too many requests',
      message: 'Please try again later',
      retryAfter: Math.ceil(req.rateLimit.resetTime / 1000)
    });
  }
});

// Strict rate limiter for authentication endpoints
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 5, // Max 5 login attempts per 15 minutes per IP
  skipSuccessfulRequests: true, // Don't count successful logins
  message: 'Too many login attempts, please try again later.',
  handler: (req, res) => {
    logger.warn('[RATE_LIMIT] Auth limit exceeded', { ip: req.ip, path: req.path });
    res.status(429).json({
      error: 'Too many authentication attempts',
      message: 'Please try again in 15 minutes',
      retryAfter: Math.ceil(req.rateLimit.resetTime / 1000)
    });
  }
});

// Stricter limiter for registration/account creation
const registrationLimiter = rateLimit({
  windowMs: 60 * 60 * 1000, // 1 hour
  max: 3, // Max 3 registration attempts per hour per IP
  message: 'Too many accounts created, please try again later.',
  handler: (req, res) => {
    logger.warn('[RATE_LIMIT] Registration limit exceeded', { ip: req.ip });
    res.status(429).json({
      error: 'Too many registration attempts',
      message: 'Please try again in 1 hour',
      retryAfter: Math.ceil(req.rateLimit.resetTime / 1000)
    });
  }
});

// Moderate limiter for file uploads/downloads
const fileLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 50, // Max 50 file operations per 15 minutes per IP
  message: 'Too many file operations, please try again later.',
  handler: (req, res) => {
    logger.warn('[RATE_LIMIT] File operation limit exceeded', { ip: req.ip, path: req.path });
    res.status(429).json({
      error: 'Too many file operations',
      message: 'Please try again later',
      retryAfter: Math.ceil(req.rateLimit.resetTime / 1000)
    });
  }
});

// Lenient limiter for database query endpoints
const queryLimiter = rateLimit({
  windowMs: 1 * 60 * 1000, // 1 minute
  max: 30, // Max 30 queries per minute per IP
  message: 'Too many database queries, please slow down.',
  handler: (req, res) => {
    logger.warn('[RATE_LIMIT] Query limit exceeded', { ip: req.ip, path: req.path });
    res.status(429).json({
      error: 'Too many requests',
      message: 'Please slow down your request rate',
      retryAfter: Math.ceil(req.rateLimit.resetTime / 1000)
    });
  }
});

// Very strict limiter for password reset
const passwordResetLimiter = rateLimit({
  windowMs: 60 * 60 * 1000, // 1 hour
  max: 3, // Max 3 password reset attempts per hour per IP
  message: 'Too many password reset attempts.',
  handler: (req, res) => {
    logger.warn('[RATE_LIMIT] Password reset limit exceeded', { ip: req.ip });
    res.status(429).json({
      error: 'Too many password reset attempts',
      message: 'Please try again in 1 hour',
      retryAfter: Math.ceil(req.rateLimit.resetTime / 1000)
    });
  }
});

module.exports = {
  apiLimiter,
  authLimiter,
  registrationLimiter,
  fileLimiter,
  queryLimiter,
  passwordResetLimiter
};
