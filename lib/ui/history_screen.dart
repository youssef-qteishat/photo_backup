import 'dart:math';

import 'package:flutter/material.dart';

import '../domain/backup_job.dart';
import '../domain/backup_run.dart';
import 'backup_controller.dart';
import 'library_screen.dart' show formatBytes;

/// Past runs (each expands to the files it handled), plus files that failed
/// or were skipped in the latest run, with reasons.
/// Stateless: the data is loaded once per visit by the FutureBuilder.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.controller});

  final BackupController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: FutureBuilder(
        future: Future.wait([controller.history(), controller.problems()]),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text('Could not load history: ${snapshot.error}'),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final runs = snapshot.data![0] as List<BackupRun>;
          final problems = snapshot.data![1] as List<BackupJob>;
          final heading = Theme.of(context).textTheme.titleSmall;
          return ListView(
            children: [
              ListTile(title: Text('Needs attention', style: heading)),
              if (problems.isEmpty)
                const ListTile(title: Text('Nothing needs attention.')),
              for (final job in problems) _JobTile(job: job),
              const Divider(),
              ListTile(title: Text('Runs', style: heading)),
              if (runs.isEmpty) const ListTile(title: Text('No backups yet.')),
              for (final run in runs)
                _RunTile(run: run, loadJobs: controller.runJobs),
            ],
          );
        },
      ),
    );
  }
}

/// One file's outcome: state, failure kind, and reason.
class _JobTile extends StatelessWidget {
  const _JobTile({required this.job, this.dense = false});

  final BackupJob job;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    final (icon, color) = switch (job.state) {
      JobState.done => (Icons.check_circle_outline, null),
      JobState.failed => (Icons.error_outline, error),
      JobState.skipped => (Icons.skip_next_outlined, null),
      _ => (Icons.schedule, null), // pending: paused or cancelled first
    };
    final kind = job.failureKind == null ? '' : ' (${job.failureKind!.name})';
    return ListTile(
      dense: dense,
      leading: Icon(icon, color: color),
      title: Text(job.item.fileName, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        job.reason == null
            ? job.state.name
            : '${job.state.name}$kind: ${job.reason}',
      ),
      trailing: Text(formatBytes(job.item.sizeBytes)),
    );
  }
}

/// A run's summary; expands to a scrollable list of the files it handled.
class _RunTile extends StatelessWidget {
  const _RunTile({required this.run, required this.loadJobs});

  final BackupRun run;
  final Future<List<BackupJob>> Function(int runId) loadJobs;

  @override
  Widget build(BuildContext context) {
    final c = run.counts;
    final duration = run.finishedAt?.difference(run.startedAt);
    final summary =
        'done ${c[JobState.done] ?? 0} · skipped ${c[JobState.skipped] ?? 0} · '
        'failed ${c[JobState.failed] ?? 0} · '
        '${formatBytes(run.bytesTransferred)}'
        '${duration == null ? '' : ' · ${_formatDuration(duration)}'}';
    final title = Text(_formatDate(run.startedAt));
    const icon = Icon(Icons.cloud_done_outlined);
    final id = run.id;
    if (id == null) {
      return ListTile(leading: icon, title: title, subtitle: Text(summary));
    }
    // Children are only built while expanded, so jobs load on first open.
    return ExpansionTile(
      leading: icon,
      title: title,
      subtitle: Text(summary),
      children: [
        _RunJobs(
          load: () => loadJobs(id),
          hadFiles: run.counts.values.any((n) => n > 0),
        ),
      ],
    );
  }

  static String _formatDate(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  static String _formatDuration(Duration d) => d.inMinutes > 0
      ? '${d.inMinutes}m ${d.inSeconds % 60}s'
      : '${d.inSeconds}s';
}

/// Stateful only to keep the load Future across rebuilds, so expanding a run
/// queries SQLite once rather than on every rebuild.
class _RunJobs extends StatefulWidget {
  const _RunJobs({required this.load, required this.hadFiles});

  final Future<List<BackupJob>> Function() load;

  /// False when the run had nothing to do; true but no rows means the run
  /// predates per-run file history.
  final bool hadFiles;

  @override
  State<_RunJobs> createState() => _RunJobsState();
}

class _RunJobsState extends State<_RunJobs> {
  static const _rowHeight = 64.0;
  static const _maxVisibleRows = 6;

  late final Future<List<BackupJob>> _jobs = widget.load();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _jobs,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListTile(title: Text('Could not load: ${snapshot.error}'));
        }
        final jobs = snapshot.data;
        if (jobs == null) return const LinearProgressIndicator();
        if (jobs.isEmpty) {
          return ListTile(
            dense: true,
            title: Text(
              widget.hadFiles
                  ? 'File details were not recorded for this run.'
                  : 'No files: everything was already backed up.',
            ),
          );
        }
        // A bounded box so long runs scroll inside the tile instead of
        // stretching the page.
        return SizedBox(
          height: _rowHeight * min(jobs.length, _maxVisibleRows),
          child: ListView.builder(
            itemExtent: _rowHeight,
            itemCount: jobs.length,
            itemBuilder: (context, i) => _JobTile(job: jobs[i], dense: true),
          ),
        );
      },
    );
  }
}
