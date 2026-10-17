import 'package:web/web.dart' as web;

/// Opens a URL in a new browser tab.
Future<bool> openExternal(String url) async {
  return web.window.open(url, '_blank') != null;
}
