/// Fetchers artwork — iTunes (priorité) + Deezer (fallback).
///
/// Algorithme pour chaque source :
///   1. Découper l'artiste ICY en parties (principal + featurings)
///   2. Lancer les recherches en PARALLÈLE pour toutes les parties
///   3. Parmi tous les résultats, sélectionner celui avec le meilleur
///      score de correspondance titre (Jaccard normalisé)
///   4. Score minimum 0.6 requis — sinon null (pas de faux positif)
///
/// Avantage du parallèle : GREGZ ne bloque plus K-REEN.
/// Le meilleur score global gagne, quelle que soit la partie de l'artiste.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// Interface commune
// ---------------------------------------------------------------------------

abstract interface class ArtworkFetcher {
  Future<String?> fetch({
    required String artist,
    required String title,
    required Duration timeout,
  });
}

// ---------------------------------------------------------------------------
// Client HTTP minimal — remplace dio
// ---------------------------------------------------------------------------

class SimpleHttpClient {
  const SimpleHttpClient();

  Future<Map<String, dynamic>?> getJson(Uri uri, {Duration? timeout}) async {
    final client = HttpClient();
    if (timeout != null) {
      client.connectionTimeout = timeout;
      client.idleTimeout       = timeout;
    }
    try {
      final request = await client.getUrl(uri);
      request.headers
        ..set(HttpHeaders.acceptHeader,   'application/json')
        ..set(HttpHeaders.userAgentHeader, 'radio_service/1.0');
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final body    = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } on Exception catch (e) {
      // ── DEBUG ──────────────────────────────────────────────────────────────
      debugPrint('[SimpleHttpClient] erreur réseau: $e');
      // ── FIN DEBUG ──────────────────────────────────────────────────────────
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

// ---------------------------------------------------------------------------
// Utilitaires de normalisation et matching
// ---------------------------------------------------------------------------

/// Normalise une chaîne pour la comparaison :
/// minuscules, suppression accents, caractères spéciaux → espace,
/// réduction des consonnes doublées (penn→pen, ll→l…).
String _normalize(String s) {
  const accents = 'àáâãäåæçèéêëìíîïðñòóôõöùúûüýÿ';
  const ascii   = 'aaaaaaeceeeeiiiidnoooooouuuuyy';
  var r = s.toLowerCase().trim();
  for (var i = 0; i < accents.length; i++) {
    r = r.replaceAll(accents[i], ascii[i]);
  }
  // Supprime les apostrophes et tirets INTRA-MOT (entre deux lettres)
  // ex: MAT'LO → matlo, C'EST → cest, L'AMOUR → lamour
  r = r.replaceAllMapped(
    RegExp(r"(?<=[a-z])['\u2019\-](?=[a-z])"),
        (_) => '',
  );
  r = r
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // Réduit les consonnes doublées : penn→pen, ll→l, tt→t…
  // 'r' exclu intentionnellement : PIERRE, WARREN, FERRARI sont des noms
  // valides avec double r — les réduire causerait des faux négatifs.
  r = r.replaceAllMapped(
    RegExp(r'([bcdfghjklmnpqstvwxyz])\1+'),
        (m) => m.group(1)!,
  );
  return r;
}

/// Longueur minimale d'un token pour le fuzzy matching.
/// Les tokens courts (< 6 chars) sont trop ambigus — MARIE vs MARIO,
/// DOU vs POU — on n'applique la distance de Levenshtein qu'aux tokens longs.
const _fuzzyMinLen = 6;

/// Retourne true si deux tokens sont considérés comme équivalents.
/// Gère les variantes dialectales/orthographiques proches :
///   BENYEM ↔ BENYEN  (créole guadeloupéen vs haïtien)
///   MATLO  ↔ MAT'LO  (apostrophe traitée en amont par _normalize)
bool _fuzzyMatch(String t1, String t2) {
  if (t1 == t2) return true;
  if (t1.length < _fuzzyMinLen || t2.length < _fuzzyMinLen) return false;

  final short = t1.length <= t2.length ? t1 : t2;
  final long  = t1.length <= t2.length ? t2 : t1;

  // Préfixe commun avec au plus 2 chars supplémentaires
  if (long.startsWith(short) && long.length - short.length <= 2) return true;

  // Distance de Levenshtein ≤ 1
  if ((t1.length - t2.length).abs() > 1) return false;
  if (t1.length == t2.length) {
    return _countDiffs(t1, t2) <= 1;
  }
  // Longueurs différentes de 1 — test par suppression d'un char
  for (var i = 0; i < long.length; i++) {
    if (long.substring(0, i) + long.substring(i + 1) == short) return true;
  }
  return false;
}

int _countDiffs(String a, String b) {
  var diffs = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) diffs++;
  }
  return diffs;
}

int _fuzzyIntersectionCount(Set<String> ta, Set<String> tb) {
  final matchedB = <String>{};
  var count = 0;
  for (final a in ta) {
    for (final b in tb) {
      if (!matchedB.contains(b) && _fuzzyMatch(a, b)) {
        matchedB.add(b);
        count++;
        break;
      }
    }
  }
  return count;
}
const _qualifierTokens = {
  'live', 'remastered', 'remaster', 'remix', 'remixed',
  'acoustic', 'version', 'edit', 'radio', 'extended',
  'instrumental', 'mix', 'single', 'deluxe',
  'bonus', 'demo', 'unplugged', 'session', 'concert',
};

/// Score de correspondance titre — coefficient de Jaccard sur les tokens.
/// Retourne 0.0 à 1.0.
///
/// Trois passes — on retient le meilleur score :
/// 1. Score exact Jaccard
/// 2. Score fuzzy — tokens ≥ 6 chars avec distance Levenshtein ≤ 1
///    ex: BENYEM ↔ BENYEN (variante dialectale créole)
/// 3. Score épuré — sans les qualificatifs iTunes (Live, Remix…)
///
/// Les tokens purement numériques (numéros de piste "01", "04"…)
/// sont exclus — ils n'apportent aucune information pour la correspondance.
double _titleScore(String a, String b) {
  bool keep(String w) => w.length >= 2 && !RegExp(r'^\d+$').hasMatch(w);
  final ta = _normalize(a).split(' ').where(keep).toSet();
  final tb = _normalize(b).split(' ').where(keep).toSet();
  if (ta.isEmpty && tb.isEmpty) return 1.0;
  if (ta.isEmpty || tb.isEmpty) return 0.0;

  // Passe 0 — sigle unique : titre ICY = 1 token qui apparaît dans iTunes
  // ex: ICY="IKPTAM" → iTunes="I Ka Pran Tèt An Mwen (IKPTAM)" → score 1.0
  // Le sigle est le titre abrégé — correspondance exacte même si le titre
  // iTunes contient des mots supplémentaires.
  if (ta.length == 1 && ta.every((t) => tb.contains(t))) return 1.0;

  // Passe 1 — score exact Jaccard
  final raw = ta.intersection(tb).length / ta.union(tb).length;

  // Passe 2 — score fuzzy
  final fi = _fuzzyIntersectionCount(ta, tb);
  final fu = ta.length + tb.length - fi;
  final fuzzy = fu > 0 ? fi / fu : 0.0;

  // Passe 3 — score épuré (sans qualificatifs)
  final tbClean = tb.difference(_qualifierTokens);
  var clean = 0.0;
  if (tbClean.isNotEmpty && tbClean.length < tb.length) {
    final fc  = _fuzzyIntersectionCount(ta, tbClean);
    final fuc = ta.length + tbClean.length - fc;
    clean = fuc > 0 ? fc / fuc : 0.0;
  }

  return [raw, fuzzy, clean].reduce((a, b) => a > b ? a : b);
}

/// Score minimum requis pour accepter un résultat.
const _minScore = 0.6;

/// Suffixes parasites ajoutés par les radios après le nom d'artiste.
/// Supprimés avant la recherche pour éviter les faux "aucun résultat".
final _artistSuffixPattern = RegExp(
  r'\s*\b(?:official|officiel|music|tv|channel|vevo|records|'
  r'prod|production|productions|entertainment|ent|'
  r'média|media|artiste|artist|groupe|group|band)\b\s*$',
  caseSensitive: false,
);

String _removeArtistSuffix(String artist) =>
    artist.replaceAll(_artistSuffixPattern, '').trim();

/// Découpe un nom d'artiste contenant un featuring en parties distinctes.
///
/// Patterns couverts (insensible à la casse) :
///   feat. / feat / ft. / ft / featuring
///   w/  (abréviation de "with")
///   and / und / et
///   with / avec
///   [+] / (+) / +
///   &
///   x  (lettre entourée d'espaces)
///   ,  (virgule)
///
/// Exemples :
///   "GREGZ ft K REEN and DJ JAIRO" → ["GREGZ", "K REEN", "DJ JAIRO"]
///   "NESLY feat. FANNY J"          → ["NESLY", "FANNY J"]
///   "DAVID & CORINE"               → ["DAVID", "CORINE"]
///   "Y'FIX [+] JACQUES D'ARBAUD"   → ["Y'FIX", "JACQUES D'ARBAUD"]
List<String> _splitFeaturing(String artist) {
  final pattern = RegExp(
    // 'featuring' en premier — plus long, évite le match partiel par 'feat'
    r'\(?\s*\bfeaturing\b\s*\)?'
    // 'feat' et 'ft' — \b des deux côtés, point optionnel inclus dans le match
    r'|\(?\s*\bfeat\.?\s*\)?'
    r'|\(?\s*\bft\.?\s*\)?'
    // Mots complets — \b évite ANDREU (and), BAGUETTE (et), KRAFTWERK (ft)
    r'|\b(?:with|avec|and|und|et)\b'
    r'|\s*\[?\+\]?\s*'
    r'|\s+x\s+'   // x uniquement entouré d'espaces
    r'|\s*&\s*'
    r'|\s*,\s*',
    caseSensitive: false,
  );
  return artist
      .split(pattern)
      .map((s) => s.replaceAll(RegExp(r'[()]'), '').trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

/// Nettoie un titre en retirant :
///   - les mentions de featuring incorporées
///   - les annotations d'année ajoutées par les radios (ex. "(1992)", "[2003]")
///
/// Exemples :
///   "The Wanderer (w/ Johnny Cash)"    → "The Wanderer"
///   "Pa fé mwen la pen (feat. K-Reen)" → "Pa fé mwen la pen"
///   "MARIE (1992)"                     → "MARIE"
///   "K-2000 WACHÉ WACHÉ (1990)"        → "K-2000 WACHÉ WACHÉ"
///   "TRIPÉ SAN TRICHÉ (1993)"          → "TRIPÉ SAN TRICHÉ"
String _cleanTitle(String title) {
  var cleaned = title;

  // Retire les annotations d'année : (1990), [2003], (90), etc.
  cleaned = cleaned.replaceAll(
    RegExp(r'\s*[\(\[]\s*(?:19|20)\d{2}\s*[\)\]]'),
    '',
  );

  // Retire les suffixes de version courants non entre parenthèses
  // ex: "Debake remix" → "Debake", "Song Extended" → "Song"
  cleaned = cleaned.replaceAll(
    RegExp(
      r'\s+\b(?:remix|remaster(?:ed)?|live|acoustic|extended|'
      r'instrumental|radio\s+edit|edit|version|mix|cover)\b\s*$',
      caseSensitive: false,
    ),
    '',
  );

  // Retire les blocs contenant un mot-clé de featuring
  cleaned = cleaned.replaceAll(
    RegExp(
      r'\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring|w\/|with|avec|and|et)'
      r'\s+[^\)\]]+[\)\]]',
      caseSensitive: false,
    ),
    '',
  );

  return cleaned.trim();
}

// ---------------------------------------------------------------------------
// Résultat intermédiaire d'une recherche
// ---------------------------------------------------------------------------

class _Match {
  const _Match({
    required this.url,
    required this.score,
    required this.typeRank,
    required this.resultArtist,
    required this.resultTitle,
    required this.searchPart,
  });

  final String url;
  final double score;
  final int    typeRank;
  final String resultArtist;
  final String resultTitle;
  final String searchPart;

  /// Compare deux matches : meilleur score d'abord,
  /// puis meilleur type d'album (0=album studio) à égalité.
  bool isBetterThan(_Match? other) {
    if (other == null) return true;
    if (score > other.score) return true;
    if (score == other.score && typeRank < other.typeRank) return true;
    return false;
  }
}

// ---------------------------------------------------------------------------
// iTunes Search API — source principale
// ---------------------------------------------------------------------------

/// Recherches parallèles sur toutes les parties de l'artiste.
/// Le meilleur score de correspondance titre gagne.
class ItunesArtworkFetcher implements ArtworkFetcher {
  const ItunesArtworkFetcher({SimpleHttpClient? http})
      : _http = http ?? const SimpleHttpClient();

  final SimpleHttpClient _http;

  static const _base  = 'https://itunes.apple.com/search';
  static const _limit = 50;

  @override
  Future<String?> fetch({
    required String artist,
    required String title,
    required Duration timeout,
  }) async {
    if (title.trim().isEmpty) return null;

    final parts        = _splitFeaturing(artist);
    final cleanedTitle = _cleanTitle(title);

    // ── DEBUG ────────────────────────────────────────────────────────────────
    debugPrint('[iTunes] fetch → artist:"$artist" title:"$title"');
    if (cleanedTitle != title) {
      debugPrint('[iTunes] titre nettoyé: "$cleanedTitle"');
    }
    debugPrint('[iTunes] parts: $parts');
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    // Lancement parallèle — une requête par partie de l'artiste
    final futures = parts.map((part) => _searchPart(
      part:         part,
      cleanedTitle: cleanedTitle,
      timeout:      timeout,
    ));

    final allMatches = await Future.wait(futures);

    // Sélection du meilleur match parmi tous les résultats
    _Match? best;
    for (final match in allMatches.whereType<_Match>()) {
      if (match.isBetterThan(best)) best = match;
    }

    // ── DEBUG ────────────────────────────────────────────────────────────────
    if (best != null) {
      debugPrint('[iTunes] → meilleur match '
          '(part:"${best.searchPart}" '
          'artist:"${best.resultArtist}" '
          'title:"${best.resultTitle}" '
          'score:${best.score.toStringAsFixed(2)}): ${best.url}');
    } else {
      debugPrint('[iTunes] → aucun résultat valide');
    }
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    return best?.url;
  }

  /// Recherche pour une partie d'artiste donnée.
  ///
  /// Passe 1 — artiste+titre, limit=5 : précis, couvre Spoon, Green Day…
  /// Passe 2 — artiste seul, limit=50 : fallback pour les artistes dont
  ///   le titre du featuring n'est pas indexé sous leur nom (K-Reen, Fania…)
  Future<_Match?> _searchPart({
    required String   part,
    required String   cleanedTitle,
    required Duration timeout,
  }) async {
    // Supprime les suffixes parasites ("official", "music"…) du nom d'artiste
    // avant de construire le term de recherche iTunes.
    // IMPORTANT : on envoie le terme ORIGINAL à iTunes (accents conservés)
    // et on réserve _normalize() uniquement au scoring côté Dart.
    // Sans accents, iTunes ne trouve pas "Joé Dwèt Filé" avec "joe dwet file".
    final cleanPart  = _removeArtistSuffix(part);
    final termArtist = Uri.encodeComponent(cleanPart.trim().toLowerCase());
    final termTitle  = Uri.encodeComponent(cleanedTitle.trim().toLowerCase());

    // ── DEBUG ──────────────────────────────────────────────────────────────
    debugPrint('[iTunes] recherche parallèle: "$part" → term: $termArtist');
    // ── FIN DEBUG ──────────────────────────────────────────────────────────

    // Passe 1 : artiste + titre, limit=5
    final uri1  = Uri.parse(
      '$_base?term=$termArtist+$termTitle&media=music'
          '&entity=musicTrack&limit=5&country=FR',
    );
    final json1 = await _http.getJson(uri1, timeout: timeout);
    final res1  = (json1?['results'] as List<dynamic>?)
        ?.cast<Map<String, dynamic>>();
    final best1 = _bestFromResults(res1, cleanedTitle, part);
    if (best1 != null) return best1;

    // Passe 2 : artiste seul, limit=50
    final uri2  = Uri.parse(
      '$_base?term=$termArtist&media=music'
          '&entity=musicTrack&limit=$_limit&country=FR',
    );
    final json2 = await _http.getJson(uri2, timeout: timeout);
    final res2  = (json2?['results'] as List<dynamic>?)
        ?.cast<Map<String, dynamic>>();

    if (res2 == null || res2.isEmpty) {
      // ── DEBUG ────────────────────────────────────────────────────────────
      debugPrint('[iTunes] aucun résultat pour "$part"');
      // ── FIN DEBUG ────────────────────────────────────────────────────────

      // Passe 3 : titre seul — utile quand l'artiste ICY est sans accents
      // (ex: "JOE DWET FILE" → aucun résultat) mais le titre est unique.
      // Seuil : le titre doit avoir au moins 2 tokens de 3+ caractères
      // pour éviter les faux positifs sur les titres courts ("DOU", "VIE"…).
      final titleTokens = cleanedTitle.split(' ')
          .where((w) => w.length >= 3).length;
      if (titleTokens >= 2) {
        final uri3 = Uri.parse(
          '$_base?term=$termTitle&media=music'
              '&entity=musicTrack&limit=$_limit&country=FR',
        );
        final json3 = await _http.getJson(uri3, timeout: timeout);
        final res3  = (json3?['results'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>();
        return _bestFromResults(res3, cleanedTitle, part);
      }
      return null;
    }

    return _bestFromResults(res2, cleanedTitle, part);
  }

  /// Trouve le meilleur match dans une liste de résultats iTunes.
  _Match? _bestFromResults(
      List<Map<String, dynamic>>? results,
      String cleanedTitle,
      String part,
      ) {
    if (results == null || results.isEmpty) return null;
    _Match? best;

    for (final r in results) {
      final resultTitle  = r['trackName']  as String? ?? '';
      final resultArtist = r['artistName'] as String? ?? '';
      final score        = _titleScore(cleanedTitle, resultTitle);

      // ── DEBUG ──────────────────────────────────────────────────────────
      if (score >= 0.4) {
        debugPrint('[iTunes] candidat "$part" — '
            'artist:"$resultArtist" title:"$resultTitle" '
            'score:${score.toStringAsFixed(2)}');
      }
      // ── FIN DEBUG ──────────────────────────────────────────────────────

      if (score >= _minScore) {
        final url = _extractUrl(r);
        if (url != null) {
          final match = _Match(
            url:          url,
            score:        score,
            typeRank:     0,
            resultArtist: resultArtist,
            resultTitle:  resultTitle,
            searchPart:   part,
          );
          if (match.isBetterThan(best)) best = match;
        }
      }
    }

    return best;
  }

  String? _extractUrl(Map<String, dynamic> result) {
    final url = result['artworkUrl100'] as String?;
    if (url == null || url.isEmpty) return null;
    return url.replaceAll('100x100bb.jpg', '1000x1000bb.jpg');
  }
}

// ---------------------------------------------------------------------------
// Deezer API — fallback
// ---------------------------------------------------------------------------

/// Même stratégie parallèle qu'iTunes.
/// Priorité album studio via `record_type` ("album" > "single" > "compile").
class DeezerArtworkFetcher implements ArtworkFetcher {
  const DeezerArtworkFetcher({SimpleHttpClient? http})
      : _http = http ?? const SimpleHttpClient();

  final SimpleHttpClient _http;

  static const _base = 'https://api.deezer.com/search';

  @override
  Future<String?> fetch({
    required String artist,
    required String title,
    required Duration timeout,
  }) async {
    if (title.trim().isEmpty) return null;

    final parts        = _splitFeaturing(artist);
    final cleanedTitle = _cleanTitle(title);

    // ── DEBUG ────────────────────────────────────────────────────────────────
    debugPrint('[Deezer] fetch → artist:"$artist" title:"$title"');
    debugPrint('[Deezer] parts: $parts');
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    // Lancement parallèle
    final futures = parts.map((part) => _searchPart(
      part:         part,
      cleanedTitle: cleanedTitle,
      timeout:      timeout,
    ));

    final allMatches = await Future.wait(futures);

    _Match? best;
    for (final match in allMatches.whereType<_Match>()) {
      if (match.isBetterThan(best)) best = match;
    }

    // ── DEBUG ────────────────────────────────────────────────────────────────
    if (best != null) {
      debugPrint('[Deezer] → meilleur match '
          '(part:"${best.searchPart}" '
          'artist:"${best.resultArtist}" '
          'title:"${best.resultTitle}" '
          'score:${best.score.toStringAsFixed(2)}): ${best.url}');
    } else {
      debugPrint('[Deezer] → aucun résultat valide');
    }
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    return best?.url;
  }

  Future<_Match?> _searchPart({
    required String   part,
    required String   cleanedTitle,
    required Duration timeout,
  }) async {
    final cleanPart = _removeArtistSuffix(part);
    // Accents conservés — Deezer les utilise pour la recherche
    final query     = Uri.encodeComponent(cleanPart.trim().toLowerCase());
    final uri   = Uri.parse('$_base?q=$query&limit=25');

    // ── DEBUG ──────────────────────────────────────────────────────────────
    debugPrint('[Deezer] recherche parallèle: "$part"');
    // ── FIN DEBUG ──────────────────────────────────────────────────────────

    final json = await _http.getJson(uri, timeout: timeout);
    final data = (json?['data'] as List<dynamic>?)
        ?.cast<Map<String, dynamic>>();

    if (data == null || data.isEmpty) {
      // ── DEBUG ────────────────────────────────────────────────────────────
      debugPrint('[Deezer] aucun résultat pour "$part"');
      // ── FIN DEBUG ────────────────────────────────────────────────────────

      // Passe 2 : titre seul — utile quand l'artiste ICY est sans accents.
      // Seuil : au moins 2 tokens de 3+ caractères pour éviter les ambiguïtés.
      final titleTokens = cleanedTitle.split(' ')
          .where((w) => w.length >= 3).length;
      if (titleTokens >= 2) {
        final queryTitle = Uri.encodeComponent(cleanedTitle.trim().toLowerCase());
        final uri2 = Uri.parse('$_base?q=$queryTitle&limit=25');
        final json2 = await _http.getJson(uri2, timeout: timeout);
        final data2 = (json2?['data'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>();
        if (data2 != null && data2.isNotEmpty) {
          return _bestDeezerFromResults(data2, cleanedTitle, part);
        }
      }
      return null;
    }

    return _bestDeezerFromResults(data, cleanedTitle, part);
  }

  _Match? _bestDeezerFromResults(
      List<Map<String, dynamic>> data,
      String cleanedTitle,
      String part,
      ) {
    _Match? best;

    for (final track in data) {
      final resultTitle  = track['title']  as String? ?? '';
      final resultArtist =
          (track['artist'] as Map<String, dynamic>?)?['name']
          as String? ?? '';
      final score    = _titleScore(cleanedTitle, resultTitle);
      final typeRank = _recordTypeRank(track);

      // ── DEBUG ────────────────────────────────────────────────────────────
      if (score >= 0.4) {
        final rType = (track['album'] as Map<String, dynamic>?)
        ?['record_type'] ?? '?';
        debugPrint('[Deezer] candidat "$part" — '
            'artist:"$resultArtist" title:"$resultTitle" '
            'record_type:"$rType" score:${score.toStringAsFixed(2)}');
      }
      // ── FIN DEBUG ────────────────────────────────────────────────────────

      if (score >= _minScore) {
        final album = track['album'] as Map<String, dynamic>?;
        final url   = album?['cover_xl']     as String? ??
            album?['cover_big']    as String? ??
            album?['cover_medium'] as String?;

        // ── DEBUG ────────────────────────────────────────────────────────────
        if (score >= 0.4) {
          debugPrint('[Deezer] url candidate: "$url"');
        }
        // ── FIN DEBUG ────────────────────────────────────────────────────────

        if (url != null && url.isNotEmpty && !url.contains('no_album')) {
          final match = _Match(
            url:          url,
            score:        score,
            typeRank:     typeRank,
            resultArtist: resultArtist,
            resultTitle:  resultTitle,
            searchPart:   part,
          );
          if (match.isBetterThan(best)) best = match;
        }
      }
    }

    return best;
  }

  int _recordTypeRank(Map<String, dynamic> track) {
    final album = track['album'] as Map<String, dynamic>?;
    final type  = (album?['record_type'] as String? ?? '').toLowerCase();
    return switch (type) {
      'album'   => 0,
      'single'  => 1,
      'compile' => 2,
      _         => 3,
    };
  }
}

// ---------------------------------------------------------------------------
// Wrappers @visibleForTesting — exposent les fonctions privées pour les tests
// ---------------------------------------------------------------------------

/// Expose [_normalize] pour les tests unitaires.
@visibleForTesting
String normalizeForTest(String s) => _normalize(s);

/// Expose [_titleScore] pour les tests unitaires.
@visibleForTesting
double titleScoreForTest(String a, String b) => _titleScore(a, b);

/// Expose [_splitFeaturing] pour les tests unitaires.
@visibleForTesting
List<String> splitFeaturingForTest(String artist) => _splitFeaturing(artist);