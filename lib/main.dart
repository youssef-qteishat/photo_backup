import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'destination/supabase_destination.dart';
import 'discovery/photo_discovery.dart';
import 'engine/backup_engine.dart';
import 'engine/job_queue.dart';
import 'manifest/manifest_store.dart';
import 'ui/backup_controller.dart';
import 'ui/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const discovery = PhotoDiscovery();
  BackupController? controller;
  Object? startupError;
  try {
    final destination = await SupabaseDestination.create();
    final db = await openDatabase(
      '${await getDatabasesPath()}/photo_backup.db',
    );
    final engine = BackupEngine(
      queue: await JobQueue.open(db),
      manifest: await ManifestStore.open(db),
      destination: destination,
      resolveFile: discovery.originalFile,
      userId: destination.userId,
    );
    controller = BackupController(
      engine: engine,
      discover: discovery.listAll,
      afterRun: discovery.clearCache, // drop cached copies of originals
      keepAwake: (on) => WakelockPlus.toggle(enable: on),
    );
  } catch (e) {
    // Shown on screen, so a wrong IP or a stopped Supabase isn't a blank app.
    startupError = e;
  }
  runApp(
    PhotoBackupApp(
      discovery: discovery,
      controller: controller,
      startupError: startupError,
    ),
  );
}

class PhotoBackupApp extends StatelessWidget {
  const PhotoBackupApp({
    super.key,
    required this.discovery,
    this.controller,
    this.startupError,
  });

  final PhotoDiscovery discovery;
  final BackupController? controller;
  final Object? startupError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Photo Backup',
      theme: ThemeData(colorSchemeSeed: Colors.blue),
      home: BackupScreen(
        discovery: discovery,
        controller: controller,
        startupError: startupError,
      ),
    );
  }
}
