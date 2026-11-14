import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/stremio/stremio_ids.dart';
import 'package:mornye/services/stremio/stremio_track_cache.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = AppLogger('StremioStreams');

/// A playback request the add-on cannot serve, reported to Stremio as a 502.
class StremioPlaybackException implements Exception {
  const StremioPlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Stream lists and playback for the Stremio add-on.
///
/// Every stream is a download source the app already has: one entry per
/// enabled download extension (and its quality options), plus the copy already
/// in the library. Choosing one enqueues the normal download, and the file is
/// served as it arrives, so playback starts before the download ends. The
/// finished file stays in the library, so the next play is instant.
class StremioStreamService {
  StremioStreamService(this._ref);

  /// How long a play request waits for the library download to finish when the
  /// partially written file could not be found.
  static const Duration downloadTimeout = Duration(minutes: 4);

  static const int maxStreams = 24;

  static const String _stagingPrefix = '.mornye-download-';

  final Ref _ref;

  Future<List<Map<String, dynamic>>> streams({
    required String id,
    required String baseUrl,
  }) async {
    final ref = StremioIds.parse(id);
    if (ref == null) return const [];

    if (ref.isLibrary) {
      final row = await LibraryDatabase.instance.getById(ref.value);
      if (row == null) return const [];
      return [
        _entry(
          baseUrl: baseUrl,
          id: id,
          mode: 'lib',
          service: '',
          quality: '',
          name: 'Mornye · Library',
          detail: 'Already in your library · plays instantly',
          bingeGroup: 'mornye-library',
        ),
      ];
    }

    if (!ref.isTrack) {
      // Albums, playlists and artists stream through their track list.
      return const [];
    }

    final track = await StremioTrackCache.instance.resolve(
      ref.source,
      ref.value,
    );
    if (track == null) return const [];

    final streams = <Map<String, dynamic>>[];

    if (await _libraryFile(track) != null) {
      streams.add(
        _entry(
          baseUrl: baseUrl,
          id: id,
          mode: 'lib',
          service: '',
          quality: '',
          name: 'Mornye · Library',
          detail: 'Already in your library · plays instantly',
          bingeGroup: 'mornye-library',
        ),
      );
    }

    for (final extension in _downloadExtensions()) {
      final qualities = extension.qualityOptions;
      if (qualities.isEmpty) {
        streams.add(
          _entry(
            baseUrl: baseUrl,
            id: id,
            mode: 'dl',
            service: extension.id,
            quality: '',
            name: 'Mornye · ${extension.displayName}',
            detail: '${extension.displayName} · downloads, then streams',
            bingeGroup: 'mornye-${extension.id}',
          ),
        );
      } else {
        for (final quality in qualities) {
          streams.add(
            _entry(
              baseUrl: baseUrl,
              id: id,
              mode: 'dl',
              service: extension.id,
              quality: quality.id,
              name: 'Mornye · ${extension.displayName}',
              detail:
                  '${extension.displayName} · ${quality.label} · downloads, then streams',
              bingeGroup: 'mornye-${extension.id}-${quality.id}',
            ),
          );
        }
      }
      if (streams.length >= maxStreams) break;
    }

    return streams;
  }

  /// Starts (or finds) the download behind a `/play` request.
  ///
  /// Returns a handle whose [StremioPlayHandle.readyFile] is set when the file
  /// is already on disk. Otherwise the caller serves the handle's partial file
  /// while the download runs, or waits for [StremioPlayHandle.waitForFile].
  Future<StremioPlayHandle> beginPlay({
    required String id,
    required String mode,
    required String service,
    required String quality,
  }) async {
    final ref = StremioIds.parse(id);
    if (ref == null) {
      throw const StremioPlaybackException('Unknown track id');
    }

    if (ref.isLibrary) {
      final row = await LibraryDatabase.instance.getById(ref.value);
      final file = await _fileForPath((row?['filePath'] ?? '').toString());
      if (file == null) {
        throw const StremioPlaybackException(
          'The library file for this track is missing',
        );
      }
      return StremioPlayHandle.ready(this, file);
    }

    if (!ref.isTrack) {
      throw const StremioPlaybackException(
        'Open a track from the album or playlist to play it',
      );
    }

    final track = await StremioTrackCache.instance.resolve(
      ref.source,
      ref.value,
    );
    if (track == null) {
      throw const StremioPlaybackException(
        'This track is no longer available from its provider',
      );
    }

    final existing = await _libraryFile(track);
    if (existing != null) return StremioPlayHandle.ready(this, existing);

    if (mode == 'lib') {
      throw const StremioPlaybackException(
        'This track is not in your library any more',
      );
    }
    if (service.trim().isEmpty) {
      throw const StremioPlaybackException('No download source was requested');
    }

    return _enqueue(track, service.trim(), quality.trim());
  }

