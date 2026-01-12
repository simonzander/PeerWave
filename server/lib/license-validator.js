/**
 * PeerWave License Validator - Binary Wrapper
 * 
 * This validator calls the compiled binary (license-validator.exe) which has:
 * - Embedded CA certificate with hash pinning
 * - Compiled/obfuscated code for tamper resistance
 * - Standalone execution without file system CA access
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

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const logger = require('../utils/logger');

class LicenseValidator {
  constructor(options = {}) {
    this.certDir = options.certDir || path.join(__dirname, '../cert');
    this.licenseCertPath = options.licensePath || path.join(this.certDir, 'license.crt');
    
    // Path to compiled binary validator
    this.validatorBinary = this._getValidatorBinary();
    
    this._cache = null;
    this._lastCheck = null;
    this.cacheTimeout = options.cacheTimeout || 5 * 60 * 1000; // 5 minutes
  }

  /**
   * Get the appropriate binary path for current platform
   * @private
   */
  _getValidatorBinary() {
    const binDir = path.join(__dirname, '../bin');
    const platform = os.platform();
    
    let binaryName;
    if (platform === 'win32') {
      binaryName = 'license-validator-win.exe';
    } else if (platform === 'linux') {
      binaryName = 'license-validator-linux';
    } else if (platform === 'darwin') {
      binaryName = 'license-validator-macos';
    } else {
      throw new Error(`Unsupported platform: ${platform}`);
    }
    
    return path.join(binDir, binaryName);
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
   * Perform actual validation by calling compiled binary
   * @private
   */
  async _performValidation() {
    try {
      // Check if compiled binary exists
      if (!fs.existsSync(this.validatorBinary)) {
        logger.warn('Compiled license validator not found: ' + this.validatorBinary);
        logger.warn('Fallback: Using non-commercial mode');
        logger.info('To build validator: cd server/lib && npm install && npm run build');
        
        return {
          valid: false,
          error: 'VALIDATOR_NOT_FOUND',
          message: 'License validator binary not found. Using non-commercial mode.',
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

      // Read license certificate
      const licenseCertPem = fs.readFileSync(this.licenseCertPath, 'utf8');

      // Call compiled binary with license certificate via stdin
      const result = await this._callValidator(licenseCertPem);
      
      // Parse dates from ISO strings
      if (result.expires) {
        result.expires = new Date(result.expires);
      }
      if (result.expiredDate) {
        result.expiredDate = new Date(result.expiredDate);
      }

      return result;

    } catch (error) {
      logger.error('License validation error:', error.message);
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
   * Call the compiled validator binary
   * @private
   */
  _callValidator(licenseCertPem) {
    return new Promise((resolve, reject) => {
      const child = spawn(this.validatorBinary, [], {
        stdio: ['pipe', 'pipe', 'pipe']
      });

      let stdout = '';
      let stderr = '';

      child.stdout.on('data', (data) => {
        stdout += data.toString();
      });

      child.stderr.on('data', (data) => {
        stderr += data.toString();
      });

      child.on('error', (error) => {
        reject(new Error(`Failed to execute validator: ${error.message}`));
      });

      child.on('close', (code) => {
        try {
          // Parse JSON output from validator
          const result = JSON.parse(stdout);
          resolve(result);
        } catch (parseError) {
          reject(new Error(`Invalid validator output: ${stdout}\nError: ${stderr}`));
        }
      });

      // Send license certificate to stdin
      child.stdin.write(licenseCertPem);
      child.stdin.end();
    });
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
