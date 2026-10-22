import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../domain/backup_job.dart';
import '../domain/backup_run.dart';
import '../domain/media_item.dart';

/// SQLite-backed job queue and run history. Every [save] is written before
/// the engine takes its next step, so a killed app reopens knowing exactly
/// where it stopped.
class JobQueue {
  final Database _db;

  JobQueue._(this._db);

  /// [db] is shared with [ManifestStore]; this only creates its own tables.
  static Future<JobQueue> open(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS jobs (
        seq          INTEGER PRIMARY KEY AUTOINCREMENT, -- FIFO order
        asset_id     TEXT NOT NULL UNIQUE,
        file_name    TEXT NOT NULL,
        size_bytes   INTEGER NOT NULL,
        modified_at  INTEGER NOT NULL, -- ms since epoch
        media_type   TEXT NOT NULL,
        state        TEXT NOT NULL,
        attempts     INTEGER NOT NULL,
        remote_path  TEXT NOT NULL,
        sha256       TEXT,
        reason       TEXT,
        failure_kind TEXT
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS runs (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        started_at        INTEGER NOT NULL,
        finished_at       INTEGER,
        counts_json       TEXT NOT NULL,
        bytes_transferred INTEGER NOT NULL
      )''');
    return JobQueue._(db);
  }

  /// Crash recovery: jobs caught mid-flight go back to pending.
  Future<void> recoverInFlight() => _db.rawUpdate(
    "UPDATE jobs SET state = 'pending' "
    "WHERE state IN ('hashing', 'uploading', 'verifying')",
  );

  /// Drops last run's finished jobs. Failed ones that are still on the device
  /// come back through the diff, which is what a manual retry is.
  Future<void> clearFinished() =>
      _db.delete('jobs', where: "state IN ('done', 'skipped', 'failed')");

  /// Adds a fresh pending job, replacing any existing row for the asset.
  Future<void> enqueue(MediaItem item, String remotePath) => _db.insert(
    'jobs',
    _toRow(
      BackupJob(
        item: item,
        state: JobState.pending,
        attempts: 0,
        remotePath: remotePath,
      ),
    ),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> save(BackupJob job) => _db.update(
    'jobs',
    _toRow(job),
    where: 'asset_id = ?',
    whereArgs: [job.item.assetId],
  );

  Future<List<BackupJob>> all() async =>
      (await _db.query('jobs', orderBy: 'seq')).map(_fromRow).toList();

  Future<bool> pathTakenByOther(String remotePath, String assetId) async =>
      (await _db.query(
        'jobs',
        columns: ['1'],
        where: 'remote_path = ? AND asset_id != ?',
        whereArgs: [remotePath, assetId],
        limit: 1,
      )).isNotEmpty;

  Future<void> recordRun(BackupRun run) => _db.insert('runs', {
    'started_at': run.startedAt.millisecondsSinceEpoch,
    'finished_at': run.finishedAt?.millisecondsSinceEpoch,
    'counts_json': jsonEncode({
      for (final e in run.counts.entries) e.key.name: e.value,
    }),
    'bytes_transferred': run.bytesTransferred,
  });

  /// Newest first, for the history screen.
  Future<List<BackupRun>> runs() async {
    final rows = await _db.query('runs', orderBy: 'id DESC');
    return [
      for (final r in rows)
        BackupRun(
          startedAt: DateTime.fromMillisecondsSinceEpoch(
            r['started_at'] as int,
          ),
          finishedAt: r['finished_at'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(r['finished_at'] as int),
          counts: {
            for (final e
                in (jsonDecode(r['counts_json'] as String) as Map).entries)
              JobState.values.byName(e.key as String): e.value as int,
          },
          bytesTransferred: r['bytes_transferred'] as int,
        ),
    ];
  }

  static Map<String, Object?> _toRow(BackupJob j) => {
    'asset_id': j.item.assetId,
    'file_name': j.item.fileName,
    'size_bytes': j.item.sizeBytes,
    'modified_at': j.item.modifiedAt.millisecondsSinceEpoch,
    'media_type': j.item.type.name,
    'state': j.state.name,
    'attempts': j.attempts,
    'remote_path': j.remotePath,
    'sha256': j.sha256,
    'reason': j.reason,
    'failure_kind': j.failureKind?.name,
  };

  static BackupJob _fromRow(Map<String, Object?> r) => BackupJob(
    item: MediaItem(
      assetId: r['asset_id'] as String,
      fileName: r['file_name'] as String,
      sizeBytes: r['size_bytes'] as int,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(r['modified_at'] as int),
      type: MediaType.values.byName(r['media_type'] as String),
    ),
    state: JobState.values.byName(r['state'] as String),
    attempts: r['attempts'] as int,
    remotePath: r['remote_path'] as String,
    sha256: r['sha256'] as String?,
    reason: r['reason'] as String?,
    failureKind: r['failure_kind'] == null
        ? null
        : FailureKind.values.byName(r['failure_kind'] as String),
  );
}
