import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/stremio/stremio_ids.dart';

void main() {
  group('StremioIds', () {
    test('track ids carry the provider and track id', () {
      final id = StremioIds.track('spotify', '4uLU6hMCjMI75M1A2tKUQC');
      final ref = StremioIds.parse(id);

      expect(ref, isNotNull);
      expect(ref!.isTrack, isTrue);
      expect(ref.source, 'spotify');
      expect(ref.value, '4uLU6hMCjMI75M1A2tKUQC');
    });

    test('ids are stable and path safe', () {
      final first = StremioIds.album('spotify', '37i9dQZF1DXcBWIGoYBM5M');
      final second = StremioIds.album('spotify', '37i9dQZF1DXcBWIGoYBM5M');

      expect(first, second);
      expect(first, isNot(contains('/')));
      expect(first, isNot(contains('=')));
      expect(first, isNot(contains(' ')));
    });

    test('each kind round-trips through its own parser branch', () {
      final album = StremioIds.parse(StremioIds.album('deezer', '302127'));
      final playlist = StremioIds.parse(
        StremioIds.playlist('deezer', '908622995'),
      );
      final artist = StremioIds.parse(StremioIds.artist('deezer', '27'));
      final library = StremioIds.parse(StremioIds.library('file:abc123'));

      expect(album!.isAlbum, isTrue);
      expect(album.value, '302127');
      expect(playlist!.isPlaylist, isTrue);
      expect(playlist.value, '908622995');
      expect(artist!.isArtist, isTrue);
      expect(artist.value, '27');
      expect(library!.isLibrary, isTrue);
      expect(library.value, 'file:abc123');
    });

    test('ids with a colon or a dot in the value survive encoding', () {
      final id = StremioIds.library('library:row.1');
      final ref = StremioIds.parse(id);

      expect(ref, isNotNull);
      expect(ref!.value, 'library:row.1');
    });

    test('foreign ids are rejected instead of parsed', () {
      expect(StremioIds.parse('tt0111161'), isNull);
      expect(StremioIds.parse('mny:'), isNull);
      expect(StremioIds.parse('mny:t'), isNull);
      expect(StremioIds.parse('mny:t:'), isNull);
    });
  });
}
