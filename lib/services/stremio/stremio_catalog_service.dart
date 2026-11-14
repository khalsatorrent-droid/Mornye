import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/stremio/stremio_ids.dart';
import 'package:mornye/services/stremio/stremio_track_cache.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';

final _log = AppLogger('StremioCatalog');

/// Catalog and metadata responses for the Stremio add-on.
///
/// Everything here reads the same sources the app does: the installed metadata
/// providers for the streaming catalogue, and the library database for files
/// that are already on the device. No provider is called directly, so the
/// add-on shows the catalogue the app shows.
class StremioCatalogService {
  StremioCatalogService(this._ref);

  static const String homeCatalogId = 'mornye-home';
  static const String searchCatalogId = 'mornye-search';
  static const String libraryCatalogId = 'mornye-library';
  static const String librarySearchCatalogId = 'mornye-library-search';

  static const int pageSize = 100;

  final Ref _ref;

  /// Every catalog the manifest advertises, in the order Stremio shows them.
  static List<Map<String, dynamic>> catalogDescriptors() => const [
    {
      'type': 'movie',
      'id': homeCatalogId,
      'name': 'Mornye · Home',
      'extra': [
        {'name': 'skip', 'isRequired': false},
      ],
    },
    {
      'type': 'movie',
      'id': searchCatalogId,
      'name': 'Mornye · Search',
      'extra': [
        {'name': 'search', 'isRequired': true},
      ],
    },
    {
      'type': 'movie',
      'id': libraryCatalogId,
      'name': 'Mornye · Library',
      'extra': [
        {'name': 'skip', 'isRequired': false},
      ],
    },
    {
      'type': 'movie',
      'id': librarySearchCatalogId,
      'name': 'Mornye · Library Search',
      'extra': [
        {'name': 'search', 'isRequired': true},
      ],
    },
  ];

  Future<Map<String, dynamic>> catalog({
    required String catalogId,
    required String baseUrl,
    String? search,
    int skip = 0,
  }) async {
    final query = (search ?? '').trim();
    final offset = skip < 0 ? 0 : skip;
    switch (catalogId) {
      case searchCatalogId:
        if (query.isEmpty) return const {'metas': []};
        return {'metas': await _searchMetas(query, offset, baseUrl)};
      case librarySearchCatalogId:
        if (query.isEmpty) return const {'metas': []};
        return {'metas': await _librarySearchMetas(query, offset, baseUrl)};
      case libraryCatalogId:
        return {'metas': await _libraryPageMetas(offset, baseUrl)};
      case homeCatalogId:
      default:
        return {'metas': await _homeMetas(offset, baseUrl)};
    }
  }

  /// One item's detail page. Returns null when the provider cannot describe it.
  Future<Map<String, dynamic>?> meta({
    required String id,
    required String baseUrl,
  }) async {
    final ref = StremioIds.parse(id);
    if (ref == null) return null;
    try {
      if (ref.isLibrary) return _libraryMeta(ref.value, baseUrl);
      if (ref.isTrack) return _trackMeta(ref.source, ref.value, baseUrl);
      if (ref.isAlbum) return _collectionMeta(ref, 'album', baseUrl);
      if (ref.isPlaylist) return _collectionMeta(ref, 'playlist', baseUrl);
      if (ref.isArtist) return _collectionMeta(ref, 'artist', baseUrl);
    } catch (error) {
      _log.w('Meta lookup failed for $id: $error');
    }
    return null;
  }

  // --- Catalogues ---------------------------------------------------------

  Future<List<Map<String, dynamic>>> _searchMetas(
    String query,
    int skip,
    String baseUrl,
  ) async {
    final limit = (skip + pageSize).clamp(pageSize, 400).toInt();
    final results = await PlatformBridge.searchTracksWithMetadataProviders(
      query,
      limit: limit,
    );
    final metas = <Map<String, dynamic>>[];
    for (final entry in results.skip(skip)) {
      if (metas.length >= pageSize) break;
      final meta = _metaFromProviderMap(entry, baseUrl);
      if (meta != null) metas.add(meta);
    }
    return metas;
  }

  Future<List<Map<String, dynamic>>> _homeMetas(
    int skip,
    String baseUrl,
  ) async {
    final extensionId = _homeFeedExtensionId();
    if (extensionId == null) return const [];
    final sections = await readExtensionHomeFeed(extensionId);
    if (sections == null) return const [];
    final metas = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final section in sections) {
      for (final item in section.items) {
        final meta = _metaFromExploreItem(item, baseUrl);
        if (meta == null) continue;
        if (!seen.add(meta['id'] as String)) continue;
        metas.add(meta);
      }
    }
    return metas.skip(skip).take(pageSize).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _libraryPageMetas(
    int skip,
    String baseUrl,
  ) async {
    final rows = await LibraryDatabase.instance.getPage(
      limit: pageSize,
      offset: skip,
    );
    return [
      for (final row in rows)
        if (_libraryPreview(row, baseUrl) case final preview?) preview,
    ];
  }

