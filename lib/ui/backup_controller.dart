import 'package:flutter/widgets.dart';

import '../domain/backup_job.dart';
import '../domain/backup_progress.dart';
import '../domain/backup_run.dart';
import '../domain/media_item.dart';
import '../engine/backup_engine.dart';

enum BackupStatus { idle, running, pausing, paused, cancelling }

/// UI state around [BackupEngine]: what the buttons should show, plus
/// auto-pause when iOS backgrounds the app. Progress itself comes straight
/// from the engine's stream.
class BackupController extends ChangeNotifier {
  BackupController({
    required this._engine,
    required this._discover,
    this._afterRun,
    this._keepAwake,
  });

  final BackupEngine _engine;
  final Future<List<MediaItem>> Function() _discover;
  final Future<void> Function()? _afterRun;
  final void Function(bool on)? _keepAwake;

  BackupStatus _status = BackupStatus.idle;
  BackupRun? _lastRun;
  Object? _lastError;
  bool _pauseRequested = false;
  bool _autoPaused = false; // only resume runs the app paused itself
  bool _resumeWhenPaused = false; // came back while still pausing

  BackupStatus get status => _status;
  BackupRun? get lastRun => _lastRun;
  Object? get lastError => _lastError;
  Stream<BackupProgress> get progress => _engine.progress;

  Future<List<BackupRun>> history() => _engine.history();
  Future<List<BackupJob>> problems() => _engine.problems();
  Future<List<BackupJob>> runJobs(int runId) => _engine.runJobs(runId);

  /// Discovers the library and backs up whatever is new. Also resumes: the
  /// engine picks up jobs left pending by a pause, cancel or crash.
  Future<void> start() async {
    if (_status != BackupStatus.idle && _status != BackupStatus.paused) return;
    _pauseRequested = false;
    _resumeWhenPaused = false;
    _lastError = null;
    _setStatus(BackupStatus.running);
    _keepAwake?.call(true);
    try {
      _lastRun = await _engine.run(await _discover());
    } catch (e) {
      _lastError = e; // jobs stay on disk; the next start recovers them
    } finally {
      _keepAwake?.call(false);
      await _afterRun?.call();
    }
    final hasPending = (_lastRun?.counts[JobState.pending] ?? 0) > 0;
    _setStatus(
      _pauseRequested && hasPending && _lastError == null
          ? BackupStatus.paused
          : BackupStatus.idle,
    );
    if (_status == BackupStatus.paused && _resumeWhenPaused) await start();
  }

  /// Finishes the current file, then stops.
  void pause() {
    if (_status != BackupStatus.running) return;
    _pauseRequested = true;
    _engine.pause();
    _setStatus(BackupStatus.pausing);
  }

  Future<void> resume() async {
    _autoPaused = false;
    await start();
  }

  /// Stops at the next step; the in-flight job goes back to pending.
  void cancel() {
    _autoPaused = false;
    switch (_status) {
      case BackupStatus.running || BackupStatus.pausing:
        _pauseRequested = false; // ends idle, not paused
        _resumeWhenPaused = false;
        _engine.cancel();
        _setStatus(BackupStatus.cancelling);
      case BackupStatus.paused:
        _setStatus(BackupStatus.idle); // nothing in flight
      case BackupStatus.idle || BackupStatus.cancelling:
        break;
    }
  }

  /// iOS suspends backgrounded apps, so going to the background pauses and
  /// coming back resumes. `inactive` (e.g. Control Center) is ignored.
  void onLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        if (_status == BackupStatus.running) {
          _autoPaused = true;
          pause();
        }
      case AppLifecycleState.resumed:
        if (!_autoPaused) return;
        if (_status == BackupStatus.paused) {
          resume();
        } else if (_status == BackupStatus.pausing) {
          _autoPaused = false;
          _resumeWhenPaused = true;
        }
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  void _setStatus(BackupStatus status) {
    _status = status;
    notifyListeners();
  }
}
