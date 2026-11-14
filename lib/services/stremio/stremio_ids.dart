import 'dart:convert';

/// Item ids handed to Stremio, and the reverse mapping back to Mornye data.
///
/// Stremio stores ids for "continue watching", so they must be stable across
/// restarts. Every id is `mny:<kind>:<base64url part>[.<base64url part>]`:
///
/// * `mny:t:<source>.<trackId>` – a catalogue track
/// * `mny:a:<source>.<albumId>` – an album
/// * `mny:r:<source>.<artistId>` – an artist
/// * `mny:p:<source>.<playlistId>` – a playlist
/// * `mny:l:<libraryRowId>` – a file already in the library
abstract final class StremioIds {
  static const String prefix = 'mny:';

  static const String trackKind = 't';
  static const String albumKind = 'a';
  static const String artistKind = 'r';
  static const String playlistKind = 'p';
  static const String libraryKind = 'l';

  static const String _separator = '.';

  static String encodePair(String kind, String first, String second) =>
      '$prefix$kind:${_encode(first)}$_separator${_encode(second)}';

  static String encodeSingle(String kind, String value) =>
      '$prefix$kind:${_encode(value)}';

  static String track(String source, String trackId) =>
      encodePair(trackKind, source, trackId);

  static String album(String source, String albumId) =>
      encodePair(albumKind, source, albumId);

  static String artist(String source, String artistId) =>
      encodePair(artistKind, source, artistId);

  static String playlist(String source, String playlistId) =>
      encodePair(playlistKind, source, playlistId);

  static String library(String rowId) => encodeSingle(libraryKind, rowId);

  static StremioIdRef? parse(String id) {
    final trimmed = id.trim();
    if (!trimmed.startsWith(prefix)) return null;
    final body = trimmed.substring(prefix.length);
    final colon = body.indexOf(':');
    if (colon <= 0 || colon == body.length - 1) return null;
    final kind = body.substring(0, colon);
    final payload = body.substring(colon + 1);
    final parts = <String>[];
    for (final part in payload.split(_separator)) {
      final decoded = _decode(part);
      if (decoded == null) return null;
      parts.add(decoded);
    }
    if (parts.isEmpty) return null;
    return StremioIdRef(kind: kind, parts: List.unmodifiable(parts));
  }

  static String _encode(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  static String? _decode(String value) {
    if (value.isEmpty) return null;
    final padded = value.padRight((value.length + 3) ~/ 4 * 4, '=');
    try {
      return utf8.decode(base64Url.decode(padded));
    } catch (_) {
      return null;
    }
  }
}

class StremioIdRef {
  const StremioIdRef({required this.kind, required this.parts});

  final String kind;
  final List<String> parts;

  String get source => parts.length > 1 ? parts[0] : '';
  String get value => parts.length > 1 ? parts[1] : parts[0];

  bool get isTrack => kind == StremioIds.trackKind;
  bool get isAlbum => kind == StremioIds.albumKind;
  bool get isArtist => kind == StremioIds.artistKind;
  bool get isPlaylist => kind == StremioIds.playlistKind;
  bool get isLibrary => kind == StremioIds.libraryKind;
}
