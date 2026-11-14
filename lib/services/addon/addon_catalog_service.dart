import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/addon/addon_ids.dart';
import 'package:mornye/services/addon/addon_track_cache.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';

final _log = AppLogger('AddonCatalog');

/// Search, detail and catalog responses for the Eclipse add-on.
///
/// Everything here reads the same sources the app does: the installed metadata
/// providers for the streaming catalogue, and the library database for files
/// that are already on the device. No provider is called directly, so the
/// add-on shows the catalogue the app shows.
class AddonCatalogService {
  AddonCatalogService(this._ref);

  static const String homeCatalogId = 'home';
  static const String libraryCatalogId = 'library';

  static const int searchLimit = 40;
  static const int catalogPageSize = 40;

  final Ref _ref;

  /// The catalog rows declared in the manifest.
  static List<Map<String, dynamic>> catalogDescriptors() => const [
    {'id': homeCatalogId, 'type': 'track', 'name': 'Mornye · Home'},
    {'id': libraryCatalogId, 'type': 'track', 'name': 'Mornye · Library'},
  ];

  // --- Search -------------------------------------------------------------

  Future<Map<String, dynamic>> search(String query) async {
    final text = query.trim();
    if (text.isEmpty) {
      return const {'tracks': [], 'albums': [], 'artists': [], 'playlists': []};
    }

    final tracks = <Map<String, dynamic>>[];
    final albums = <Map<String, dynamic>>[];
    final artists = <Map<String, dynamic>>[];
    final playlists = <Map<String, dynamic>>[];

    try {
      final results = await PlatformBridge.searchTracksWithMetadataProviders(
        text,
        limit: searchLimit,
      );
      for (final entry in results) {
        final itemType = (entry['item_type'] ?? '').toString().toLowerCase();
        final source = (entry['source'] ?? entry['provider_id'] ?? '')
            .toString()
            .trim();
        switch (itemType) {
          case 'album':
            final album = _albumFromMap(entry, source);
            if (album != null) albums.add(album);
          case 'artist':
            final artist = _artistFromMap(entry, source);
            if (artist != null) artists.add(artist);
          case 'playlist':
            final playlist = _playlistFromMap(entry, source);
            if (playlist != null) playlists.add(playlist);
          default:
            final track = _trackFromMap(entry, source);
            if (track != null) tracks.add(track);
        }
      }
    } catch (error) {
      _log.w('Provider search failed for "$text": $error');
    }

    // Files already on the device come first: they play instantly.
    for (final hit in await _librarySearch(text)) {
      tracks.insert(0, hit);
    }

    return {
      'tracks': tracks,
      'albums': albums,
      'artists': artists,
      'playlists': playlists,
    };
  }

  Future<List<Map<String, dynamic>>> _librarySearch(String query) async {
    try {
      final hits = await LibraryDatabase.instance.searchLibrary(
        query: query,
        kind: LibrarySearchKind.songs,
        includeLocal: true,
        limit: 10,
      );
      return [
        for (final hit in hits)
          {
            'id': AddonIds.library(hit.id),
            'title': hit.title,
            'artist': hit.artist,
            if (hit.cover != null && hit.cover!.isNotEmpty)
              'artworkURL': hit.cover,
          },
      ];
    } catch (error) {
      _log.d('Library search failed: $error');
      return const [];
    }
  }

  // --- Catalog rows -------------------------------------------------------

  Future<Map<String, dynamic>> catalogRow(String id, int skip) async {
    switch (id) {
      case libraryCatalogId:
        return {'items': await _libraryRow(skip)};
      case homeCatalogId:
      default:
        return {'items': await _homeRow(skip)};
    }
  }

