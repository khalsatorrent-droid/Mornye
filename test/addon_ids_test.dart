import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/addon/addon_ids.dart';

void main() {
  group('AddonIds', () {
    test('track ids carry the provider and track id', () {
      final id = AddonIds.track('spotify', '4uLU6hMCjMI75M1A2tKUQC');
      final ref = AddonIds.parse(id);

      expect(ref, isNotNull);
      expect(ref!.isTrack, isTrue);
      expect(ref.source, 'spotify');
      expect(ref.value, '4uLU6hMCjMI75M1A2tKUQC');
    });

    test('ids are stable and path safe', () {
      final first = AddonIds.album('spotify', '37i9dQZF1DXcBWIGoYBM5M');
      final second = AddonIds.album('spotify', '37i9dQZF1DXcBWIGoYBM5M');

      expect(first, second);
      expect(first, isNot(contains('/')));
      expect(first, isNot(contains('=')));
      expect(first, isNot(contains(' ')));
    });

    test('each kind round-trips through its own parser branch', () {
      final album = AddonIds.parse(AddonIds.album('deezer', '302127'));
      final playlist = AddonIds.parse(AddonIds.playlist('deezer', '908622995'));
      final artist = AddonIds.parse(AddonIds.artist('deezer', '27'));
      final library = AddonIds.parse(AddonIds.library('file:abc123'));

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
      final id = AddonIds.library('library:row.1');
      final ref = AddonIds.parse(id);

      expect(ref, isNotNull);
      expect(ref!.value, 'library:row.1');
    });

    test('foreign ids are rejected instead of parsed', () {
      expect(AddonIds.parse('tt0111161'), isNull);
      expect(AddonIds.parse('mny:'), isNull);
      expect(AddonIds.parse('mny:t'), isNull);
      expect(AddonIds.parse('mny:t:'), isNull);
    });
  });
}
