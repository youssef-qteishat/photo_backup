// lib/destination/supabase_config.dart
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const backupBucket = String.fromEnvironment(
  'SUPABASE_BUCKET',
  defaultValue: 'backups',
);

bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
