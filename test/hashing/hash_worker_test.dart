import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_backup/hashing/hash_worker.dart';

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('hash_test'));
  tearDown(() => tmp.delete(recursive: true));

  test('50 MiB file matches a known SHA-256, progress by bytes', () async {
    // 50 x 1 MiB of bytes i % 256. Expected hash computed independently with
    // Python's hashlib.
    final chunk = Uint8List.fromList(List.generate(1 << 20, (i) => i % 256));
    final file = File('${tmp.path}/big.bin');
    final sink = file.openWrite();
    for (var i = 0; i < 50; i++) {
      sink.add(chunk);
    }
    await sink.close();

    final progress = <int>[];
    final hash = await const HashWorker().hash(
      file,
      onProgress: (done, total) {
        expect(total, 50 << 20);
        progress.add(done);
      },
    );

    expect(
      hash,
      '624bbe3f61588f97cfaad1af50360bb8c5fc94774d3c15dbf471dcd42b9bea8e',
    );
    expect(progress.last, 50 << 20);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
  });

  test('known vector: "abc"', () async {
    final file = await File('${tmp.path}/abc.txt').writeAsString('abc');
    expect(
      await const HashWorker().hash(file),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('missing file throws FileSystemException', () {
    expect(
      const HashWorker().hash(File('${tmp.path}/nope')),
      throwsA(isA<FileSystemException>()),
    );
  });
}
