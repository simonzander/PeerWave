/// Static class to track network diagnostics metrics
class NetworkMetrics {
  // API Call Counters
  static int _totalApiCalls = 0;
  static int _successfulApiCalls = 0;
  static int _failedApiCalls = 0;

  // Socket Counters
  static int _socketEmitCount = 0;
  static int _socketReceiveCount = 0;

  // Getters
  static int get totalApiCalls => _totalApiCalls;
  static int get successfulApiCalls => _successfulApiCalls;
  static int get failedApiCalls => _failedApiCalls;
  static int get socketEmitCount => _socketEmitCount;
  static int get socketReceiveCount => _socketReceiveCount;

  // Recording methods
  static void recordApiCall({required bool success}) {
    _totalApiCalls++;
    if (success) {
      _successfulApiCalls++;
    } else {
      _failedApiCalls++;
    }
  }

  static void recordSocketEmit(int count) {
    _socketEmitCount += count;
  }

  static void recordSocketReceive(int count) {
    _socketReceiveCount += count;
  }

  // Reset method
  static void reset() {
    _totalApiCalls = 0;
    _successfulApiCalls = 0;
    _failedApiCalls = 0;
    _socketEmitCount = 0;
    _socketReceiveCount = 0;
  }

  // Export to JSON
  static Map<String, dynamic> toJson() {
    return {
      'totalApiCalls': _totalApiCalls,
      'successfulApiCalls': _successfulApiCalls,
      'failedApiCalls': _failedApiCalls,
      'socketEmitCount': _socketEmitCount,
      'socketReceiveCount': _socketReceiveCount,
    };
  }
}
