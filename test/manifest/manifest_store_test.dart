import 'package:flutter_test/flutter_test.dart';
import 'package:photo_backup/domain/manifest_entry.dart';
import 'package:photo_backup/domain/media_item.dart';
import 'package:photo_backup/manifest/manifest_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../destination/fake_destination.dart';

MediaItem _item(String id, {int size = 100, int mtimeMs = 1000}) => MediaItem(
  assetId: id,
  fileName: '$id.HEIC',
  sizeBytes: size,
  modifiedAt: DateTime.fromMillisecondsSinceEpoch(mtimeMs),
  type: MediaType.photo,
);

ManifestEntry _entry(MediaItem item, {String? sha256, String? remotePath}) =>
    ManifestEntry(
      assetId: item.assetId,
      sizeBytes: item.sizeBytes,
      modifiedAt: item.modifiedAt,
      sha256: sha256 ?? 'hash-${item.assetId}',
      remotePath: remotePath ?? 'user-1/2026/${item.fileName}',
      backedUpAt: DateTime.fromMillisecondsSinceEpoch(5000),
    );

// singleInstance: false gives each call its own empty DB; by default every
// open of ':memory:' returns the same shared instance.
Future<ManifestStore> _openStore() async => ManifestStore.open(
  await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  ),
);

void main() {
  sqfliteFfiInit();

  late ManifestStore store;

  setUp(() async => store = await _openStore());

  group('needsBackup', () {
    final items = [_item('a'), _item('b'), _item('c')];

    test('first run queues everything', () async {
      expect(await store.needsBackup(items), hasLength(3));
    });

    test('second run over unchanged files queues zero', () async {
      for (final i in items) {
        await store.record(_entry(i));
      }
      expect(await store.needsBackup(items), isEmpty);
    });

    test('changing one file size queues exactly one', () async {
      for (final i in items) {
        await store.record(_entry(i));
      }
      final changed = [items[0], _item('b', size: 999), items[2]];
      final queued = await store.needsBackup(changed);
      expect(queued.map((i) => i.assetId), ['b']);
    });

    test('changing one modified time queues exactly one', () async {
      for (final i in items) {
        await store.record(_entry(i));
      }
      final changed = [items[0], items[1], _item('c', mtimeMs: 2000)];
      final queued = await store.needsBackup(changed);
      expect(queued.map((i) => i.assetId), ['c']);
    });

    test('assets deleted from the device keep their rows', () async {
      for (final i in items) {
        await store.record(_entry(i));
      }
      expect(await store.needsBackup([items[0]]), isEmpty);
      expect(await store.get('b'), isNotNull);
      expect(await store.get('c'), isNotNull);
    });
  });

  group('rename dedup', () {
    test('renamed but identical file causes no upload', () async {
      final dest = FakeDestination();
      final original = _item('a');
      await store.record(_entry(original, sha256: 'same'));

      // Same content shows up under a new asset ID: diff queues it...
      final renamed = _item('a-renamed');
      expect(await store.needsBackup([original, renamed]), [renamed]);

      // ...after hashing, the engine finds the hash and records an alias.
      final existing = await store.findByHash('same');
      expect(existing, isNotNull);
      await store.record(
        _entry(renamed, sha256: 'same', remotePath: existing!.remotePath),
      );

      expect(await store.needsBackup([original, renamed]), isEmpty);
      expect((await store.get('a-renamed'))!.remotePath, existing.remotePath);
      expect(dest.uploadCount, 0);
    });

    test('findByHash returns null for unknown content', () async {
      expect(await store.findByHash('nope'), isNull);
    });
  });

  test('record replaces the row for the same asset (changed file)', () async {
    await store.record(_entry(_item('a'), sha256: 'v1'));
    await store.record(_entry(_item('a', size: 200), sha256: 'v2'));

    final row = await store.get('a');
    expect(row!.sha256, 'v2');
    expect(row.sizeBytes, 200);
    expect(await store.findByHash('v1'), isNull);
  });

  group('destination copy', () {
    test('reinstall recovers history from the destination', () async {
      final dest = FakeDestination();
      final items = [_item('a'), _item('b')];
      for (final i in items) {
        await store.record(_entry(i));
      }
      await store.pushTo(dest);

      final reinstalled = await _openStore();
      expect(await reinstalled.needsBackup(items), hasLength(2));
      await reinstalled.pullFrom(dest);
      expect(await reinstalled.needsBackup(items), isEmpty);
      expect(
        (await reinstalled.get('a'))!.backedUpAt.millisecondsSinceEpoch,
        5000,
      );
    });

    test('merge keeps local rows on conflict', () async {
      final dest = FakeDestination();
      await store.record(_entry(_item('x'), sha256: 'remote'));
      await store.record(_entry(_item('y')));
      await store.pushTo(dest);

      final local = await _openStore();
      await local.record(_entry(_item('x'), sha256: 'local'));
      await local.pullFrom(dest);

      expect((await local.get('x'))!.sha256, 'local');
      expect(await local.get('y'), isNotNull);
    });

    test('pull with no remote manifest is a no-op', () async {
      await store.record(_entry(_item('a')));
      await store.pullFrom(FakeDestination());
      expect(await store.get('a'), isNotNull);
    });

    test('malformed manifest throws and writes nothing', () async {
      await store.record(_entry(_item('a')));
      final before = await store.toJson();

      for (final bad in [
        'not json',
        '{"entries": "oops"}',
        '{"entries": [{"asset_id": 1}]}',
      ]) {
        await expectLater(store.mergeJson(bad), throwsFormatException);
      }
      expect(await store.toJson(), before);
    });
  });
}
