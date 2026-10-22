import 'dart:io';

import '../domain/backup_job.dart';

/// Thrown by destinations; the engine uses [kind] to decide whether to retry.
class DestinationException implements Exception {
  final String message;
  final FailureKind kind;

  const DestinationException(this.message, this.kind);

  @override
  String toString() => 'DestinationException(${kind.name}): $message';
}

/// Paths are full object paths, e.g. `<user-id>/2026/IMG_0001.HEIC`.
abstract class BackupDestination {
  Future<bool> exists(String path);
  // Streams the file; stores [sha256] as object metadata. Overwrites [path].
  Future<void> upload(
    String path,
    File file, {
    required String sha256,
    void Function(int sent, int total)? onProgress,
  });
  // The sha256 stored at upload, or null if the object is missing.
  Future<String?> remoteHash(String path);
  // Overwrites [to] if it exists (used for `.part` -> final).
  Future<void> move(String from, String to);
  // No-op if [path] is missing.
  Future<void> delete(String path);
  Future<int> freeSpace(); // simulated quota
  // Stored at `<user-id>/manifest.json`.
  Future<void> writeManifest(String json);
  Future<String?> readManifest();
}
