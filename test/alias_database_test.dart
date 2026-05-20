import 'package:flutter_test/flutter_test.dart';
import 'package:atmos/services/alias_database.dart';

void main() {
  group('AliasDatabase Tests', () {
    test('getSearchVariations returns manual aliases for known titles', () async {
      final variations = await AliasDatabase.getSearchVariations('Breaking Bad');
      expect(variations, contains('bb'));
      expect(variations, contains('breakingbad'));
      expect(variations, contains('Breaking Bad'));
    });

    test('getSearchVariations dynamically generates initials for unknown titles', () async {
      final variations = await AliasDatabase.getSearchVariations('House of Cards');
      expect(variations, contains('hoc'));
      expect(variations, contains('HouseofCards'));
    });

    test('getSearchVariations handles stop words and connector swaps', () async {
      final variations = await AliasDatabase.getSearchVariations('Rick and Morty');
      expect(variations, contains('rm'));
      expect(variations, contains('Rick & Morty'));
      expect(variations, contains('Rick n Morty'));
      expect(variations, contains('rickandmorty'));
    });

    test('getSearchVariations handles leading stop words', () async {
      final variations = await AliasDatabase.getSearchVariations('The Walking Dead');
      expect(variations, contains('Walking Dead'));
      expect(variations, contains('twd'));
    });
  });
}
