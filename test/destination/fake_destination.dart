import 'dart:io';

import 'package:photo_backup/destination/backup_destination.dart';
import 'package:photo_backup/domain/backup_job.dart';

/// In-memory [BackupDestination] for tests, with fault-injection knobs.
/// Only file sizes and hashes are stored, never file contents.
class FakeDestination implements BackupDestination {
  final files = <String, ({int size, String sha256})>{};
  String? manifest;

  /// Successful uploads so far (for "no duplicates" / "uploads nothing").
  int uploadCount = 0;

  /// Once [uploadCount] reaches this, every upload throws a transient error
  /// (simulates a crash or network loss mid-run). Set to null to recover.
  int? failAfterUploads;

  /// Files larger than this fail permanently (bucket `file_size_limit`).
  int? maxFileBytes;

  /// `freeSpace = quotaBytes - used`. Set to 0 to simulate a full destination.
  int quotaBytes;

  /// [remoteHash] returns a wrong hash for these paths (verification failure).
  final corruptHashPaths = <String>{};

  FakeDestination({
    this.quotaBytes = 1 << 40,
    this.failAfterUploads,
    this.maxFileBytes,
  });

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> upload(
    String path,
    File file, {
    required String sha256,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (failAfterUploads != null && uploadCount >= failAfterUploads!) {
      throw DestinationException(
        'Injected failure after $failAfterUploads uploads',
        FailureKind.transient,
      );
    }
    final size = await file.length();
    if (maxFileBytes != null && size > maxFileBytes!) {
      throw DestinationException(
        '$size bytes exceeds the $maxFileBytes byte limit',
        FailureKind.permanent,
      );
    }
    onProgress?.call(0, size);
    files[path] = (size: size, sha256: sha256);
    uploadCount++;
    onProgress?.call(size, size);
  }

  @override
  Future<String?> remoteHash(String path) async {
    final hash = files[path]?.sha256;
    if (hash == null) return null;
    return corruptHashPaths.contains(path) ? 'corrupt-$hash' : hash;
  }

  @override
  Future<void> move(String from, String to) async {
    final entry = files.remove(from);
    if (entry == null) {
      throw DestinationException('$from not found', FailureKind.permanent);
    }
    files[to] = entry;
  }

  @override
  Future<void> delete(String path) async => files.remove(path);

  @override
  Future<int> freeSpace() async =>
      quotaBytes - files.values.fold(0, (sum, f) => sum + f.size);

  @override
  Future<void> writeManifest(String json) async => manifest = json;

  @override
  Future<String?> readManifest() async => manifest;
}
