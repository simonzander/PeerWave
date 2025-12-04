import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/audio_settings.dart';

/// Service for processing audio with noise gate, compressor, and volume control
class AudioProcessorService {
  static final AudioProcessorService _instance = AudioProcessorService._internal();
  static AudioProcessorService get instance => _instance;

  AudioProcessorService._internal();

  AudioSettings _settings = AudioSettings.defaults();
  bool _isProcessing = false;

  /// Update audio processing settings
  void updateSettings(AudioSettings settings) {
    _settings = settings;
    debugPrint('[AudioProcessor] Settings updated: gate=${settings.noiseGate.enabled}, comp=${settings.compressor.enabled}');
  }

  /// Process audio samples through noise gate and compressor
  Float32List processAudioFrame(Float32List samples) {
    if (!_isProcessing) {
      _isProcessing = true;
    }

    var processed = samples;

    // Apply noise gate
    if (_settings.noiseGate.enabled) {
      processed = _applyNoiseGate(processed);
    }

    // Apply compressor
    if (_settings.compressor.enabled) {
      processed = _applyCompressor(processed);
    }

    // Apply input volume
    processed = _applyVolume(processed, _settings.inputVolume);

    return processed;
  }

  Float32List _applyNoiseGate(Float32List samples) {
    final threshold = _dbToLinear(_settings.noiseGate.threshold);
    final attackTime = _settings.noiseGate.attack / 1000.0; // Convert to seconds
    final releaseTime = _settings.noiseGate.release / 1000.0;
    
    final result = Float32List(samples.length);
    double envelope = 0.0;
    
    for (int i = 0; i < samples.length; i++) {
      final sample = samples[i].abs();
      
      // Update envelope
      if (sample > envelope) {
        envelope = sample; // Instant attack
      } else {
        // Exponential release
        envelope *= (1.0 - (1.0 / (releaseTime * 44100))); // Assuming 44.1kHz
      }
      
      // Apply gate
      if (envelope < threshold) {
        result[i] = 0.0; // Silence below threshold
      } else {
        result[i] = samples[i];
      }
    }
    
    return result;
  }

  Float32List _applyCompressor(Float32List samples) {
    final threshold = _dbToLinear(_settings.compressor.threshold);
    final ratio = _settings.compressor.ratio;
    final makeupGain = _dbToLinear(_settings.compressor.makeupGain);
    
    final result = Float32List(samples.length);
    
    for (int i = 0; i < samples.length; i++) {
      final sample = samples[i];
      final sampleAbs = sample.abs();
      
      if (sampleAbs > threshold) {
        // Calculate compression
        final excess = sampleAbs - threshold;
        final compressed = threshold + (excess / ratio);
        final gain = compressed / sampleAbs;
        
        // Apply compression and makeup gain
        result[i] = sample * gain * makeupGain;
      } else {
        // Below threshold - only apply makeup gain
        result[i] = sample * makeupGain;
      }
    }
    
    return result;
  }

  Float32List _applyVolume(Float32List samples, double volumeDb) {
    if (volumeDb == 0.0) return samples;
    
    final gain = _dbToLinear(volumeDb);
    final result = Float32List(samples.length);
    
    for (int i = 0; i < samples.length; i++) {
      result[i] = samples[i] * gain;
      // Clamp to prevent clipping
      if (result[i] > 1.0) result[i] = 1.0;
      if (result[i] < -1.0) result[i] = -1.0;
    }
    
    return result;
  }

  /// Convert dB to linear gain
  double _dbToLinear(double db) {
    return pow(10.0, db / 20.0).toDouble();
  }

  /// Calculate RMS level of audio samples (for visualization)
  double calculateRMS(Float32List samples) {
    if (samples.isEmpty) return 0.0;
    
    double sum = 0.0;
    for (final sample in samples) {
      sum += sample * sample;
    }
    
    return sqrt(sum / samples.length);
  }

  /// Convert RMS to dB
  double rmsToDb(double rms) {
    if (rms <= 0.0) return -96.0; // Silence
    return 20.0 * (log(rms) / ln10);
  }

  void dispose() {
    _isProcessing = false;
  }
}

// Math helpers
double pow(double x, double exponent) {
  if (exponent == 0) return 1.0;
  if (exponent == 1) return x;
  
  double result = 1.0;
  for (int i = 0; i < exponent.abs().round(); i++) {
    result *= x;
  }
  return exponent < 0 ? 1.0 / result : result;
}

double sqrt(double x) {
  if (x < 0) return 0.0;
  if (x == 0) return 0.0;
  
  double guess = x / 2;
  for (int i = 0; i < 10; i++) {
    guess = (guess + x / guess) / 2;
  }
  return guess;
}

double log(double x) {
  if (x <= 0) return double.negativeInfinity;
  return (x - 1) / x; // Simplified approximation
}

const double ln10 = 2.302585092994046;
