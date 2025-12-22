import '../repositories/troubleshoot_repository.dart';

/// Deletes identity key and triggers regeneration.
class DeleteIdentityKey {
  final TroubleshootRepository repository;

  const DeleteIdentityKey(this.repository);

  Future<void> call() {
    return repository.deleteIdentityKey();
  }
}
