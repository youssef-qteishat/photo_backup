import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../destination/backup_destination.dart';
import '../domain/backup_job.dart';
import '../domain/backup_progress.dart';
import '../domain/backup_run.dart';
import '../domain/manifest_entry.dart';
import '../domain/media_item.dart';
import '../hashing/hash_worker.dart';
import '../manifest/manifest_store.dart';
import 'job_queue.dart';

/// Returns the local file for an asset, or null if it no longer exists.
typedef FileResolver = Future<File?> Function(MediaItem item);
typedef Sleep = Future<void> Function(Duration duration);

/// Runs the backup pipeline one job at a time:
/// hash → skip if already backed up → upload `.part` → verify → move → done.
class BackupEngine {
  static const maxRetries = 3; // backoff 1s, 2s, 4s; 4 attempts in total

  final JobQueue _queue;
  final ManifestStore _manifest;
  final BackupDestination _destination;
  final FileResolver _resolveFile;
  final String _userId;
  final HashWorker _hasher;
  final int _maxFileBytes;
  final Sleep _sleep;
  final DateTime Function() _now;

  final _progress = StreamController<BackupProgress>.broadcast();
  final _jobs = <String, BackupJob>{}; // this run's jobs, in queue order
  final _hashed = <String, int>{};
  final _uploaded = <String, int>{};
  final _shown = <String, int>{}; // per-job progress, kept monotonic
  String? _currentFile;
  int _bytesTransferred = 0;
  bool _pauseRequested = false;
  bool _cancelRequested = false;

  BackupEngine({
    required this._queue,
    required this._manifest,
    required this._destination,
    required this._resolveFile,
    required this._userId,
    this._hasher = const HashWorker(),
    this._maxFileBytes = 4 << 30, // matches the bucket's file_size_limit
    this._sleep = Future<void>.delayed,
    this._now = DateTime.now,
  });

  /// Bytes count both passes: bytesTotal = 2 × Σ sizes (hash + upload).
  Stream<BackupProgress> get progress => _progress.stream;

  /// Finish the current job, then stop. Call [run] again to resume.
  void pause() => _pauseRequested = true;

  /// Stop at the next step boundary; the in-flight job goes back to pending
  /// and its `.part` is deleted.
  // ponytail: a cancel during a long upload waits for that upload to finish;
  // throw from the upload's onProgress if it needs to abort mid-stream.
  void cancel() => _cancelRequested = true;

  /// Backs up whatever in [discovered] isn't in the manifest, plus any jobs
  /// left pending by an earlier (paused, cancelled or killed) run.
  Future<BackupRun> run(List<MediaItem> discovered) async {
    final startedAt = _now();
    _pauseRequested = false;
    _cancelRequested = false;
    _bytesTransferred = 0;
    _hashed.clear();
    _uploaded.clear();
    _shown.clear();

    await _queue.recoverInFlight();
    await _queue.clearFinished();
    await _ignoreDestinationErrors(() => _manifest.pullFrom(_destination));
    for (final item in await _manifest.needsBackup(discovered)) {
      await _queue.enqueue(item, await _pathFor(item));
    }
    _jobs
      ..clear()
      ..addEntries(
        (await _queue.all()).map((j) => MapEntry(j.item.assetId, j)),
      );
    _emit();

    for (final id in _jobs.keys.toList()) {
      if (_pauseRequested || _cancelRequested) break;
      if (_jobs[id]!.state == JobState.pending) await _process(id);
    }

    _currentFile = null;
    _emit();
    await _ignoreDestinationErrors(() => _manifest.pushTo(_destination));
    final run = BackupRun(
      startedAt: startedAt,
      finishedAt: _now(),
      counts: _counts(),
      bytesTransferred: _bytesTransferred,
    );
    await _queue.recordRun(run);
    return run;
  }

  /// Runs attempts until the job settles; transient failures retry with
  /// exponential backoff, permanent ones never do.
  Future<void> _process(String id) async {
    while (true) {
      await _attempt(id);
      final job = _jobs[id]!;
      final retry =
          job.state == JobState.failed &&
          job.failureKind == FailureKind.transient &&
          job.attempts <= maxRetries &&
          !_pauseRequested &&
          !_cancelRequested;
      if (!retry) return;
      await _sleep(Duration(seconds: 1 << (job.attempts - 1)));
      await _set(id, job.transitionTo(JobState.pending));
    }
  }

