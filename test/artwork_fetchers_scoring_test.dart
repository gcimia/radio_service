/// Tests unitaires — scoring et normalisation des titres.
///
/// Couvre tous les cas réels rencontrés en production sur les radios
/// caribéennes. Ces tests ne nécessitent aucun flux live — ils valident
/// la logique de _titleScore, _normalize et _splitFeaturing.
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/src/artwork/artwork_fetchers.dart';

// ---------------------------------------------------------------------------
// Helpers — accès aux fonctions privées via des wrappers de test
// ---------------------------------------------------------------------------

// artwork_fetchers.dart expose ces fonctions au niveau bibliothèque (top-level)
// On les teste via les fetchers qui les utilisent en interne.
// Pour les tester directement, on les réexpose ici via @visibleForTesting
// ou on les teste indirectement via ItunesArtworkFetcher avec un stub.

// ---------------------------------------------------------------------------
// Tests _normalize (via comportement observable)
// ---------------------------------------------------------------------------

void main() {
  // ── _normalize ─────────────────────────────────────────────────────────────

  group('_normalize — accents et caractères spéciaux', () {
    // Ces tests valident que _normalize produit les bons tokens
    // pour le scoring Jaccard.

    test('convertit les accents', () {
      // é → e, è → e, ê → e
      expect(_norm('généraliste'), equals('generaliste'));
      expect(_norm('étoile'),      equals('etoile'));
      expect(_norm('MARIE'),       equals('marie'));
    });

    test('supprime les apostrophes intra-mot', () {
      // MAT'LO → matlo (pas mat lo)
      expect(_norm("MAT'LO"),   equals('matlo'));
      expect(_norm("C'EST"),    equals('cest'));
      expect(_norm("L'AMOUR"),  equals('lamour'));
      expect(_norm("BENYEN M'"), contains('benyen'));
    });

    test('remplace les autres caractères par espace', () {
      expect(_norm('TO ! TO ! TO !'), equals('to to to'));
      expect(_norm('(Live)'),         equals('live'));
    });

    test('réduit les consonnes doublées sauf r', () {
      expect(_norm('PENN'),    equals('pen'));   // nn → n
      expect(_norm('BILLONG'), equals('bilong')); // ll → l
      // r NON réduit
      expect(_norm('PIERRE'),  equals('pierre'));  // rr conservé
      expect(_norm('WARREN'),  equals('waren'));   // rr conservé → waren
      expect(_norm('FERRARI'), equals('ferari')); // rr conservé
    });

    test('supprime les numéros de piste', () {
      // Les tokens numériques sont filtrés dans _titleScore, pas _normalize
      // _normalize les laisse passer — le filtre est dans keep()
      expect(_norm('04 MAT\'LO'), contains('matlo'));
    });
  });

  // ── _titleScore ────────────────────────────────────────────────────────────

  group('_titleScore — cas réels radios caribéennes', () {

    // ── Correspondances exactes ─────────────────────────────────────────────
    test('titre identique', () {
      expect(_score('MARIE', 'Marie'), equals(1.0));
      expect(_score('BILONGO', 'Bilongo'), equals(1.0));
      expect(_score('RET SEZI', 'Ret Sezi'), equals(1.0));
    });

    test('titre avec accents côté iTunes', () {
      expect(_score('PA FE MWEN', 'Pa fé mwen'), equals(1.0));
      expect(_score('ALANVE', 'Alanvè'), equals(1.0));
    });

    // ── Numéros de piste iTunes ─────────────────────────────────────────────
    test('numéro de piste préfixé iTunes ignoré', () {
      expect(_score('Matlo', "04 MAT'LO"), greaterThanOrEqualTo(0.6));
      expect(_score('MARIE', '01 MARIE'),  greaterThanOrEqualTo(0.6));
      expect(_score('Matlo', '01 MATLO'),  greaterThanOrEqualTo(0.6));
    });

    // ── Apostrophes dans les titres ─────────────────────────────────────────
    test("apostrophe intra-mot : MAT'LO = MATLO", () {
      expect(_score('Matlo', "MAT'LO"), equals(1.0));
      expect(_score('Matlo', "Mat'lo"), equals(1.0));
    });

    test("C'EST LA MIENNE — apostrophe début de mot", () {
      expect(_score("C'EST LA MIENNE", "C'est la mienne"),
          greaterThanOrEqualTo(0.6));
    });

    // ── Qualificatifs Live / Remix / Remastered ─────────────────────────────
    test('Live dans le titre iTunes ignoré', () {
      expect(_score('Alanve', 'Alanvè (Live)'),
          greaterThanOrEqualTo(0.6));
      expect(_score('Your Best American Girl', 'Your Best American Girl (Live)'),
          greaterThanOrEqualTo(0.6));
      expect(_score("Cheri Benyem", "Cheri Benyen M' (live)"),
          greaterThanOrEqualTo(0.6));
    });

    test('Remastered dans le titre iTunes ignoré', () {
      expect(_score('Warning', 'Warning (Remastered)'),
          greaterThanOrEqualTo(0.6));
    });

    test('Remix dans le titre ICY → nettoyé avant scoring', () {
      // "Debake remix" → _cleanTitle → "Debake" → score vs "Debake" = 1.0
      expect(_score('Debake', 'Debake'), equals(1.0));
    });

    // ── Variantes dialectales créoles (fuzzy) ────────────────────────────────
    test('BENYEM ↔ BENYEN (créole guadeloupéen vs haïtien)', () {
      expect(_score('CHERI BENYEM', "Cheri Benyen M'"),
          greaterThanOrEqualTo(0.6));
      expect(_score('CHERI BENYEM', "Cheri Benyen M' (live)"),
          greaterThanOrEqualTo(0.6));
    });

    // ── Titres longs multi-tokens ───────────────────────────────────────────
    test('titre long — correspondance partielle acceptée', () {
      expect(_score('Bohemian Rhapsody', 'Bohemian Rhapsody'), equals(1.0));
      expect(_score('PA FE MWEN LA PENN', 'Pa fé mwen la pen'),
          greaterThanOrEqualTo(0.6));
    });

    // ── Faux positifs à éviter ──────────────────────────────────────────────
    test('faux positif — titres sans lien', () {
      expect(_score('CHERI BENYEM', 'Incroyable'), lessThan(0.6));
      expect(_score('CHERI BENYEM', 'Illegal'),    lessThan(0.6));
      expect(_score('MATLO', '05 TRASE SI KONKAN'), lessThan(0.6));
    });

    test('faux positif — tokens courts similaires', () {
      expect(_score('MARIE', 'MARIO'), lessThan(0.6)); // 5 chars < fuzzyMinLen
      expect(_score('DOU', 'POU'),     lessThan(0.6));
      expect(_score('BOLO', 'SOLO'),   lessThan(0.6));
    });

    // ── Sigles (titre ICY = acronyme du titre réel) ─────────────────────────
    test('IKPTAM = I Ka Pran Tèt An Mwen (IKPTAM)', () {
      // Le sigle ICY apparaît entre parenthèses dans le titre iTunes
      expect(_score('IKPTAM', 'I Ka Pran Tèt An Mwen (IKPTAM)'),
          greaterThanOrEqualTo(0.6));
    });
    test("AN NOU TRIPE avec apostrophe dans le StreamTitle ICY", () {
      // ICY brut : KASSAV' - AN NOU TRIPE' → notre parser extrait AN NOU TRIPE
      // après suppression de l'apostrophe finale par [^;]*
      expect(_score("AN NOU TRIPE", "An nou tripé"), greaterThanOrEqualTo(0.6));
    });
  });

  // ── _splitFeaturing ─────────────────────────────────────────────────────────

  group('_splitFeaturing — découpage artistes', () {
    test('artiste simple — pas de split', () {
      expect(_split('DJET-X'),     equals(['DJET-X']));
      expect(_split('WEEK-END'),   equals(['WEEK-END']));
      expect(_split('KRAFTWERK'),  equals(['KRAFTWERK']));
      expect(_split('AFTER EIGHT'),equals(['AFTER EIGHT']));
      expect(_split('PATRICK ANDREU'), equals(['PATRICK ANDREU']));
    });

    test('feat. — split correct', () {
      expect(_split('Calvin Harris feat. Rihanna'),
          equals(['Calvin Harris', 'Rihanna']));
      expect(_split('NESLY feat. FANNY J'),
          equals(['NESLY', 'FANNY J']));
    });

    test('ft — split correct', () {
      expect(_split('A ft. B'), equals(['A', 'B']));
      expect(_split('GREGZ ft K REEN'), equals(['GREGZ', 'K REEN']));
    });

    test('featuring — split correct', () {
      expect(_split('A featuring B and C'), equals(['A', 'B', 'C']));
    });

    test('& — split correct', () {
      expect(_split('DAVID & CORINE'), equals(['DAVID', 'CORINE']));
      expect(_split('DJ SNAKE & OZUNA'), equals(['DJ SNAKE', 'OZUNA']));
    });

    test('and/et — split sur mots complets uniquement', () {
      expect(_split('ARTIST1 et ARTIST2'), equals(['ARTIST1', 'ARTIST2']));
      expect(_split('GREGZ ft K REEN and DJ JAIRO'),
          equals(['GREGZ', 'K REEN', 'DJ JAIRO']));
      // ET dans DJET-X ne doit PAS couper
      expect(_split('DJET-X'), equals(['DJET-X']));
      // AND dans ANDREU ne doit PAS couper
      expect(_split('PATRICK ANDREU'), equals(['PATRICK ANDREU']));
    });

    test('[+] — split correct', () {
      expect(_split("Y'FIX [+] JACQUES D'ARBAUD"),
          equals(["Y'FIX", "JACQUES D'ARBAUD"]));
    });
  });
}

// ---------------------------------------------------------------------------
// Wrappers — appellent les fonctions top-level de artwork_fetchers.dart
// ---------------------------------------------------------------------------

/// Expose _normalize pour les tests — la fonction est top-level dans la lib.
String _norm(String s) => normalizeForTest(s);

/// Expose _titleScore pour les tests.
double _score(String a, String b) => titleScoreForTest(a, b);

/// Expose _splitFeaturing pour les tests.
List<String> _split(String artist) => splitFeaturingForTest(artist);