import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/backup_job.dart';
import 'backup_destination.dart';

class SupabaseDestination implements BackupDestination {
  final SupabaseClient _client;
  final String bucket;
  final int quotaBytes;

  static const _pageSize = 1000;

  SupabaseDestination(
    this._client, {
    this.bucket = 'backups',
    this.quotaBytes = 10 * 1024 * 1024 * 1024,
  });

  StorageFileApi get _bucket => _client.storage.from(bucket);

  String get _userId =>
      _client.auth.currentUser?.id ??
      (throw const DestinationException(
        'Not signed in',
        FailureKind.permanent,
      ));

  String get _manifestPath => '$_userId/manifest.json';

  @override
  Future<bool> exists(String path) => _guard(() => _bucket.exists(path));

  // storage_client's upload() reads the whole file into memory
  // (readAsBytesSync), so we send the same multipart request ourselves,
  // streamed from disk.
  @override
  Future<void> upload(
    String path,
    File file, {
    required String sha256,
    void Function(int sent, int total)? onProgress,
  }) => _guard(() async {
    final total = await file.length();
    var sent = 0;
    onProgress?.call(0, total);
    final body = file.openRead().map((chunk) {
      sent += chunk.length;
      onProgress?.call(sent, total);
      return chunk;
    });

    // storage.headers holds `Bearer <anon key>`; the client swaps in the
    // user's token per request inside its own http client, which we bypass.
    final token = _client.auth.currentSession?.accessToken;
    if (token == null) {
      throw const DestinationException('Not signed in', FailureKind.permanent);
    }

    final encodedPath = Uri(pathSegments: path.split('/')).path;
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('${_client.storage.url}/object/$bucket/$encodedPath'),
          )
          ..headers.addAll(_client.storage.headers)
          ..headers['Authorization'] = 'Bearer $token'
          ..headers['x-upsert'] = 'true'
          ..fields['cacheControl'] = '3600'
          ..fields['metadata'] = jsonEncode({'sha256': sha256})
          ..files.add(
            http.MultipartFile('', body, total, filename: path.split('/').last),
          );

    // ponytail: no timeout, so a stalled socket waits for the OS to drop it;
    // add an idle timeout on the stream if Wi-Fi drops hang in practice.
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode >= 300) {
      throw StorageException(
        response.body,
        statusCode: '${response.statusCode}',
      );
    }
  });

  @override
  Future<String?> remoteHash(String path) => _guard(() async {
    try {
      final info = await _bucket.info(path);
      return info.metadata?['sha256'] as String?;
    } on StorageException catch (e) {
      if (_isNotFound(e)) return null;
      rethrow;
    }
  });

  // ponytail: delete-then-move isn't atomic, so the old version is briefly
  // missing when a changed file is re-backed-up.
  @override
  Future<void> move(String from, String to) => _guard(() async {
    if (await _bucket.exists(to)) await _bucket.remove([to]);
    await _bucket.move(from, to);
  });

  @override
  Future<void> delete(String path) => _guard(() => _bucket.remove([path]));

  @override
  Future<int> freeSpace() =>
      _guard(() async => quotaBytes - await _sizeUnder(_userId));

  Future<int> _sizeUnder(String prefix) async {
    var total = 0;
    for (var offset = 0; ; offset += _pageSize) {
      final items = await _bucket.list(
        path: prefix,
        searchOptions: SearchOptions(limit: _pageSize, offset: offset),
      );
      for (final item in items) {
        // Folders come back with a null id.
        total += item.id == null
            ? await _sizeUnder('$prefix/${item.name}')
            : (item.metadata?['size'] as int? ?? 0);
      }
      if (items.length < _pageSize) return total;
    }
  }

  @override
  Future<void> writeManifest(String json) => _guard(
    () => _bucket.uploadBinary(
      _manifestPath,
      utf8.encode(json),
      fileOptions: const FileOptions(
        upsert: true,
        contentType: 'application/json',
      ),
    ),
  );

  @override
  Future<String?> readManifest() => _guard(() async {
    try {
      return utf8.decode(await _bucket.download(_manifestPath));
    } on StorageException catch (e) {
      if (_isNotFound(e)) return null;
      rethrow;
    }
  });

  // Same rule storage_client's own exists() uses.
  static bool _isNotFound(StorageException e) =>
      e.statusCode == '400' || e.statusCode == '404';

  /// Maps every error to a [DestinationException]. Network errors and 5xx are
  /// transient (worth retrying); anything else (4xx: too large, RLS, bad
  /// request) is permanent.
  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on DestinationException {
      rethrow;
    } on StorageException catch (e) {
      // Non-HTTP failures arrive with the error's type name as statusCode.
      final code = int.tryParse(e.statusCode ?? '');
      final transient = code == null || code >= 500;
      throw DestinationException(
        e.message,
        transient ? FailureKind.transient : FailureKind.permanent,
      );
    } on SocketException catch (e) {
      throw DestinationException(e.message, FailureKind.transient);
    } on http.ClientException catch (e) {
      throw DestinationException(e.message, FailureKind.transient);
    } on TimeoutException catch (e) {
      throw DestinationException('$e', FailureKind.transient);
    }
  }
}
