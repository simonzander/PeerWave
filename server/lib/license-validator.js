/**
 * PeerWave License Validator
 * 
 * Validates X.509 license certificates with:
 * - Signature verification against Root CA
 * - Expiration date check with grace period
 * - Custom extension parsing (features)
 * 
 * Usage:
 *   const LicenseValidator = require('./lib/license-validator');
 *   const validator = new LicenseValidator();
 *   const license = await validator.validate();
 *   
 *   if (license.valid) {
 *     console.log('License type:', license.type);
 *     console.log('Features:', license.features);
 *   }
 */

const forge = require('node-forge');
const fs = require('fs');
const path = require('path');

class LicenseValidator {
  constructor(options = {}) {
    this.certDir = options.certDir || path.join(__dirname, '../cert');
    this.caCertPath = path.join(this.certDir, 'ca-cert.pem');
    this.licenseCertPath = options.licensePath || path.join(this.certDir, 'license.crt');
    
    this._cache = null;
    this._lastCheck = null;
    this.cacheTimeout = options.cacheTimeout || 5 * 60 * 1000; // 5 minutes
  }

  /**
   * Validate the license certificate
   * @returns {Promise<Object>} License validation result
   */
  async validate() {
    // Return cached result if still valid
    if (this._cache && this._lastCheck && 
        (Date.now() - this._lastCheck) < this.cacheTimeout) {
      return this._cache;
    }

    const result = await this._performValidation();
    
    // Cache successful validations
    if (result.valid) {
      this._cache = result;
      this._lastCheck = Date.now();
    }

    return result;
  }

  /**
   * Perform actual validation (internal)
   * @private
   */
  async _performValidation() {
    try {
      // Check if CA certificate exists
      if (!fs.existsSync(this.caCertPath)) {
        return {
          valid: false,
          error: 'CA_NOT_FOUND',
          message: 'Root CA certificate not found. Server is not properly configured.',
          type: 'non-commercial',
          features: {}
        };
      }

      // Check if license certificate exists
      if (!fs.existsSync(this.licenseCertPath)) {
        return {
          valid: false,
          error: 'LICENSE_NOT_FOUND',
          message: 'No license certificate found. Using non-commercial mode.',
          type: 'non-commercial',
          features: {}
        };
      }

      // Load certificates
      const caCertPem = fs.readFileSync(this.caCertPath, 'utf8');
      const licenseCertPem = fs.readFileSync(this.licenseCertPath, 'utf8');

      const caCert = forge.pki.certificateFromPem(caCertPem);
      const licenseCert = forge.pki.certificateFromPem(licenseCertPem);

      // Verify certificate signature
      const caStore = forge.pki.createCaStore([caCert]);
      
      try {
        const verified = forge.pki.verifyCertificateChain(caStore, [licenseCert]);
        
        if (!verified) {
          return {
            valid: false,
            error: 'INVALID_SIGNATURE',
            message: 'License certificate signature is invalid.',
            type: 'non-commercial',
            features: {}
          };
        }
      } catch (e) {
        return {
          valid: false,
          error: 'VERIFICATION_FAILED',
          message: `Certificate verification failed: ${e.message}`,
          type: 'non-commercial',
          features: {}
        };
      }

      // Check expiration with grace period
      const now = new Date();
      const notBefore = licenseCert.validity.notBefore;
      const notAfter = licenseCert.validity.notAfter;
      
      // Parse features to get grace period from certificate
      const features = this._parseFeatures(licenseCert);
      const gracePeriodDays = features.gracePeriodDays || 30;
      
      // Calculate grace period end date
      const gracePeriodEnd = new Date(notAfter);
      gracePeriodEnd.setDate(gracePeriodEnd.getDate() + gracePeriodDays);

      // Check if certificate is not yet valid
      if (now < notBefore) {
        return {
          valid: false,
          error: 'NOT_YET_VALID',
          message: `License is not yet valid. Valid from: ${notBefore.toISOString().split('T')[0]}`,
          type: 'non-commercial',
          features: {}
        };
      }

      // Check if grace period has expired
      if (now > gracePeriodEnd) {
        return {
          valid: false,
          error: 'EXPIRED',
          message: `License expired on ${notAfter.toISOString().split('T')[0]} (grace period ended)`,
          type: 'non-commercial',
          features: {},
          expired: true,
          expiredDate: notAfter
        };
      }

      // Check if in grace period
      const inGracePeriod = now > notAfter && now <= gracePeriodEnd;
      const daysRemaining = inGracePeriod 
        ? Math.ceil((gracePeriodEnd - now) / (1000 * 60 * 60 * 24))
        : Math.ceil((notAfter - now) / (1000 * 60 * 60 * 24));

      // Extract customer name
      const customerField = licenseCert.subject.getField('CN');
      const customer = customerField ? customerField.value : 'Unknown';

      // Build result
      const result = {
        valid: true,
        customer: customer,
        type: features.type || 'non-commercial',
        features: features,
        expires: notAfter,
        daysRemaining: daysRemaining,
        serial: licenseCert.serialNumber,
        gracePeriodDays: gracePeriodDays
      };

      // Add grace period warning if applicable
      if (inGracePeriod) {
        result.gracePeriod = true;
        result.warning = `License expired on ${notAfter.toISOString().split('T')[0]}. Grace period ends in ${daysRemaining} days.`;
      }

      return result;

    } catch (error) {
      return {
        valid: false,
        error: 'VALIDATION_ERROR',
        message: `License validation error: ${error.message}`,
        type: 'non-commercial',
        features: {}
      };
    }
  }

  /**
   * Parse custom extension containing license features
   * @private
   */
  _parseFeatures(cert) {
    try {
      // Look for our custom extension (OID 1.3.6.1.4.1.99999.1)
      const customExt = cert.extensions.find(ext => ext.id === '1.3.6.1.4.1.99999.1');
      
      if (!customExt) {
        return { type: 'non-commercial' };
      }

      // Decode base64 value
      const jsonString = forge.util.decode64(customExt.value);
      const features = JSON.parse(jsonString);

      return features;

    } catch (error) {
      console.error('Failed to parse license features:', error.message);
      return { type: 'non-commercial' };
    }
  }

  /**
   * Clear validation cache (force recheck)
   */
  clearCache() {
    this._cache = null;
    this._lastCheck = null;
  }

  /**
   * Get a summary string of the license status
   * @returns {Promise<string>}
   */
  async getSummary() {
    const license = await this.validate();
    
    if (!license.valid) {
      return `❌ ${license.message || license.error}`;
    }

    let summary = `✅ Licensed to: ${license.customer}`;
    summary += `\n   Type: ${license.type}`;
    summary += `\n   Expires: ${license.expires.toISOString().split('T')[0]}`;
    
    if (license.gracePeriod) {
      summary += `\n   ⚠️  Grace Period: ${license.daysRemaining} days remaining`;
    } else {
      summary += `\n   Days Remaining: ${license.daysRemaining}`;
    }

    if (license.features.maxUsers) {
      summary += `\n   Max Users: ${license.features.maxUsers}`;
    }
    
    summary += `\n   Grace Period: ${license.gracePeriodDays || 30} days`;

    return summary;
  }
}

module.exports = LicenseValidator;
