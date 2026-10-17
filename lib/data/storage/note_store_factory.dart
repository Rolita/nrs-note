/// Picks the right [NoteStore] implementation at compile time.
///
/// Desktop / mobile get real `.md` files on disk; the web build falls back to
/// browser storage so the UI can still be previewed and shared.
library;

export 'note_store.dart';
export 'note_store_web.dart' if (dart.library.io) 'note_store_io.dart';
