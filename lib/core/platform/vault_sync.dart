/// Cross-platform foreground hook.
///
/// [startVaultSync] starts listening and returns the function that stops it.
library;

export 'vault_sync_web.dart' if (dart.library.io) 'vault_sync_io.dart';