  Future<List<Map<String, dynamic>>> _librarySearchMetas(
    String query,
    int skip,
    String baseUrl,
  ) async {
    final hits = await LibraryDatabase.instance.searchLibrary(
      query: query,
      kind: LibrarySearchKind.songs,
      includeLocal: true,
      limit: pageSize,
      offset: skip,
    );
    return [
      for (final hit in hits)
        {
          'id': StremioIds.library(hit.id),
          'type': 'movie',
          'name': hit.title,
          'poster': hit.cover == null || hit.cover!.isEmpty
              ? null
              : '$baseUrl/cover/${Uri.encodeComponent(hit.id)}',
          'posterShape': 'square',
          'description': hit.artist,
        }..removeWhere((_, value) => value == null),
    ];
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

  // --- Meta ---------------------------------------------------------------

  Future<Map<String, dynamic>?> _trackMeta(
    String source,
    String trackId,
    String baseUrl,
  ) async {
    final track = await StremioTrackCache.instance.resolve(source, trackId);
    if (track == null) return null;
    return {'meta': _trackPreview(track, source, baseUrl)};
  }

  /// Albums, playlists and artists all list tracks; only the header differs.
  Future<Map<String, dynamic>?> _collectionMeta(
    StremioIdRef ref,
    String resourceType,
    String baseUrl,
  ) async {
    final source = ref.source;
    final id = ref.value;
    if (source.isEmpty || id.isEmpty) return null;
    final payload = await PlatformBridge.getProviderMetadata(
      source,
      resourceType,
      id,
    );
    final info = _firstMap([
      payload['album_info'],
      payload['playlist'],
      payload['artist'],
      payload,
    ]);
    final trackMaps = _trackListFromPayload(payload);
    final tracks = <Track>[];
    for (final map in trackMaps) {
      final track = Track.fromBackendMap(map, source: source);
      if (track.id.trim().isEmpty) continue;
      StremioTrackCache.instance.put(track, source: source);
      tracks.add(track);
    }
    final name = _stringOf(info, ['name', 'title']) ?? id;
    final poster = _firstHttpUrl([
      _stringOf(info, ['cover_url', 'cover', 'image']),
      if (tracks.isNotEmpty) tracks.first.coverUrl,
    ]);
    return {
      'meta': {
        'id': StremioIds.encodePair(ref.kind, source, id),
        'type': 'movie',
        'name': name,
        'poster': poster,
        'background': poster,
        'posterShape': 'square',
        'description':
            _stringOf(info, ['description', 'bio']) ??
            _stringOf(info, ['artists', 'artist']) ??
            '',
        'releaseInfo': _yearOf(_stringOf(info, ['release_date'])),
        if (tracks.isNotEmpty)
          'videos': [
            for (var index = 0; index < tracks.length; index++)
              {
                'id': StremioIds.track(source, tracks[index].id),
                'title': '${index + 1}. ${tracks[index].name}',
                'season': 1,
                'episode': index + 1,
                'thumbnail': _firstHttpUrl([tracks[index].coverUrl]),
                'overview': tracks[index].artistName,
              },
          ],
      },
    };
  }

  Future<Map<String, dynamic>?> _libraryMeta(
    String rowId,
    String baseUrl,
  ) async {
    final row = await LibraryDatabase.instance.getById(rowId);
    if (row == null) return null;
    final preview = _libraryPreview(row, baseUrl);
    if (preview == null) return null;
    return {
      'meta': {
        ...preview,
        'description': [
          _rowText(row, 'artistName'),
          _rowText(row, 'albumName'),
        ].where((value) => value.isNotEmpty).join(' · '),
      },
    };
  }

  // --- Mapping ------------------------------------------------------------

  Map<String, dynamic>? _metaFromProviderMap(
    Map<String, dynamic> data,
    String baseUrl,
  ) {
    final source = (data['source'] ?? data['provider_id'] ?? '').toString();
    final itemType = (data['item_type'] ?? '').toString().toLowerCase();
    if (itemType == 'album' || itemType == 'playlist' || itemType == 'artist') {
      final id = (data['id'] ?? '').toString();
      if (source.isEmpty || id.isEmpty) return null;
      return {
        'id': itemType == 'album'
            ? StremioIds.album(source, id)
            : itemType == 'playlist'
            ? StremioIds.playlist(source, id)
            : StremioIds.artist(source, id),
        'type': 'movie',
        'name': (data['name'] ?? '').toString(),
        'poster': _firstHttpUrl([
          (data['cover_url'] ?? data['cover'] ?? '').toString(),
        ]),
        'posterShape': 'square',
        'description': [
          (data['artists'] ?? data['artist'] ?? '').toString(),
          _collectionLabel(itemType),
        ].where((value) => value.isNotEmpty).join(' · '),
      };
    }
    final track = Track.fromBackendMap(data, source: source);
    if (track.id.trim().isEmpty || track.name.trim().isEmpty) return null;
    if (source.isNotEmpty) {
      StremioTrackCache.instance.put(track, source: source);
    }
    return _trackPreview(track, source, baseUrl);
  }

  Map<String, dynamic>? _metaFromExploreItem(ExploreItem item, String baseUrl) {
    final source = (item.providerId ?? '').trim();
    if (source.isEmpty || item.id.trim().isEmpty) return null;
    switch (item.type) {
      case 'album':
        return {
          'id': StremioIds.album(source, item.id),
          'type': 'movie',
          'name': item.name,
          'poster': _firstHttpUrl([item.coverUrl, item.featuredCoverUrl]),
          'posterShape': 'square',
          'description': [
            item.artists,
            'Album',
          ].where((value) => value.isNotEmpty).join(' · '),
        };
      case 'playlist':
        return {
          'id': StremioIds.playlist(source, item.id),
          'type': 'movie',
          'name': item.name,
          'poster': _firstHttpUrl([item.coverUrl, item.featuredCoverUrl]),
          'posterShape': 'square',
          'description': [
            item.artists,
            'Playlist',
          ].where((value) => value.isNotEmpty).join(' · '),
        };
      case 'artist':
        return {
          'id': StremioIds.artist(source, item.id),
          'type': 'movie',
          'name': item.name,
          'poster': _firstHttpUrl([item.coverUrl, item.featuredCoverUrl]),
          'posterShape': 'square',
          'description': 'Artist',
        };
      case 'track':
      default:
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
        StremioTrackCache.instance.put(track, source: source);
        return _trackPreview(track, source, baseUrl);
    }
  }

  Map<String, dynamic> _trackPreview(
    Track track,
    String source,
    String baseUrl,
  ) {
    final poster = _firstHttpUrl([track.coverUrl]);
    return {
      'id': StremioIds.track(source, track.id),
      'type': 'movie',
      'name': track.name,
      'poster': poster,
      'posterShape': 'square',
      'description': [
        track.artistName,
        track.albumName,
      ].where((value) => value.trim().isNotEmpty).join(' · '),
      'releaseInfo': _yearOf(track.releaseDate),
    }..removeWhere((_, value) => value == null || value == '');
  }

  Map<String, dynamic>? _libraryPreview(
    Map<String, dynamic> row,
    String baseUrl,
  ) {
    final id = _rowText(row, 'id');
    final name = _rowText(row, 'trackName');
    if (id.isEmpty || name.isEmpty) return null;
    return {
      'id': StremioIds.library(id),
      'type': 'movie',
      'name': name,
      'poster': '$baseUrl/cover/${Uri.encodeComponent(id)}',
      'posterShape': 'square',
      'description': _rowText(row, 'artistName'),
    };
  }

  // --- Small helpers ------------------------------------------------------

  static String _collectionLabel(String itemType) => switch (itemType) {
    'album' => 'Album',
    'playlist' => 'Playlist',
    'artist' => 'Artist',
    _ => '',
  };

  static Map<String, dynamic> _firstMap(List<Object?> candidates) {
    for (final candidate in candidates) {
      if (candidate is Map) return Map<String, dynamic>.from(candidate);
    }
    return const {};
  }

  static List<Map<String, dynamic>> _trackListFromPayload(
    Map<String, dynamic> payload,
  ) {
    for (final key in ['track_list', 'tracks', 'items', 'top_tracks']) {
      final value = payload[key];
      if (value is List) {
        return [
          for (final entry in value)
            if (entry is Map) Map<String, dynamic>.from(entry),
        ];
      }
    }
    return const [];
  }

  static String? _stringOf(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is List && value.isNotEmpty) {
        final joined = value
            .whereType<Object>()
            .map((e) => e.toString())
            .join(', ');
        if (joined.trim().isNotEmpty) return joined.trim();
      }
    }
    return null;
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
}
