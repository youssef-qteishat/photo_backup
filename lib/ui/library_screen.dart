import 'package:flutter/material.dart';

import '../discovery/photo_discovery.dart';
import '../domain/backup_job.dart';
import '../domain/backup_progress.dart';
import '../domain/media_item.dart';
import 'backup_controller.dart';
import 'history_screen.dart';

/// The backup screen: library access, "Back up now", progress by bytes,
/// Pause/Resume/Cancel, and counts.
///
/// Stateful because it owns state that outlives a build: library access, the
/// discovered items, and the app-lifecycle observer. The progress and status
/// parts below are rebuilt from the engine's stream and the controller.
class BackupScreen extends StatefulWidget {
  const BackupScreen({
    super.key,
    this.discovery = const PhotoDiscovery(),
    this.controller,
    this.startupError,
  });

  final PhotoDiscovery discovery;

  /// Null when the backup server couldn't be set up; see [startupError].
  final BackupController? controller;
  final Object? startupError;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen>
    with WidgetsBindingObserver {
  LibraryAccess? _access; // null while loading
  List<MediaItem> _items = const [];
  bool _showItems = true; // the "All items" section is collapsible

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller?.onLifecycle(state); // auto-pause in the background
    // The user may have changed access in Settings while we were away.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final access = await widget.discovery.requestAccess();
    final items = access == LibraryAccess.denied
        ? const <MediaItem>[]
        : await widget.discovery.listAll();
    if (!mounted) return;
    setState(() {
      _access = access;
      _items = items;
    });
  }

  Future<void> _selectMore() async {
    await widget.discovery.selectMorePhotos();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photo Backup'),
        actions: [
          IconButton(
            tooltip: 'History',
            icon: const Icon(Icons.history),
            onPressed: controller == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => HistoryScreen(controller: controller),
                    ),
                  ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.startupError != null)
            MaterialBanner(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              content: Text(
                "Can't reach the backup server: ${widget.startupError}\n"
                'Is `supabase start` running? On iPhone, SUPABASE_URL in '
                "env/device.env must use the Mac's Wi-Fi IP.",
              ),
              actions: const [SizedBox.shrink()],
            ),
          Expanded(child: _body(controller)),
        ],
      ),
    );
  }

  Widget _body(BackupController? controller) {
    return switch (_access) {
      null => const Center(child: CircularProgressIndicator()),
      LibraryAccess.denied => _Denied(
        onOpenSettings: widget.discovery.openSettings,
      ),
      // Slivers so the item list builds rows lazily as they scroll into
      // view; a plain Column/ListView of children would build every row.
      LibraryAccess.full || LibraryAccess.limited => RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  if (_access == LibraryAccess.limited)
                    MaterialBanner(
                      content: const Text(
                        'Only selected photos are visible, so only they will '
                        'be backed up.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: _selectMore,
                          child: const Text('Select more'),
                        ),
                        TextButton(
                          onPressed: widget.discovery.openSettings,
                          child: const Text('Allow all'),
                        ),
                      ],
                    ),
                  ListTile(
                    leading: const Icon(Icons.photo_library_outlined),
                    title: Text('${_items.length} photos and videos'),
                    trailing: Text(
                      formatBytes(
                        _items.fold(0, (sum, i) => sum + i.sizeBytes),
                      ),
                    ),
                  ),
                  if (controller != null)
                    _BackupPanel(
                      controller: controller,
                      canStart: _items.isNotEmpty,
                    ),
                  const Divider(height: 1),
                  ListTile(
                    title: const Text('All items'),
                    trailing: Icon(
                      _showItems ? Icons.expand_less : Icons.expand_more,
                    ),
                    onTap: () => setState(() => _showItems = !_showItems),
                  ),
                ],
              ),
            ),
            if (_showItems)
              SliverList.builder(
                itemCount: _items.length,
                itemBuilder: (context, i) => _ItemTile(item: _items[i]),
              ),
          ],
        ),
      ),
    };
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        item.type == MediaType.video
            ? Icons.videocam_outlined
            : Icons.photo_outlined,
      ),
      title: Text(item.fileName, overflow: TextOverflow.ellipsis),
      trailing: Text(formatBytes(item.sizeBytes)),
    );
  }
}

/// Stateless: everything it shows comes from [controller] (status, last run)
/// and the engine's progress stream, so it simply rebuilds when they change.
class _BackupPanel extends StatelessWidget {
  const _BackupPanel({required this.controller, required this.canStart});

  final BackupController controller;
  final bool canStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final status = controller.status;
        final active = status != BackupStatus.idle;
        return Card(
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StreamBuilder<BackupProgress>(
                  stream: controller.progress,
                  builder: (context, snapshot) {
                    final p = snapshot.data;
                    if (p == null) return const SizedBox.shrink();
                    return _ProgressView(progress: p, showFile: active);
                  },
                ),
                _buttons(status),
                if (!active && controller.lastRun != null) ...[
                  const SizedBox(height: 12),
                  Text(_lastRunSummary(), textAlign: TextAlign.center),
                ],
                if (controller.lastError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Backup stopped: ${controller.lastError}',
                    style: TextStyle(color: theme.colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buttons(BackupStatus status) {
    return switch (status) {
      BackupStatus.idle => FilledButton.icon(
        onPressed: canStart ? controller.start : null,
        icon: const Icon(Icons.cloud_upload_outlined),
        label: const Text('Back up now'),
      ),
      BackupStatus.running => Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: controller.pause,
              icon: const Icon(Icons.pause),
              label: const Text('Pause'),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: controller.cancel, child: const Text('Cancel')),
        ],
      ),
      BackupStatus.paused => Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: controller.resume,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Resume'),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: controller.cancel, child: const Text('Cancel')),
        ],
      ),
      BackupStatus.pausing => const FilledButton(
        onPressed: null,
        child: Text('Pausing after this file…'),
      ),
      BackupStatus.cancelling => const FilledButton(
        onPressed: null,
        child: Text('Cancelling…'),
      ),
    };
  }

  String _lastRunSummary() {
    final counts = controller.lastRun!.counts;
    if (counts.values.every((n) => n == 0)) return 'Everything is backed up.';
    String n(JobState s) => '${counts[s] ?? 0}';
    final pending = counts[JobState.pending] ?? 0;
    return 'Last run: done ${n(JobState.done)} · '
        'skipped ${n(JobState.skipped)} · failed ${n(JobState.failed)}'
        '${pending > 0 ? ' · $pending not started' : ''}';
  }
}

class _ProgressView extends StatelessWidget {
  const _ProgressView({required this.progress, required this.showFile});

  final BackupProgress progress;
  final bool showFile;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    // Bytes count both passes (hash + upload), so show a percentage.
    final fraction = p.bytesTotal == 0 ? 1.0 : p.bytesDone / p.bytesTotal;
    int count(JobState s) => p.counts[s] ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: LinearProgressIndicator(value: fraction)),
              const SizedBox(width: 12),
              Text('${(fraction * 100).floor()}%'),
            ],
          ),
          if (showFile && p.currentFile != null) ...[
            const SizedBox(height: 8),
            Text(
              p.currentFile!,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              Chip(label: Text('Done ${count(JobState.done)}')),
              Chip(label: Text('Skipped ${count(JobState.skipped)}')),
              Chip(label: Text('Failed ${count(JobState.failed)}')),
            ],
          ),
        ],
      ),
    );
  }
}

class _Denied extends StatelessWidget {
  const _Denied({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library_outlined, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Photo Backup needs access to your photos to back them up.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onOpenSettings,
              child: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 1536 -> "1.5 KB" (base 1024, one decimal above bytes).
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}
