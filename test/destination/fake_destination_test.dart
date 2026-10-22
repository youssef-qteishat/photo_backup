import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_backup/destination/backup_destination.dart';
import 'package:photo_backup/domain/backup_job.dart';

import 'fake_destination.dart';

Matcher _throwsKind(FailureKind kind) =>
    throwsA(isA<DestinationException>().having((e) => e.kind, 'kind', kind));

void main() {
  late Directory tmp;
  late File small; // 10 bytes
  late File big; // 100 bytes
  late FakeDestination dest;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fake_dest_test');
    small = await File('${tmp.path}/small.bin')
        .writeAsBytes(List.filled(10, 1));
    big = await File('${tmp.path}/big.bin').writeAsBytes(List.filled(100, 2));
    dest = FakeDestination(quotaBytes: 1000);
  });

  tearDown(() => tmp.delete(recursive: true));

  group('basic behaviour', () {
    test('upload stores the hash and reports progress in bytes', () async {
      final progress = <(int, int)>[];
      await dest.upload(
        'u/2026/a.part',
        small,
        sha256: 'abc',
        onProgress: (sent, total) => progress.add((sent, total)),
      );

      expect(await dest.exists('u/2026/a.part'), isTrue);
      expect(await dest.remoteHash('u/2026/a.part'), 'abc');
      expect(progress, [(0, 10), (10, 10)]);
      expect(dest.uploadCount, 1);
    });

    test('missing paths: exists is false and remoteHash is null', () async {
      expect(await dest.exists('nope'), isFalse);
      expect(await dest.remoteHash('nope'), isNull);
    });

    test(
      'move keeps the hash, removes the source, overwrites the target',
      () async {
        await dest.upload('u/2026/a', big, sha256: 'old');
        await dest.upload('u/2026/a.part', small, sha256: 'new');

        await dest.move('u/2026/a.part', 'u/2026/a');

        expect(await dest.exists('u/2026/a.part'), isFalse);
        expect(await dest.remoteHash('u/2026/a'), 'new');
        expect(dest.files['u/2026/a']!.size, 10);
      },
    );

    test('move of a missing source throws', () {
      expect(dest.move('nope', 'x'), _throwsKind(FailureKind.permanent));
    });

    test('delete removes the file; deleting a missing path is fine', () async {
      await dest.upload('u/2026/a.part', small, sha256: 'abc');
      await dest.delete('u/2026/a.part');
      expect(await dest.exists('u/2026/a.part'), isFalse);
      await dest.delete('u/2026/a.part');
    });

    test('manifest is null before the first write, then round-trips', () async {
      expect(await dest.readManifest(), isNull);
      await dest.writeManifest('{"entries":[]}');
      expect(await dest.readManifest(), '{"entries":[]}');
    });

    test(
      'freeSpace shrinks after upload and grows back after delete',
      () async {
        expect(await dest.freeSpace(), 1000);
        await dest.upload('u/2026/b', big, sha256: 'h');
        expect(await dest.freeSpace(), 900);
        await dest.delete('u/2026/b');
        expect(await dest.freeSpace(), 1000);
      },
    );
  });

  group('fault injection', () {
    test('failAfterUploads throws transient after N uploads', () async {
      dest.failAfterUploads = 2;
      await dest.upload('a', small, sha256: 'h');
      await dest.upload('b', small, sha256: 'h');

      await expectLater(
        dest.upload('c', small, sha256: 'h'),
        _throwsKind(FailureKind.transient),
      );
      expect(await dest.exists('c'), isFalse);
      expect(dest.uploadCount, 2);

      dest.failAfterUploads = null; // "restart"
      await dest.upload('c', small, sha256: 'h');
      expect(dest.uploadCount, 3);
    });

    test(
      'maxFileBytes rejects large files permanently, stores nothing',
      () async {
        dest.maxFileBytes = 50;
        await expectLater(
          dest.upload('big', big, sha256: 'h'),
          _throwsKind(FailureKind.permanent),
        );
        expect(await dest.exists('big'), isFalse);
        expect(dest.uploadCount, 0);

        await dest.upload(
          'small',
          small,
          sha256: 'h',
        ); // under the limit is fine
      },
    );

    test('quotaBytes = 0 reports no free space', () async {
      dest.quotaBytes = 0;
      expect(await dest.freeSpace(), 0);
    });

    test('corruptHashPaths makes remoteHash mismatch', () async {
      await dest.upload('a', small, sha256: 'abc');
      dest.corruptHashPaths.add('a');
      expect(await dest.remoteHash('a'), isNot('abc'));
    });
  });
}