  Future<StremioPlayHandle> _enqueue(
    Track track,
    String service,
    String quality,
  ) async {
    final queue = _ref.read(downloadQueueProvider);
    if (queue.isPaused) {
      throw const StremioPlaybackException(
        'Downloads are paused in Mornye. Resume the queue, then try again.',
      );
    }

    final notifier = _ref.read(downloadQueueProvider.notifier);
    for (final item in queue.items) {
      if (!_sameTrack(item.track, track)) continue;
      if (item.status == DownloadStatus.failed) continue;
      if (item.status == DownloadStatus.skipped) continue;
      if (item.service.toLowerCase() != service.toLowerCase()) continue;
      // Reuse a download that is already queued or running for this track.
      // Its staging directory already exists, so it cannot be identified by
      // difference: wait for the finished file instead.
      return StremioPlayHandle.queued(this, item.id, track, null);
    }

    final knownStaging = await _stagingDirectories();
    _log.i('Queueing ${track.name} from $service');
    final itemId = notifier.addToQueue(
      track,
      service,
      qualityOverride: quality.isEmpty ? null : quality,
    );
    return StremioPlayHandle.queued(this, itemId, track, knownStaging);
  }

  // --- Queue state --------------------------------------------------------

  DownloadItem? itemById(String itemId) {
    for (final item in _ref.read(downloadQueueProvider).items) {
      if (item.id == itemId) return item;
    }
    return null;
  }

  static bool _sameTrack(Track a, Track b) {
    final isrcA = (a.isrc ?? '').trim().toLowerCase();
    final isrcB = (b.isrc ?? '').trim().toLowerCase();
    if (isrcA.isNotEmpty && isrcB.isNotEmpty) return isrcA == isrcB;
    return a.id.trim().toLowerCase() == b.id.trim().toLowerCase();
  }

  // --- Library ------------------------------------------------------------

  Future<File?> _libraryFile(Track track) async {
    try {
      final row = await LibraryDatabase.instance.findExisting(
        isrc: track.isrc,
        trackName: track.name,
        artistName: track.artistName,
      );
      if (row == null) return null;
      return _fileForPath((row['filePath'] ?? '').toString());
    } catch (error) {
      _log.w('Library lookup failed for ${track.name}: $error');
      return null;
    }
  }

  /// Local paths are read directly. SAF documents (Android) are copied to the
  /// app cache first, because the player only understands a file.
  Future<File?> _fileForPath(String path) async {
    final value = path.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('content://')) {
      try {
        final copy = await PlatformBridge.copyContentUriToTemp(value);
        if (copy == null || copy.isEmpty) return null;
        final file = File(copy);
        return await file.exists() ? file : null;
      } catch (error) {
        _log.w('Could not open library document: $error');
        return null;
      }
    }
    final file = File(value);
    return await file.exists() ? file : null;
  }

  // --- Partially written downloads ---------------------------------------

  /// The staging directories that exist right now.
  ///
  /// An extension writes into `<support>/extension_data/<extension>/downloads/
  /// .mornye-download-*` and the backend moves the file into the library when
  /// the transfer ends. Remembering the directories that exist before a
  /// download starts is what identifies the one it creates.
  Future<Set<String>> _stagingDirectories() async {
    final found = <String>{};
    try {
      final root = await _stagingRoot();
      if (root == null) return found;
      await for (final extensionDir in root.list(followLinks: false)) {
        if (extensionDir is! Directory) continue;
        final downloads = Directory(p.join(extensionDir.path, 'downloads'));
        if (!await downloads.exists()) continue;
        await for (final entry in downloads.list(followLinks: false)) {
          if (entry is Directory &&
              p.basename(entry.path).startsWith(_stagingPrefix)) {
            found.add(entry.path);
          }
        }
      }
    } catch (error) {
      _log.d('Could not list download staging: $error');
    }
    return found;
  }

