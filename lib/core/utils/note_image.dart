/// Resolves an image reference from a note to something the editor can draw.
library;

export 'note_image_web.dart' if (dart.library.io) 'note_image_io.dart';