  Future<List<Map<String, dynamic>>> _homeRow(int skip) async {
    final extensionId = _homeFeedExtensionId();
    if (extensionId == null) return const [];
    final sections = await readExtensionHomeFeed(extensionId);
    if (sections == null) return const [];
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final section in sections) {
      for (final item in section.items) {
        final mapped = _trackFromExploreItem(item);
        if (mapped == null) continue;
        if (!seen.add(mapped['id'] as String)) continue;
        items.add(mapped);
      }
    }
    return items.skip(skip).take(catalogPageSize).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _libraryRow(int skip) async {
    final rows = await LibraryDatabase.instance.getPage(
      limit: catalogPageSize,
      offset: skip,
    );
    return [
      for (final row in rows)
        if (_trackFromLibraryRow(row) case final track?) track,
    ];
  }

  // --- Detail -------------------------------------------------------------

  Future<Map<String, dynamic>?> album(String id) async {
    final ref = AddonIds.parse(id);
    if (ref == null || !ref.isAlbum) return null;
    try {
      final payload = await PlatformBridge.getProviderMetadata(
        ref.source,
        'album',
        ref.value,
      );
      final info = _firstMap([
        payload['album_info'],
        payload['album'],
        payload,
      ]);
      final tracks = _tracksFromList(payload['track_list'], ref.source);
      final poster = _firstHttpUrl([
        _stringOf(info, ['cover_url', 'cover', 'image']),
        if (tracks.isNotEmpty) tracks.first.coverUrl,
      ]);
      return {
        'id': id,
        'title': _stringOf(info, ['name', 'title']) ?? ref.value,
        'artist': _stringOf(info, ['artists', 'artist', 'album_artist']) ?? '',
        if (poster != null) 'artworkURL': poster,
        if (_yearOf(_stringOf(info, ['release_date'])) case final year?)
          'year': year,
        if (_stringOf(info, ['description']) case final description?)
          'description': description,
        'trackCount': tracks.length,
        'tracks': [
          for (final track in tracks)
            _trackJson(track, ref.source, albumArtwork: poster),
        ],
      };
    } catch (error) {
      _log.w('Album $id failed: $error');
      return null;
    }
  }

  Future<Map<String, dynamic>?> artist(String id) async {
    final ref = AddonIds.parse(id);
    if (ref == null || !ref.isArtist) return null;
    try {
      final payload = await PlatformBridge.getProviderMetadata(
        ref.source,
        'artist',
        ref.value,
      );
      final info = _firstMap([
        payload['artist_info'],
        payload['artist'],
        payload,
      ]);
      final topTracks = _tracksFromList(payload['top_tracks'], ref.source);
      final genres = _genres(info);
      final albums = <Map<String, dynamic>>[];
      for (final entry in _mapList(payload['albums'])) {
        final album = _albumFromMap(entry, ref.source);
        if (album != null) albums.add(album);
      }
      final poster = _firstHttpUrl([
        _stringOf(info, ['images', 'cover_url', 'header_image']),
        if (topTracks.isNotEmpty) topTracks.first.coverUrl,
      ]);
      return {
        'id': id,
        'name': _stringOf(info, ['name']) ?? ref.value,
        if (poster != null) 'artworkURL': poster,
        if (_stringOf(info, ['bio', 'description']) case final bio?) 'bio': bio,
        if (genres.isNotEmpty) 'genres': genres,
        'topTracks': [
          for (final track in topTracks)
            _trackJson(track, ref.source, albumArtwork: poster),
        ],
        'albums': albums,
      };
    } catch (error) {
      _log.w('Artist $id failed: $error');
      return null;
    }
  }