  Future<Directory?> _stagingRoot() async {
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory(p.join(support.path, 'extension_data'));
      return await root.exists() ? root : null;
    } catch (error) {
      _log.d('Could not resolve the extension data directory: $error');
      return null;
    }
  }

  /// The file a running download is writing, if one has appeared since
  /// [knownStaging] was captured.
  Future<File?> stagingFile(Set<String> knownStaging) async {
    try {
      final root = await _stagingRoot();
      if (root == null) return null;
      await for (final extensionDir in root.list(followLinks: false)) {
        if (extensionDir is! Directory) continue;
        final downloads = Directory(p.join(extensionDir.path, 'downloads'));
        if (!await downloads.exists()) continue;
        await for (final entry in downloads.list(followLinks: false)) {
          if (entry is! Directory) continue;
          if (!p.basename(entry.path).startsWith(_stagingPrefix)) continue;
          if (knownStaging.contains(entry.path)) continue;
          await for (final file in entry.list(followLinks: false)) {
            if (file is! File) continue;
            if (await file.length() == 0) continue;
            return file;
          }
        }
      }
    } catch (error) {
      _log.d('Could not read download staging: $error');
    }
    return null;
  }

  // --- Sources ------------------------------------------------------------

  List<Extension> _downloadExtensions() {
    return _ref
        .read(extensionProvider)
        .extensions
        .where(
          (extension) => extension.enabled && extension.hasDownloadProvider,
        )
        .toList(growable: false);
  }

  Map<String, dynamic> _entry({
    required String baseUrl,
    required String id,
    required String mode,
    required String service,
    required String quality,
    required String name,
    required String detail,
    required String bingeGroup,
  }) {
    final query = <String, String>{
      'm': mode,
      if (service.isNotEmpty) 's': service,
      if (quality.isNotEmpty) 'q': quality,
    };
    final suffix = query.entries
        .map((entry) => '${entry.key}=${Uri.encodeQueryComponent(entry.value)}')
        .join('&');
    return {
      'name': name,
      'title': detail,
      'url': '$baseUrl/play/${Uri.encodeComponent(id)}?$suffix',
      'behaviorHints': {'bingeGroup': bingeGroup, 'notWebReady': false},
    };
  }
}

/// One in-flight playback request: either a finished file, or a download the
/// caller can follow while it writes.
class StremioPlayHandle {
  StremioPlayHandle._({
    required this.service,
    this.readyFile,
    this.itemId,
    this.track,
    this.knownStaging,
  });

  factory StremioPlayHandle.ready(StremioStreamService service, File file) =>
      StremioPlayHandle._(service: service, readyFile: file);

  factory StremioPlayHandle.queued(
    StremioStreamService service,
    String itemId,
    Track track,
    Set<String>? knownStaging,
  ) => StremioPlayHandle._(
    service: service,
    itemId: itemId,
    track: track,
    knownStaging: knownStaging,
  );

  final StremioStreamService service;

  /// Set when the audio is already on disk.
  final File? readyFile;

  final String? itemId;
  final Track? track;

  /// Staging directories that existed before this download started. Null when
  /// the download was already running, which makes the partial file unusable
  /// as an identifier.
  final Set<String>? knownStaging;

  File? _finalFile;
  bool _complete = false;

  bool get isComplete => _complete;
  File? get finalFile => _finalFile;

  /// Waits for the download to finish and returns the library file.
  Future<File> waitForFile() async {
    if (readyFile != null) return readyFile!;
    final itemId = this.itemId;
    if (itemId == null) {
      throw const StremioPlaybackException('Nothing to download');
    }
    final deadline = DateTime.now().add(StremioStreamService.downloadTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final file = await _poll();
      if (file != null) return file;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    _log.w('Timed out waiting for ${track?.name ?? itemId}');
    throw const StremioPlaybackException(
      'The download did not finish in time. Check the queue in Mornye, then try again.',
    );
  }

  /// Follows the download without blocking: returns the file to read next, or
  /// null once the finished library file has been read to its end.
  Future<File?> nextSource() async {
    if (_complete) return _finalFile;
    final file = await _poll();
    if (file != null) return file;
    return null;
  }

  /// The partially written file, once the source starts writing one.
  Future<File?> findPartialFile({
    Duration within = const Duration(seconds: 8),
  }) {
    final deadline = DateTime.now().add(within);
    return _pollPartial(deadline);
  }

  Future<File?> _pollPartial(DateTime deadline) async {
    final known = knownStaging;
    if (known == null) return null;
    while (DateTime.now().isBefore(deadline)) {
      if (_complete) return _finalFile;
      final partial = await service.stagingFile(known);
      if (partial != null) return partial;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  /// Returns the finished file, marking the handle complete, or null while the
  /// download is still running.
  Future<File?> _poll() async {
    if (_complete) return _finalFile;
    final itemId = this.itemId;
    if (itemId == null) return null;
    final item = service.itemById(itemId);
    if (item == null) return null;
    if (item.status == DownloadStatus.completed) {
      final file = await service._fileForPath(item.filePath ?? '');
      if (file == null) return null;
      _finalFile = file;
      _complete = true;
      return file;
    }
    if (item.status == DownloadStatus.skipped) {
      final track = this.track;
      if (track != null) {
        final library = await service._libraryFile(track);
        if (library != null) {
          _finalFile = library;
          _complete = true;
          return library;
        }
      }
      throw StremioPlaybackException(
        item.error ?? 'The source skipped this track',
      );
    }
    if (item.status == DownloadStatus.failed) {
      throw StremioPlaybackException(item.error ?? 'The download failed');
    }
    return null;
  }
}
