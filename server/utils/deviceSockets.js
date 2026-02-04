/**
 * Device Socket Management
 * Centralized management of device-to-socket mappings for real-time communication
 */

// Map: userId -> deviceId -> [socket1, socket2, ...]
// Multiple sockets per device (e.g., multiple browser tabs)
const deviceSockets = new Map();

/**
 * Get the deviceSockets Map (for direct access if needed)
 * @returns {Map} The deviceSockets Map
 */
function getDeviceSockets() {
  return deviceSockets;
}

module.exports = {
  deviceSockets,
  getDeviceSockets
};
