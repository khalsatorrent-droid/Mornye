import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('StremioTracks');

/// Remembers the catalogue tracks this add-on has shown, so a stream request
/// can name the track without a second provider round trip.
///
/// A miss is not an error: the track is looked up from its metadata provider
/// instead, which is why ids carry the provider and track id.
class StremioTrackCache {
  StremioTrackCache();

  static final StremioTrackCache instance = StremioTrackCache();

  static const int _maxEntries = 600;

  final Map<String, Track> _tracks = <String, Track>{};

  static String _key(String source, String trackId) =>
      '${source.trim().toLowerCase()}|${trackId.trim()}';

  void put(Track track, {String? source}) {
    final trackSource = (source ?? track.source ?? '').trim();
    if (trackSource.isEmpty || track.id.trim().isEmpty) return;
    final key = _key(trackSource, track.id);
    _tracks.remove(key);
    _tracks[key] = track;
    while (_tracks.length > _maxEntries) {
      _tracks.remove(_tracks.keys.first);
    }
  }

  Track? peek(String source, String trackId) => _tracks[_key(source, trackId)];

  /// The cached track, else the metadata provider's own record for it.
  Future<Track?> resolve(String source, String trackId) async {
    final cached = peek(source, trackId);
    if (cached != null) return cached;
    if (source.trim().isEmpty || trackId.trim().isEmpty) return null;
    try {
      final payload = await PlatformBridge.getProviderMetadata(
        source,
        'track',
        trackId,
      );
      final data = _unwrapTrack(payload);
      if (data.isEmpty) return null;
      final track = Track.fromBackendMap({
        ...data,
        if ((data['id'] ?? '').toString().isEmpty) 'id': trackId,
      }, source: source);
      put(track, source: source);
      return track;
    } catch (error) {
      _log.w('Could not resolve $source/$trackId: $error');
      return null;
    }
  }

  static Map<String, dynamic> _unwrapTrack(Map<String, dynamic> payload) {
    final track = payload['track'];
    if (track is Map) return Map<String, dynamic>.from(track);
    return payload;
  }
}
