import '../repositories/troubleshoot_repository.dart';

/// Forces complete pre-key regeneration (local and server).
class ForcePreKeyRegeneration {
  final TroubleshootRepository repository;

  const ForcePreKeyRegeneration(this.repository);

  Future<void> call() {
    return repository.forcePreKeyRegeneration();
  }
}
