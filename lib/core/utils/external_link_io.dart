import 'dart:io';

/// Opens a URL in the user's default browser without pulling in a plugin.
Future<bool> openExternal(String url) async {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) return false;
  try {
    if (Platform.isWindows) {
      await Process.run('cmd', <String>['/c', 'start', '', url]);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[url]);
    } else {
      await Process.run('xdg-open', <String>[url]);
    }
    return true;
  } on ProcessException {
    return false;
  }
}