  Future<void> _attempt(String id) async {
    var job = _jobs[id]!;
    final item = job.item;
    final part = '${job.remotePath}.part';
    _currentFile = item.fileName;
    try {
      final file = await _resolveFile(item);
      if (file == null) {
        await _set(
          id,
          job.transitionTo(
            JobState.skipped,
            reason: 'asset no longer available',
          ),
        );
        return;
      }

      job = await _set(id, job.transitionTo(JobState.hashing));
      if (item.sizeBytes > _maxFileBytes) {
        await _fail(
          id,
          FailureKind.permanent,
          '${item.sizeBytes} bytes exceeds the $_maxFileBytes byte limit',
        );
        return;
      }
      final hash = await _hasher.hash(
        file,
        onProgress: (done, _) => _onBytes(_hashed, id, done),
      );

      // Already backed up: a crash after move but before recording lands
      // here, as does a renamed or re-dated copy of known content.
      if (await _destination.remoteHash(job.remotePath) == hash) {
        await _manifest.record(_entry(item, hash, job.remotePath));
        await _set(
          id,
          job.transitionTo(
            JobState.skipped,
            reason: 'already on destination',
            sha256: hash,
          ),
        );
        return;
      }
      final existing = await _manifest.findByHash(hash);
      if (existing != null) {
        await _manifest.record(_entry(item, hash, existing.remotePath));
        await _set(
          id,
          job.transitionTo(
            JobState.skipped,
            reason: 'same content already backed up at ${existing.remotePath}',
            sha256: hash,
          ),
        );
        return;
      }

      if (await _destination.freeSpace() < item.sizeBytes) {
        await _fail(id, FailureKind.permanent, 'destination full');
        return;
      }

      if (await _cancelIfRequested(id, part)) return;
      job = await _set(id, job.transitionTo(JobState.uploading, sha256: hash));
      await _destination.upload(
        part,
        file,
        sha256: hash,
        onProgress: (sent, _) => _onBytes(_uploaded, id, sent),
      );
      _bytesTransferred += item.sizeBytes;

      if (await _cancelIfRequested(id, part)) return;
      job = await _set(id, job.transitionTo(JobState.verifying));
      if (await _destination.remoteHash(part) != hash) {
        await _fail(id, FailureKind.transient, 'hash mismatch after upload');
        return;
      }
      await _destination.move(part, job.remotePath);
      await _manifest.record(_entry(item, hash, job.remotePath));
      await _set(id, job.transitionTo(JobState.done));
    } on DestinationException catch (e) {
      await _fail(id, e.kind, e.message);
    } on FileSystemException catch (e) {
      // Deleted or permission revoked mid-run (SPEC: skip and record why).
      await _set(
        id,
        _jobs[id]!.transitionTo(
          JobState.skipped,
          reason: 'asset unavailable: ${e.message}',
        ),
      );
    }
    // Anything else is a crash: it propagates, and the job stays in its
    // in-flight state on disk for recoverInFlight() on the next run.
  }

  Future<bool> _cancelIfRequested(String id, String part) async {
    if (!_cancelRequested) return false;
    await _destination.delete(part);
    await _set(id, _jobs[id]!.transitionTo(JobState.pending));
    return true;
  }

  Future<void> _fail(String id, FailureKind kind, String reason) => _set(
    id,
    _jobs[id]!.transitionTo(JobState.failed, reason: reason, kind: kind),
  );

  Future<BackupJob> _set(String id, BackupJob job) async {
    _jobs[id] = job;
    await _queue.save(job);
    _emit();
    return job;
  }

  /// `<uid>/<yyyy>/<fileName>`, or `<stem>_<8hex><ext>` if a different asset
  /// already uses that path (iPhone names repeat). Deterministic per asset.
  Future<String> _pathFor(MediaItem item) async {
    final dir = '$_userId/${item.modifiedAt.year}';
    final plain = '$dir/${item.fileName}';
    final taken =
        await _manifest.pathTakenByOther(plain, item.assetId) ||
        await _queue.pathTakenByOther(plain, item.assetId);
    if (!taken) return plain;
    final tag = sha256
        .convert(utf8.encode(item.assetId))
        .toString()
        .substring(0, 8);
    final dot = item.fileName.lastIndexOf('.');
    final name = dot <= 0
        ? '${item.fileName}_$tag'
        : '${item.fileName.substring(0, dot)}_$tag'
              '${item.fileName.substring(dot)}';
    return '$dir/$name';
  }

  ManifestEntry _entry(MediaItem item, String hash, String remotePath) =>
      ManifestEntry(
        assetId: item.assetId,
        sizeBytes: item.sizeBytes,
        modifiedAt: item.modifiedAt,
        sha256: hash,
        remotePath: remotePath,
        backedUpAt: _now(),
      );

  void _onBytes(Map<String, int> phase, String id, int bytes) {
    phase[id] = max(phase[id] ?? 0, bytes);
    _emit();
  }

  // ponytail: O(jobs) per emit, about once per MiB; keep running totals if
  // runs grow past tens of thousands of jobs.
  void _emit() {
    if (!_progress.hasListener) return;
    var total = 0;
    var done = 0;
    for (final MapEntry(key: id, value: job) in _jobs.entries) {
      final size = job.item.sizeBytes;
      total += 2 * size;
      final int current = switch (job.state) {
        JobState.done || JobState.skipped || JobState.failed => 2 * size,
        _ => min(_hashed[id] ?? 0, size) + min(_uploaded[id] ?? 0, size),
      };
      // Retries restart a job's bytes; never let the bar move backwards.
      done += _shown[id] = max(_shown[id] ?? 0, current);
    }
    _progress.add(
      BackupProgress(
        bytesDone: done,
        bytesTotal: total,
        currentFile: _currentFile,
        counts: _counts(),
      ),
    );
  }

  Map<JobState, int> _counts() {
    final counts = <JobState, int>{};
    for (final job in _jobs.values) {
      counts[job.state] = (counts[job.state] ?? 0) + 1;
    }
    return counts;
  }

  /// Manifest sync is best-effort: offline must not fail the run.
  // ponytail: errors are swallowed silently; surface them in BackupRun if the
  // UI needs to show "manifest not synced".
  static Future<void> _ignoreDestinationErrors(
    Future<void> Function() body,
  ) async {
    try {
      await body();
    } on DestinationException {
      // Next run retries the sync.
    }
  }
}
