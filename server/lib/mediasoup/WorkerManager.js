/**
 * WorkerManager - Manages mediasoup Worker Pool
 * 
 * Responsibilities:
 * - Create and manage mediasoup Worker pool
 * - Load balance across workers using Round-Robin
 * - Monitor worker health and restart failed workers
 * - Provide worker lifecycle events
 * 
 * Architecture:
 * - 1 Worker per CPU core (configurable)
 * - Each Worker can handle multiple Routers
 * - Workers are stateless and independent
 */

const mediasoup = require('mediasoup');
const EventEmitter = require('events');
const config = require('../../config/mediasoup.config');

class WorkerManager extends EventEmitter {
  constructor() {
    super();
    this.workers = [];
    this.nextWorkerIdx = 0;
    this.isInitialized = false;
  }

  /**
   * Initialize Worker Pool
   * Creates numWorkers workers based on config
   */
  async initialize() {
    if (this.isInitialized) {
      console.log('[WorkerManager] Already initialized');
      return;
    }

    console.log(`[WorkerManager] Initializing ${config.numWorkers} workers...`);

    try {
      // Create workers in parallel
      const workerPromises = [];
      for (let i = 0; i < config.numWorkers; i++) {
        workerPromises.push(this._createWorker(i));
      }

      this.workers = await Promise.all(workerPromises);
      this.isInitialized = true;

      console.log(`[WorkerManager] ✓ ${this.workers.length} workers initialized`);
      this.emit('initialized', { workerCount: this.workers.length });

      return this.workers;
    } catch (error) {
      console.error('[WorkerManager] ✗ Initialization failed:', error);
      this.emit('error', error);
      throw error;
    }
  }

  /**
   * Create a single mediasoup Worker
   * @param {number} index - Worker index for logging
   * @returns {Promise<mediasoup.Worker>}
   */
  async _createWorker(index) {
    try {
      const worker = await mediasoup.createWorker({
        logLevel: config.worker.logLevel,
        logTags: config.worker.logTags,
        rtcMinPort: config.worker.rtcMinPort,
        rtcMaxPort: config.worker.rtcMaxPort,
      });

      worker.workerId = index;

      // Worker event handlers
      worker.on('died', (error) => {
        console.error(`[WorkerManager] Worker ${index} died:`, error);
        this.emit('workerdied', { workerId: index, error });
        
        // Auto-restart worker
        this._restartWorker(index);
      });

      // Log resource usage periodically (every 30 seconds)
      if (config.worker.logLevel === 'debug') {
        setInterval(async () => {
          const usage = await worker.getResourceUsage();
          console.log(`[WorkerManager] Worker ${index} resource usage:`, usage);
        }, 30000);
      }

      console.log(`[WorkerManager] Worker ${index} created (PID: ${worker.pid})`);
      return worker;

    } catch (error) {
      console.error(`[WorkerManager] Failed to create worker ${index}:`, error);
      throw error;
    }
  }

  /**
   * Restart a failed worker
   * @param {number} index - Worker index to restart
   */
  async _restartWorker(index) {
    console.log(`[WorkerManager] Restarting worker ${index}...`);
    
    try {
      const newWorker = await this._createWorker(index);
      this.workers[index] = newWorker;
      
      console.log(`[WorkerManager] ✓ Worker ${index} restarted`);
      this.emit('workerrestarted', { workerId: index });
    } catch (error) {
      console.error(`[WorkerManager] ✗ Failed to restart worker ${index}:`, error);
      this.emit('error', { workerId: index, error });
    }
  }

  /**
   * Get next available worker using Round-Robin
   * @returns {mediasoup.Worker}
   */
  getWorker() {
    if (!this.isInitialized || this.workers.length === 0) {
      throw new Error('WorkerManager not initialized');
    }

    // Round-robin load balancing
    const worker = this.workers[this.nextWorkerIdx];
    this.nextWorkerIdx = (this.nextWorkerIdx + 1) % this.workers.length;

    return worker;
  }

  /**
   * Get worker by specific index
   * @param {number} index - Worker index
   * @returns {mediasoup.Worker}
   */
  getWorkerByIndex(index) {
    if (index < 0 || index >= this.workers.length) {
      throw new Error(`Worker index ${index} out of range`);
    }
    return this.workers[index];
  }

  /**
   * Get all workers
   * @returns {mediasoup.Worker[]}
   */
  getAllWorkers() {
    return this.workers;
  }

  /**
   * Get worker statistics
   * @returns {Promise<Object>}
   */
  async getStats() {
    const stats = {
      numWorkers: this.workers.length,
      workers: []
    };

    for (let i = 0; i < this.workers.length; i++) {
      const worker = this.workers[i];
      const usage = await worker.getResourceUsage();
      
      stats.workers.push({
        id: i,
        pid: worker.pid,
        resourceUsage: usage
      });
    }

    return stats;
  }

  /**
   * Graceful shutdown of all workers
   */
  async close() {
    console.log('[WorkerManager] Closing all workers...');
    
    const closePromises = this.workers.map((worker, index) => {
      return new Promise((resolve) => {
        worker.close();
        console.log(`[WorkerManager] Worker ${index} closed`);
        resolve();
      });
    });

    await Promise.all(closePromises);
    
    this.workers = [];
    this.isInitialized = false;
    
    console.log('[WorkerManager] ✓ All workers closed');
    this.emit('closed');
  }
}

// Singleton instance
let instance = null;

/**
 * Get WorkerManager singleton instance
 * @returns {WorkerManager}
 */
function getWorkerManager() {
  if (!instance) {
    instance = new WorkerManager();
  }
  return instance;
}

module.exports = {
  WorkerManager,
  getWorkerManager
};
