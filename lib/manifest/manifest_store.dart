import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../destination/backup_destination.dart';
import '../domain/manifest_entry.dart';
import '../domain/media_item.dart';

/// Local record of what's already backed up (SQLite), mirrored to the
/// destination as `manifest.json`. Rows are never deleted: backups are
/// additive, so assets deleted from the device stay recorded.
class ManifestStore {
  final Database _db;

  ManifestStore._(this._db);

  /// [db] is shared with the job queue; this only creates its own table.
  static Future<ManifestStore> open(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS manifest (
        asset_id     TEXT PRIMARY KEY,
        size_bytes   INTEGER NOT NULL,
        modified_at  INTEGER NOT NULL, -- ms since epoch
        sha256       TEXT NOT NULL,
        remote_path  TEXT NOT NULL,
        backed_up_at INTEGER NOT NULL  -- ms since epoch
      )''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS manifest_sha256 ON manifest(sha256)',
    );
    return ManifestStore._(db);
  }

  /// Items that are new (assetId not recorded) or changed (size or
  /// modifiedAt differ). Unchanged items are not returned, so never queued.
  // ponytail: loads every row's key fields into memory; query in chunks with
  // `WHERE asset_id IN (...)` if libraries grow past ~100k items.
  Future<List<MediaItem>> needsBackup(List<MediaItem> items) async {
    final rows = await _db.query(
      'manifest',
      columns: ['asset_id', 'size_bytes', 'modified_at'],
    );
    final known = {
      for (final r in rows)
        r['asset_id'] as String: (
          size: r['size_bytes'] as int,
          modifiedAt: r['modified_at'] as int,
        ),
    };
    return items.where((item) {
      final k = known[item.assetId];
      return k == null ||
          k.size != item.sizeBytes ||
          k.modifiedAt != item.modifiedAt.millisecondsSinceEpoch;
    }).toList();
  }

  /// Rename dedup: an existing entry with the same content, or null. On a hit
  /// the engine records an alias row (new assetId, same remotePath) and skips
  /// the upload.
  Future<ManifestEntry?> findByHash(String sha256) async {
    final rows = await _db.query(
      'manifest',
      where: 'sha256 = ?',
      whereArgs: [sha256],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// True if a different asset already backs up to [remotePath] (name clash).
  Future<bool> pathTakenByOther(String remotePath, String assetId) async =>
      (await _db.query(
        'manifest',
        columns: ['1'],
        where: 'remote_path = ? AND asset_id != ?',
        whereArgs: [remotePath, assetId],
        limit: 1,
      )).isNotEmpty;

  Future<ManifestEntry?> get(String assetId) async {
    final rows = await _db.query(
      'manifest',
      where: 'asset_id = ?',
      whereArgs: [assetId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Inserts, or replaces the row for the same assetId (changed file).
  Future<void> record(ManifestEntry entry) => _db.insert(
    'manifest',
    _toRow(entry),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<String> toJson() async {
    final rows = await _db.query('manifest', orderBy: 'asset_id');
    return jsonEncode({'version': 1, 'entries': rows});
  }

  /// Inserts rows missing locally; local rows win on conflict. Malformed
  /// JSON throws [FormatException] before anything is written.
  Future<void> mergeJson(String json) async {
    final List<ManifestEntry> entries;
    try {
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      entries = (decoded['entries'] as List)
          .map((r) => _fromRow(r as Map<String, Object?>))
          .toList();
    } on TypeError catch (e) {
      throw FormatException('Malformed manifest: $e');
    }
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final e in entries) {
        batch.insert(
          'manifest',
          _toRow(e),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> pushTo(BackupDestination dest) async =>
      dest.writeManifest(await toJson());

  /// No-op when the destination has no manifest yet.
  Future<void> pullFrom(BackupDestination dest) async {
    final json = await dest.readManifest();
    if (json != null) await mergeJson(json);
  }

  static Map<String, Object?> _toRow(ManifestEntry e) => {
    'asset_id': e.assetId,
    'size_bytes': e.sizeBytes,
    'modified_at': e.modifiedAt.millisecondsSinceEpoch,
    'sha256': e.sha256,
    'remote_path': e.remotePath,
    'backed_up_at': e.backedUpAt.millisecondsSinceEpoch,
  };

  static ManifestEntry _fromRow(Map<String, Object?> r) => ManifestEntry(
    assetId: r['asset_id'] as String,
    sizeBytes: r['size_bytes'] as int,
    modifiedAt: DateTime.fromMillisecondsSinceEpoch(r['modified_at'] as int),
    sha256: r['sha256'] as String,
    remotePath: r['remote_path'] as String,
    backedUpAt: DateTime.fromMillisecondsSinceEpoch(r['backed_up_at'] as int),
  );
}