  Future<Map<String, dynamic>?> playlist(String id) async {
    final ref = AddonIds.parse(id);
    if (ref == null || !ref.isPlaylist) return null;
    try {
      final payload = await PlatformBridge.getProviderMetadata(
        ref.source,
        'playlist',
        ref.value,
      );
      final info = _firstMap([
        payload['playlist_info'],
        payload['playlist'],
        payload,
      ]);
      final tracks = _tracksFromList(
        payload['track_list'] ?? payload['tracks'],
        ref.source,
      );
      final owner = _firstMap([info['owner']]);
      final poster = _firstHttpUrl([
        _stringOf(info, ['images', 'cover_url', 'cover']),
        _stringOf(owner, ['images', 'cover_url']),
        if (tracks.isNotEmpty) tracks.first.coverUrl,
      ]);
      final creator =
          _stringOf(info, ['owner_name']) ??
          _stringOf(owner, ['name']) ??
          _stringOf(info, ['creator']);
      return {
        'id': id,
        'title': _stringOf(info, ['name', 'title']) ?? ref.value,
        if (_stringOf(info, ['description']) case final description?)
          'description': description,
        if (poster != null) 'artworkURL': poster,
        if (creator != null) 'creator': creator,
        'tracks': [
          for (final track in tracks)
            _trackJson(track, ref.source, albumArtwork: poster),
        ],
      };
    } catch (error) {
      _log.w('Playlist $id failed: $error');
      return null;
    }
  }

  // --- Mapping ------------------------------------------------------------

  Map<String, dynamic>? _trackFromMap(
    Map<String, dynamic> data,
    String source,
  ) {
    final track = Track.fromBackendMap(data, source: source);
    if (track.id.trim().isEmpty || track.name.trim().isEmpty) return null;
    if (source.isNotEmpty) {
      AddonTrackCache.instance.put(track, source: source);
    }
    return _trackJson(track, source);
  }

  Map<String, dynamic>? _trackFromExploreItem(ExploreItem item) {
    final source = (item.providerId ?? '').trim();
    if (source.isEmpty || item.id.trim().isEmpty) return null;
    if (item.type != 'track') return null;
    final track = Track(
      id: item.id,
      name: item.name,
      artistName: item.artists,
      albumName: item.albumName ?? '',
      albumId: item.albumId,
      duration: item.durationMs ~/ 1000,
      releaseDate: item.releaseDate,
      coverUrl: item.coverUrl,
      source: source,
      explicit: item.explicit,
    );
    AddonTrackCache.instance.put(track, source: source);
    return _trackJson(track, source);
  }

  Map<String, dynamic>? _trackFromLibraryRow(Map<String, dynamic> row) {
    final id = _rowText(row, 'id');
    final title = _rowText(row, 'trackName');
    if (id.isEmpty || title.isEmpty) return null;
    return {
      'id': AddonIds.library(id),
      'title': title,
      'artist': _rowText(row, 'artistName'),
      if (_rowText(row, 'albumName') case final album when album.isNotEmpty)
        'album': album,
      if (_durationOf(row) case final duration when duration > 0)
        'duration': duration,
    };
  }

  Map<String, dynamic> _trackJson(
    Track track,
    String source, {
    String? albumArtwork,
  }) {
    final artwork = _firstHttpUrl([track.coverUrl, albumArtwork]);
    return {
      'id': AddonIds.track(source, track.id),
      'title': track.name,
      'artist': track.artistName,
      if (track.albumName.trim().isNotEmpty) 'album': track.albumName,
      if (track.duration > 0) 'duration': track.duration,
      if (artwork != null) 'artworkURL': artwork,
      if ((track.isrc ?? '').trim().isNotEmpty) 'isrc': track.isrc!.trim(),
    };
  }

  Map<String, dynamic>? _albumFromMap(
    Map<String, dynamic> data,
    String source,
  ) {
    final id = (data['id'] ?? '').toString().trim();
    if (id.isEmpty || source.isEmpty) return null;
    final artwork = _firstHttpUrl([
      (data['cover_url'] ?? data['cover'] ?? data['image'] ?? '').toString(),
    ]);
    final count = data['total_tracks'];
    return {
      'id': AddonIds.album(source, id),
      'title': (data['name'] ?? data['title'] ?? '').toString(),
      'artist': (data['artists'] ?? data['artist'] ?? '').toString(),
      if (artwork != null) 'artworkURL': artwork,
      if (count is num && count > 0) 'trackCount': count.toInt(),
      if (_yearOf((data['release_date'] ?? '').toString()) case final year?)
        'year': year,
    };
  }

