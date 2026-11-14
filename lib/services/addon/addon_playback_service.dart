import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/addon/addon_ids.dart';
import 'package:mornye/services/addon/addon_settings.dart';
import 'package:mornye/services/addon/addon_track_cache.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = AppLogger('AddonPlayback');

/// A playback request the add-on cannot serve, reported to Eclipse as an error.
class AddonPlaybackException implements Exception {
  const AddonPlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Playback for the Eclipse add-on.
///
/// Eclipse asks for one URL per track, so the add-on picks the source: the
/// copy in the library when there is one, otherwise the download source
/// configured in Settings → Eclipse add-on (or the app's default service).
/// The track is downloaded into the library and the file is served from
/// there, so a replay is instant and needs no network.
class AddonPlaybackService {
  AddonPlaybackService(this._ref);

  /// How long a play request waits for the library download to finish when the
  /// partially written file could not be found.
  static const Duration downloadTimeout = Duration(minutes: 4);

  static const String _stagingPrefix = '.mornye-download-';

  final Ref _ref;

  /// What Eclipse needs for `/stream/{id}`: a URL it can play, plus the format
  /// when the file is already on disk and the answer is certain.
  Future<Map<String, dynamic>> streamInfo({
    required String id,
    required String baseUrl,
  }) async {
    final ref = AddonIds.parse(id);
    if (ref == null) {
      throw const AddonPlaybackException('Unknown track id');
    }

    final file = await _readyFile(ref);
    final url = '$baseUrl/play/${Uri.encodeComponent(id)}';
    final format = file == null ? null : _formatOf(file.path);
    return {
      'url': url,
      if (format != null) 'format': format,
      'quality': file == null ? 'auto' : 'library',
    };
  }

  /// The file Eclipse should read for a `/play` request: the library copy when
  /// there is one, otherwise a fresh download.
  Future<AddonPlayHandle> beginPlay(String id) async {
    final ref = AddonIds.parse(id);
    if (ref == null) {
      throw const AddonPlaybackException('Unknown track id');
    }

    if (ref.isLibrary) {
      final row = await LibraryDatabase.instance.getById(ref.value);
      final file = await _fileForPath((row?['filePath'] ?? '').toString());
      if (file == null) {
        throw const AddonPlaybackException(
          'The library file for this track is missing',
        );
      }
      return AddonPlayHandle.ready(this, file);
    }

    if (!ref.isTrack) {
      throw const AddonPlaybackException(
        'Open a track from the album, artist or playlist to play it',
      );
    }

    final track = await AddonTrackCache.instance.resolve(ref.source, ref.value);
    if (track == null) {
      throw const AddonPlaybackException(
        'This track is no longer available from its provider',
      );
    }

    final existing = await _libraryFile(track);
    if (existing != null) return AddonPlayHandle.ready(this, existing);

    return _enqueue(track);
  }

  /// The file when it is already on disk, for the fast `/stream` answer.
  Future<File?> _readyFile(AddonIdRef ref) async {
    if (ref.isLibrary) {
      final row = await LibraryDatabase.instance.getById(ref.value);
      return _fileForPath((row?['filePath'] ?? '').toString());
    }
    if (!ref.isTrack) return null;
    final track = await AddonTrackCache.instance.resolve(ref.source, ref.value);
    if (track == null) return null;
    return _libraryFile(track);
  }

  Future<AddonPlayHandle> _enqueue(Track track) async {
    final service = _resolveSource();
    if (service.isEmpty) {
      throw const AddonPlaybackException(
        'No download source is available. Enable a download extension in '
        'Mornye, then try again.',
      );
    }

    final queue = _ref.read(downloadQueueProvider);
    if (queue.isPaused) {
      throw const AddonPlaybackException(
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
      return AddonPlayHandle.queued(this, item.id, track, null);
    }

    final knownStaging = await _stagingDirectories();
    _log.i('Queueing ${track.name} from $service');
    final itemId = notifier.addToQueue(track, service);
    return AddonPlayHandle.queued(this, itemId, track, knownStaging);
  }

  /// The download source chosen on the add-on page, else the app's default.
  String _resolveSource() {
    final settings = _ref.read(settingsProvider);
    final extensionState = _ref.read(extensionProvider);
    final chosen = _ref.read(addonSettingsProvider).source.trim();
    final requested = chosen.isNotEmpty ? chosen : settings.defaultService;
    // An empty request, or a source that was since disabled, resolves to the
    // first enabled download provider.
    return resolveEffectiveDownloadService(requested, extensionState);
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

  static String? _formatOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1) return null;
    final extension = path.substring(dot + 1).toLowerCase();
    return switch (extension) {
      'mp3' => 'mp3',
      'flac' => 'flac',
      'm4a' || 'mp4' || 'alac' => 'm4a',
      'aac' => 'aac',
      'ogg' || 'oga' || 'opus' => 'ogg',
      _ => null,
    };
  }
}

/// One in-flight playback request: either a finished file, or a download the
/// caller can follow while it writes.
class AddonPlayHandle {
  AddonPlayHandle._({
    required this.service,
    this.readyFile,
    this.itemId,
    this.track,
    this.knownStaging,
  });

  factory AddonPlayHandle.ready(AddonPlaybackService service, File file) =>
      AddonPlayHandle._(service: service, readyFile: file);

  factory AddonPlayHandle.queued(
    AddonPlaybackService service,
    String itemId,
    Track track,
    Set<String>? knownStaging,
  ) => AddonPlayHandle._(
    service: service,
    itemId: itemId,
    track: track,
    knownStaging: knownStaging,
  );

  final AddonPlaybackService service;

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
      throw const AddonPlaybackException('Nothing to download');
    }
    final deadline = DateTime.now().add(AddonPlaybackService.downloadTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final file = await _poll();
      if (file != null) return file;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    _log.w('Timed out waiting for ${track?.name ?? itemId}');
    throw const AddonPlaybackException(
      'The download did not finish in time. Check the queue in Mornye, then try again.',
    );
  }

  /// Follows the download without blocking: returns the finished file, or null
  /// while it is still running.
  Future<File?> nextSource() async {
    if (_complete) return _finalFile;
    return _poll();
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
      throw AddonPlaybackException(
        item.error ?? 'The source skipped this track',
      );
    }
    if (item.status == DownloadStatus.failed) {
      throw AddonPlaybackException(item.error ?? 'The download failed');
    }
    return null;
  }
}
