import '../entities/key_metrics.dart';
import '../repositories/troubleshoot_repository.dart';

/// Retrieves current Signal Protocol key management metrics.
class GetKeyMetrics {
  final TroubleshootRepository repository;

  const GetKeyMetrics(this.repository);

  Future<KeyMetrics> call() {
    return repository.getKeyMetrics();
  }
}
