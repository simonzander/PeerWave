/**
 * Firebase Admin SDK Service
 * 
 * Initializes Firebase Admin SDK if credentials are provided via environment variables.
 * If credentials are not set, the service is disabled and push notifications will be skipped.
 * 
 * Environment variables:
 * - FIREBASE_SERVICE_ACCOUNT: JSON string containing the service account credentials
 *   OR
 * - FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY: Individual credential fields
 */

const logger = require('../utils/logger');

let admin = null;
let isConfigured = false;

try {
  // Check if Firebase credentials are provided
  let serviceAccount = null;

  // Option 1: Full JSON string
  if (process.env.FIREBASE_SERVICE_ACCOUNT) {
    try {
      serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
      logger.info('[FIREBASE ADMIN] Loaded credentials from FIREBASE_SERVICE_ACCOUNT');
    } catch (error) {
      logger.error('[FIREBASE ADMIN] Failed to parse FIREBASE_SERVICE_ACCOUNT:', error.message);
    }
  }
  // Option 2: Individual fields
  else if (process.env.FIREBASE_PROJECT_ID && process.env.FIREBASE_CLIENT_EMAIL && process.env.FIREBASE_PRIVATE_KEY) {
    serviceAccount = {
      projectId: process.env.FIREBASE_PROJECT_ID,
      clientEmail: process.env.FIREBASE_CLIENT_EMAIL,
      privateKey: process.env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, '\n') // Handle escaped newlines
    };
    logger.info('[FIREBASE ADMIN] Loaded credentials from individual env variables');
  }

  // Initialize Firebase Admin if credentials are available
  if (serviceAccount) {
    admin = require('firebase-admin');
    
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount)
    });
    
    isConfigured = true;
    logger.info('[FIREBASE ADMIN] ✅ Firebase Admin SDK initialized successfully');
  } else {
    logger.info('[FIREBASE ADMIN] ℹ️ Firebase not configured (no credentials provided)');
    logger.info('[FIREBASE ADMIN] Push notifications will be disabled');
  }
} catch (error) {
  logger.error('[FIREBASE ADMIN] ⚠️ Failed to initialize Firebase Admin SDK:', error.message);
  logger.info('[FIREBASE ADMIN] Push notifications will be disabled');
}

/**
 * Get Firebase Admin instance
 * @returns {admin|null} Firebase Admin instance or null if not configured
 */
function getAdmin() {
  return admin;
}

/**
 * Check if Firebase is configured and available
 * @returns {boolean} True if Firebase Admin is ready to use
 */
function isFirebaseConfigured() {
  return isConfigured;
}

module.exports = {
  getAdmin,
  isFirebaseConfigured
};
