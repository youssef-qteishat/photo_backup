import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Streams a file through SHA-256 on a background isolate, so hashing a
/// large video never blocks the UI. `async` alone wouldn't help: hashing is
/// CPU work, and the main isolate's event loop can't run anything else while
/// it computes.
class HashWorker {
  static const _progressEvery = 1 << 20; // 1 MiB

  const HashWorker();

  /// Lowercase hex SHA-256 of [file]. [onProgress] gets bytes hashed so far,
  /// roughly every 1 MiB, then a final (total, total). File errors (missing,
  /// permission revoked) are thrown as [FileSystemException].
  Future<String> hash(
    File file, {
    void Function(int done, int total)? onProgress,
  }) async {
    final total = await file.length();
    final port = ReceivePort();
    port.listen((done) => onProgress?.call(done as int, total));
    try {
      final digest = await _run(file.path, port.sendPort);
      // Port messages aren't ordered relative to the result; finish here.
      onProgress?.call(total, total);
      return digest;
    } finally {
      port.close();
    }
  }

  // Separate function so the isolate closure captures only sendable values
  // (a String and a SendPort), not the ReceivePort or callback above.
  static Future<String> _run(String path, SendPort progress) =>
      Isolate.run(() => _hashInIsolate(path, progress));

  static Future<String> _hashInIsolate(String path, SendPort progress) async {
    var done = 0;
    var lastSent = 0;
    final chunks = File(path).openRead().map((chunk) {
      done += chunk.length;
      if (done - lastSent >= _progressEvery) {
        progress.send(done);
        lastSent = done;
      }
      return chunk;
    });
    final digest = await sha256.bind(chunks).first;
    return digest.toString();
  }
}