  Map<String, dynamic>? _artistFromMap(
    Map<String, dynamic> data,
    String source,
  ) {
    final id = (data['id'] ?? '').toString().trim();
    if (id.isEmpty || source.isEmpty) return null;
    final artwork = _firstHttpUrl([
      (data['cover_url'] ?? data['image'] ?? data['images'] ?? '').toString(),
    ]);
    return {
      'id': AddonIds.artist(source, id),
      'name': (data['name'] ?? data['title'] ?? '').toString(),
      if (artwork != null) 'artworkURL': artwork,
    };
  }

  Map<String, dynamic>? _playlistFromMap(
    Map<String, dynamic> data,
    String source,
  ) {
    final id = (data['id'] ?? '').toString().trim();
    if (id.isEmpty || source.isEmpty) return null;
    final artwork = _firstHttpUrl([
      (data['cover_url'] ?? data['image'] ?? '').toString(),
    ]);
    final count = data['total_tracks'];
    final creator = (data['owner_name'] ?? data['creator'] ?? '').toString();
    return {
      'id': AddonIds.playlist(source, id),
      'title': (data['name'] ?? data['title'] ?? '').toString(),
      if (creator.isNotEmpty) 'creator': creator,
      if (artwork != null) 'artworkURL': artwork,
      if (count is num && count > 0) 'trackCount': count.toInt(),
    };
  }

  String? _homeFeedExtensionId() {
    final settings = _ref.read(settingsProvider);
    final extensions = _ref
        .read(extensionProvider)
        .extensions
        .where((extension) => extension.enabled && extension.hasHomeFeed)
        .toList(growable: false);
    if (extensions.isEmpty) return null;
    final preferred = settings.homeFeedProvider;
    if (preferred == AppSettings.homeFeedProviderOff) return null;
    if (preferred != null && preferred.isNotEmpty) {
      for (final extension in extensions) {
        if (extension.id == preferred) return extension.id;
      }
      return null;
    }
    return extensions.first.id;
  }

  List<Track> _tracksFromList(Object? value, String source) {
    final tracks = <Track>[];
    for (final entry in _mapList(value)) {
      final track = Track.fromBackendMap(entry, source: source);
      if (track.id.trim().isEmpty || track.name.trim().isEmpty) continue;
      if (source.isNotEmpty) {
        AddonTrackCache.instance.put(track, source: source);
      }
      tracks.add(track);
    }
    return tracks;
  }

  static List<Map<String, dynamic>> _mapList(Object? value) {
    if (value is! List) return const [];
    return [
      for (final entry in value)
        if (entry is Map) Map<String, dynamic>.from(entry),
    ];
  }

  static Map<String, dynamic> _firstMap(List<Object?> candidates) {
    for (final candidate in candidates) {
      if (candidate is Map) return Map<String, dynamic>.from(candidate);
    }
    return const {};
  }

  static String? _stringOf(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num) return value.toString();
    }
    return null;
  }

  static List<String> _genres(Map<String, dynamic> info) {
    final value = info['genres'];
    if (value is List) {
      return [
        for (final genre in value)
          if (genre is String && genre.trim().isNotEmpty) genre.trim(),
      ];
    }
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(',')
          .map((genre) => genre.trim())
          .where((genre) => genre.isNotEmpty)
          .toList();
    }
    return const [];
  }

  static String? _firstHttpUrl(List<String?> candidates) {
    for (final candidate in candidates) {
      final url = normalizeRemoteHttpUrl(candidate);
      if (url != null) return url;
    }
    return null;
  }

  static String? _yearOf(String? date) {
    final value = (date ?? '').trim();
    if (value.length < 4) return null;
    final year = int.tryParse(value.substring(0, 4));
    return year == null || year < 1800 ? null : year.toString();
  }

  static String _rowText(Map<String, dynamic> row, String key) =>
      (row[key] ?? '').toString().trim();

  static int _durationOf(Map<String, dynamic> row) {
    final value = row['duration'];
    if (value is num) return value.toInt();
    return int.tryParse((value ?? '').toString()) ?? 0;
  }
}
