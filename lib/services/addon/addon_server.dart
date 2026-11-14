import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/addon/addon_catalog_service.dart';
import 'package:mornye/services/addon/addon_playback_service.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('AddonServer');

/// Serves the Eclipse add-on over the local network.
///
/// Eclipse installs an add-on from its manifest URL and then calls `/search`,
/// `/stream`, the optional detail endpoints and any catalog rows. Every answer
/// comes from the app's own providers, downloads and library, so the add-on
/// shows what the app shows.
class AddonServer {
  AddonServer({required Ref ref, required this.port})
    : _catalog = AddonCatalogService(ref),
      _playback = AddonPlaybackService(ref);

  final int port;
  final AddonCatalogService _catalog;
  final AddonPlaybackService _playback;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    // Android 17 gates LAN sockets; the app asks for the grant it already
    // requests for SMB and local media servers. Older releases always allow.
    try {
      await LocalNetworkAccess.instance.ensureGranted();
    } catch (error) {
      _log.w('Local network permission not granted: $error');
    }
    final server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      port,
      shared: false,
    );
    server.autoCompress = true;
    _server = server;
    _subscription = server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object error) => _log.w('Server error: $error'),
      cancelOnError: false,
    );
    _log.i('Eclipse add-on listening on port $port');
  }

  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final server = _server;
    _server = null;
    if (server == null) return;
    try {
      await server.close(force: true);
    } catch (error) {
      _log.w('Could not close the add-on server: $error');
    }
    _log.i('Eclipse add-on stopped');
  }

  // --- Routing ------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'OPTIONS') {
        final response = request.response;
        _applyCors(response);
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }

      final segments = request.uri.pathSegments;
      if (segments.isEmpty) {
        await _serveLanding(request);
        return;
      }

      switch (segments.first) {
        case 'manifest.json':
          await _json(request, _manifest());
          return;
        case 'search':
          final query = request.uri.queryParameters['q'] ?? '';
          await _json(request, await _catalog.search(query));
          return;
        case 'stream':
          await _handleStream(request, segments);
          return;
        case 'album':
          await _handleDetail(request, segments, _catalog.album);
          return;
        case 'artist':
          await _handleDetail(request, segments, _catalog.artist);
          return;
        case 'playlist':
          await _handleDetail(request, segments, _catalog.playlist);
          return;
        case 'catalog':
          final id = segments.length > 1 ? segments[1] : '';
          final skip = int.tryParse(request.uri.queryParameters['skip'] ?? '');
          await _json(request, await _catalog.catalogRow(id, skip ?? 0));
          return;
        case 'play':
          await _handlePlay(request, segments);
          return;
        case 'cover':
          await _handleCover(request, segments);
          return;
        case 'health':
          await _json(request, {'status': 'ok', 'app': AppInfo.appName});
          return;
        default:
          await _json(request, {'error': 'not found'}, status: 404);
          return;
      }
    } catch (error, stackTrace) {
      _log.w('Request failed: $error\n$stackTrace');
      try {
        await _json(request, {'error': 'internal error'}, status: 500);
      } catch (_) {
        // The client is already gone.
      }
    }
  }

  Map<String, dynamic> _manifest() => {
    'id': 'org.mornye.eclipse.addon',
    'name': 'Mornye',
    'version': AppInfo.version,
    'description':
        'Your Mornye catalogue in Eclipse. Browse the same providers the app '
        'uses, and each track is downloaded into your library and streamed '
        'from there.',
    'resources': ['search', 'stream', 'catalog'],
    'types': ['track', 'album', 'artist', 'playlist'],
    'contentType': 'music',
    'catalogs': AddonCatalogService.catalogDescriptors(),
  };

  Future<void> _handleStream(HttpRequest request, List<String> segments) async {
    if (segments.length < 2) {
      await _json(request, {'error': 'not found'}, status: 404);
      return;
    }
    final id = segments[1];
    try {
      final info = await _playback.streamInfo(
        id: id,
        baseUrl: _baseUrl(request),
      );
      await _json(request, info);
    } on AddonPlaybackException catch (error) {
      await _json(request, {'error': error.message}, status: 404);
    }
  }

  Future<void> _handleDetail(
    HttpRequest request,
    List<String> segments,
    Future<Map<String, dynamic>?> Function(String id) load,
  ) async {
    if (segments.length < 2) {
      await _json(request, {'error': 'not found'}, status: 404);
      return;
    }
    final payload = await load(segments[1]);
    if (payload == null) {
      await _json(request, {'error': 'not found'}, status: 404);
      return;
    }
    await _json(request, payload);
  }

  Future<void> _handlePlay(HttpRequest request, List<String> segments) async {
    if (segments.length < 2) {
      await _json(request, {'error': 'not found'}, status: 404);
      return;
    }
    final id = segments[1];

    try {
      final handle = await _playback.beginPlay(id);
      final ready = handle.readyFile;
      if (ready != null) {
        await _serveFile(request, ready);
        return;
      }
      // Playback starts as soon as the source has written the first bytes.
      final partial = await handle.findPartialFile();
      if (partial != null) {
        await _serveGrowing(request, handle, partial);
        return;
      }
      await _serveFile(request, await handle.waitForFile());
    } on AddonPlaybackException catch (error) {
      await _json(request, {'error': error.message}, status: 502);
    }
  }

  Future<void> _handleCover(HttpRequest request, List<String> segments) async {
    if (segments.length < 2) {
      await _json(request, {'error': 'not found'}, status: 404);
      return;
    }
    final rowId = segments[1];
    final row = await LibraryDatabase.instance.getById(rowId);
    final coverPath = (row?['coverPath'] ?? '').toString().trim();
    if (coverPath.isEmpty) {
      await _json(request, {'error': 'not found'}, status: 404);
      return;
    }
    final file = File(coverPath);
    if (!await file.exists()) {
      await _json(request, {'error': 'not found'}, status: 404);
      return;
    }
    await _serveFile(request, file);
  }

  Future<void> _serveLanding(HttpRequest request) async {
    final baseUrl = _baseUrl(request);
    final manifestUrl = '$baseUrl/manifest.json';
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/html; charset=utf-8',
    );
    _applyCors(response);
    response.write('''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mornye · Eclipse add-on</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 0; padding: 40px 20px;
         background: #101014; color: #f3f3f5; }
  main { max-width: 640px; margin: 0 auto; }
  h1 { font-size: 1.6rem; margin: 0 0 8px; }
  p { color: #b9b9c2; line-height: 1.55; }
  code { background: #1d1d24; padding: 3px 6px; border-radius: 6px;
         word-break: break-all; }
</style>
</head>
<body>
<main>
  <h1>Mornye</h1>
  <p>The add-on is running. In Eclipse Music open
  <em>Settings → Connections → Add Connection → Addon</em> and paste this
  manifest URL.</p>
  <p><code>$manifestUrl</code></p>
  <p>Both devices must be on the same network. Keep Mornye open while you
  stream: the app resolves the download and serves the file.</p>
</main>
</body>
</html>
''');
    await response.close();
  }

  // --- Responses ----------------------------------------------------------

  String _baseUrl(HttpRequest request) {
    final host = request.headers.value(HttpHeaders.hostHeader);
    if (host != null && host.trim().isNotEmpty) {
      return 'http://${host.trim()}';
    }
    // HttpConnectionInfo only exposes the local port, not the local address;
    // Eclipse always sends a Host header, so this is a last resort.
    final localPort = request.connectionInfo?.localPort ?? port;
    return 'http://127.0.0.1:$localPort';
  }

  Future<void> _json(
    HttpRequest request,
    Object body, {
    int status = HttpStatus.ok,
  }) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    _applyCors(response);
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _serveFile(HttpRequest request, File file) async {
    final length = await file.length();
    if (length == 0) {
      await _json(request, {'error': 'empty file'}, status: 503);
      return;
    }

    var start = 0;
    var end = length - 1;
    var partial = false;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null && rangeHeader.trim().isNotEmpty) {
      final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(rangeHeader);
      if (match != null) {
        final startText = match.group(1) ?? '';
        final endText = match.group(2) ?? '';
        if (startText.isEmpty && endText.isNotEmpty) {
          final suffix = int.tryParse(endText) ?? 0;
          start = (length - suffix).clamp(0, length - 1).toInt();
        } else {
          start = int.tryParse(startText) ?? 0;
          if (endText.isNotEmpty) end = int.tryParse(endText) ?? end;
        }
        if (start < 0 || start >= length) {
          final response = request.response;
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$length',
          );
          _applyCors(response);
          await response.close();
          return;
        }
        end = end.clamp(start, length - 1).toInt();
        partial = true;
      }
    }

    final response = request.response;
    response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.contentTypeHeader, _mimeType(file.path));
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (partial) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    }
    _applyCors(response);
    response.contentLength = end - start + 1;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    try {
      await response.addStream(file.openRead(start, end + 1));
    } catch (error) {
      _log.d('Playback stream ended early: $error');
    } finally {
      try {
        await response.close();
      } catch (_) {
        // The player closed the connection.
      }
    }
  }

  /// Sends a file that is still being written, so the player starts before
  /// the download ends. The response is chunked because the final length is
  /// not known yet; once the library file exists it is served with ranges.
  Future<void> _serveGrowing(
    HttpRequest request,
    AddonPlayHandle handle,
    File initial,
  ) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'none');
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      _mimeType(initial.path),
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    _applyCors(response);
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }

    var current = initial;
    var offset = 0;
    final deadline = DateTime.now().add(AddonPlaybackService.downloadTimeout);
    try {
      while (true) {
        var length = 0;
        try {
          length = await current.length();
        } catch (_) {
          length = 0;
        }
        if (length > offset) {
          await response.addStream(current.openRead(offset, length));
          offset = length;
        }
        if (handle.isComplete) {
          final finalFile = handle.finalFile;
          if (finalFile != null && finalFile.path != current.path) {
            current = finalFile;
            continue;
          }
          if (length <= offset) break;
        }
        if (DateTime.now().isAfter(deadline)) {
          _log.w('Playback stopped: the download ran out of time');
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        // Advances the handle: this is where a finished or failed download
        // is noticed while bytes are still being sent.
        await handle.nextSource();
      }
    } catch (error) {
      _log.d('Playback stream ended: $error');
    } finally {
      try {
        await response.close();
      } catch (_) {
        // The player closed the connection.
      }
    }
  }

  void _applyCors(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
    response.headers.set(
      'Access-Control-Allow-Headers',
      'Range, Content-Type, Accept, Origin',
    );
    response.headers.set(
      'Access-Control-Expose-Headers',
      'Content-Range, Content-Length, Accept-Ranges',
    );
  }

  static String _mimeType(String path) {
    final dot = path.lastIndexOf('.');
    final extension = dot == -1 ? '' : path.substring(dot + 1).toLowerCase();
    return switch (extension) {
      'mp3' => 'audio/mpeg',
      'flac' => 'audio/flac',
      'm4a' || 'mp4' || 'aac' || 'alac' => 'audio/mp4',
      'ogg' || 'oga' => 'audio/ogg',
      'opus' => 'audio/opus',
      'wav' => 'audio/wav',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => 'application/octet-stream',
    };
  }
}

/// The addresses other devices on the network can use to reach [port].
Future<List<String>> addonLanUrls(int port) async {
  final addresses = <String>[];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final ip = address.address;
        if (ip.startsWith('169.254.')) continue;
        if (addresses.contains(ip)) continue;
        addresses.add(ip);
      }
    }
  } catch (error) {
    _log.w('Could not list network interfaces: $error');
  }
  bool isPrivate(String ip) =>
      ip.startsWith('192.168.') ||
      ip.startsWith('10.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
  addresses.sort((a, b) {
    final aPrivate = isPrivate(a) ? 0 : 1;
    final bPrivate = isPrivate(b) ? 0 : 1;
    return aPrivate != bPrivate ? aPrivate - bPrivate : a.compareTo(b);
  });
  if (addresses.isEmpty) return ['http://127.0.0.1:$port'];
  return [for (final ip in addresses) 'http://$ip:$port'];
}
