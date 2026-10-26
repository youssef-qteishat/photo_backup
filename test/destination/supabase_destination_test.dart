// Opt-in: needs local Supabase running. Skipped unless env defines are passed:
//   flutter test --tags integration --dart-define-from-file=env/simulator.env
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_backup/destination/supabase_destination.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const _email = String.fromEnvironment('TEST_EMAIL');
const _password = String.fromEnvironment('TEST_PASSWORD');

// Skipping the group (not each test) also skips setUpAll/tearDownAll.
void main() => group(
  'SupabaseDestination',
  skip: _url.isEmpty ? 'pass --dart-define-from-file=env/simulator.env' : false,
  () {
    // Nullable so tearDownAll copes with a setUpAll that failed partway.
    SupabaseClient? client;
    Directory? tmp;
    late SupabaseDestination dest;
    late String prefix;

    setUpAll(() async {
      final missing = {
        'SUPABASE_ANON_KEY': _anonKey,
        'TEST_EMAIL': _email,
        'TEST_PASSWORD': _password,
      }.entries.where((e) => e.value.isEmpty).map((e) => e.key);
      if (missing.isNotEmpty) {
        fail('Missing in env file: ${missing.join(', ')}');
      }
      tmp = await Directory.systemTemp.createTemp('supabase_dest_test');
      final c = client = SupabaseClient(_url, _anonKey);
      await c.auth.signInWithPassword(email: _email, password: _password);
      dest = SupabaseDestination(c);
      prefix =
          '${c.auth.currentUser!.id}/integration-test-'
          '${DateTime.now().millisecondsSinceEpoch}';
    });

    tearDownAll(() async {
      await tmp?.delete(recursive: true);
      await client?.dispose();
    });

    test('upload .part, verify hash, move to final path', () async {
      final file = await File('${tmp!.path}/a.bin')
          .writeAsBytes(List.filled(1024, 7));
      final part = '$prefix/a.bin.part';
      final finalPath = '$prefix/a.bin';
      var lastSent = 0;

      try {
        final before = await dest.freeSpace();
        await dest.upload(
          part,
          file,
          sha256: 'test-hash',
          onProgress: (sent, _) => lastSent = sent,
        );
        expect(lastSent, 1024);
        expect(await dest.remoteHash(part), 'test-hash');

        await dest.move(part, finalPath);
        expect(await dest.exists(part), isFalse);
        expect(await dest.exists(finalPath), isTrue);
        expect(await dest.remoteHash(finalPath), 'test-hash');
        expect(await dest.freeSpace(), before - 1024);
      } finally {
        await dest.delete(part);
        await dest.delete(finalPath);
      }
    });

    test('manifest round-trips (restores the real one afterwards)', () async {
      final original = await dest.readManifest();
      try {
        await dest.writeManifest('{"test":true}');
        expect(await dest.readManifest(), '{"test":true}');
      } finally {
        // Never leave the dummy behind: it would break the app's next run.
        if (original != null) {
          await dest.writeManifest(original);
        } else {
          await dest.delete('${dest.userId}/manifest.json');
        }
      }
    });
  },
);
