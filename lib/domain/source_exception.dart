import 'backup_job.dart';

/// A failure reading from the source (e.g. an iCloud download of an
/// original), classified like destination errors so the engine can retry it.
class SourceException implements Exception {
  final String message;
  final FailureKind kind;

  const SourceException(this.message, this.kind);

  @override
  String toString() => 'SourceException(${kind.name}): $message';
}
