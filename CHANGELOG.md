## 0.0.2

### Corrections
* Les erreurs de lecture remontent désormais à l'UI sous forme de `PlayerError`
  (auparavant envoyées comme erreurs de canal, jamais visibles) — fini le
  loader infini quand une radio est indisponible.
* Watchdog « premier octet » : si aucune donnée audio n'arrive dans les 15 s
  suivant la connexion, le flux est déclaré indisponible (`PlayerError`).
* L'état d'erreur n'est plus écrasé par le `STATE_IDLE` automatique
  qu'ExoPlayer émet après une erreur.
* `IcyStreamReader` signale l'épuisement des tentatives de reconnexion
  (callback `onUnavailable`) au lieu d'abandonner en silence.

### Focus audio (Android)
* Gestion manuelle du focus audio (remplace `handleAudioFocus` de Media3) :
  pause sur interruption (appel, autre appli média), ducking sur les
  interruptions courtes (notification, GPS), reprise au retour du focus.
* Nouveau paramètre `autoResumeAfterFocusLoss` (défaut `true`) : si `false`,
  la lecture reste en pause après une interruption — reprise manuelle.

### Cycle de vie & ressources (Android)
* Nouvelle méthode native `release()` appelée par `RadioService.dispose()` :
  arrête le foreground service et libère player, MediaSession et notification.
  Plus aucune ressource ne survit à la fermeture de l'application.
* `configure(backgroundEnabled: false)` arrête désormais le service s'il
  tournait (libération par fonctionnalité).
* Balayage de l'appli depuis les récents (`onTaskRemoved`) : arrêt de la
  lecture et libération complète.
* `dispose()` est désormais idempotent (garde anti double-libération).

### Toolchain
* Alignement sur Flutter 3.44 : AGP 9.0.1, Kotlin 2.3.20, Gradle 9.1.0
  (exemple), `android.builtInKotlin=false` (état supporté par Flutter 3.44.x).
* Contrainte d'environnement : Flutter >= 3.44.0, Dart ^3.12.0.

### Divers
* Implémentation web alignée sur l'interface (`configure`, `release`) et
  nettoyée (imports redondants, membre `metadataStream` documenté comme
  spécifique au web).

## 0.0.1

Première version.

### Fonctionnalités
* Lecture de flux radio en streaming (ICY / SHOUTcast / Icecast, MP3 / AAC / OGG).
* Analyse automatique des métadonnées ICY (titre, artiste, nom de station).
* Récupération des métadonnées via API REST (chemins JSON imbriqués).
* Résolution de pochettes (iTunes / Deezer) avec cache LRU.
* Égaliseur 5 bandes avec presets.
* Lecture en arrière-plan et contrôles via la notification système (Android).
* Détection de silence / flux inactif.

### Plateformes
* Android : pris en charge.
* iOS : prévu.
