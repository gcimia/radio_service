<!--
  Version française du journal des modifications (secondaire).
  Le fichier de référence pour pub.dev est CHANGELOG.md (anglais).
-->

## 0.1.7

### RUPTURE
* **`pause()` relâche désormais la source.** Elle coupe la couche réseau Dart
  (lecteur ICY + proxy audio) en plus du lecteur natif, et `play()` recharge la
  station. Les sites d'appel ne changent pas — `service.player.pause()` garde
  la même signature — mais le comportement, si : la reprise coûte une
  reconnexion d'environ une seconde, et les métadonnées repartent au prochain
  bloc ICY de la station. Un hôte qui comptait sur une reprise instantanée doit
  s'attendre à un court état de mise en tampon. HLS n'est pas concerné.

### Corrigé — un bouton de lecture qui ne faisait rien du tout
* Jusqu'en 0.1.6, `pause()` gardait délibérément le flux vivant « pour
  permettre une reprise immédiate ». Le lecteur ICY continuait donc de tirer
  sur la station et de remplir un tampon local **que plus personne ne vidait**.
  Au bout d'un moment la liaison cassait ; la reprise relançait alors la
  lecture sur une source morte, ce qui ne produit **ni son, ni erreur** — aucun
  état ne changeait, aucun écran ne bougeait, et la personne concluait qu'elle
  avait raté le bouton. Un bouton silencieux est pire qu'un bouton qui échoue :
  un échec se voit et se signale, un silence se répète. `pause()` relâche
  maintenant la source et `play()` la recharge.
* Un direct ne se reprend pas, il se rejoint. Même source intacte, reprendre là
  où la lecture s'est arrêtée fait réécouter le passé le temps que le tampon se
  vide — dix minutes de pause, dix minutes de retard. Recharger est le
  comportement juste, pas un contournement.
* Une pause ne ressemble plus à une coupure réseau : le relâchement incrémente
  le jeton de génération du flux, si bien que la déconnexion qu'il provoque ne
  peut pas être annoncée comme `PlayerInterrupted`.

### Corrigé — la notification n'ouvrait pas l'application
* La `MediaSession` porte désormais un `setSessionActivity(...)` : l'intention
  que Media3 remet à **toutes** les surfaces système qui interrogent la session
  — écran de verrouillage, contrôles média du système, Android Auto, montre.
  Sans elle, aucune ne savait où aller.
* La notification construite à la main porte en plus son propre
  `setContentIntent(...)`. `MediaStyleNotificationHelper.MediaStyle(session)`
  **ne reprend pas** la session activity comme intention de contenu d'une
  notification construite à la main : poser seulement `setSessionActivity`
  aurait laissé le corps de la notification inerte.
* Aucune application hôte n'est nommée : `getLaunchIntentForPackage(packageName)`
  rend le point d'entrée de n'importe quel hôte, l'universalité du plugin est
  préservée. `FLAG_IMMUTABLE` est obligatoire depuis Android 12 (API 31) ;
  `SINGLE_TOP | CLEAR_TOP` évitent d'empiler une seconde instance par-dessus
  une application déjà ouverte.

### Supprimé — un gestionnaire d'autorisation injoignable
* Le canal `radio_service/permissions` et son gestionnaire
  `requestNotificationPermission` disparaissent, ainsi que l'implémentation
  `ActivityAware` devenue inutile. Rien dans `lib/` ne les appelait.
* L'autorisation n'a jamais été nécessaire : la notification du lecteur passe
  par une `MediaSession`, et Android exempte explicitement ces notifications de
  `POST_NOTIFICATIONS` — c'est pourquoi elle s'est toujours affichée sans que
  rien n'ait été accordé. Du code mort qui a l'air d'une fonctionnalité est pire
  que pas de fonctionnalité : le jour où quelqu'un s'y fie, il se trompe, et il
  met du temps à comprendre pourquoi.
* La ligne `POST_NOTIFICATIONS` **reste dans le manifeste**, documentée. Une
  déclaration n'a aucun effet tant que personne ne demande, et elle évite à un
  hôte qui poste ses propres notifications d'avoir à l'ajouter. Demander
  l'autorisation est le rôle de l'hôte, pas du plugin.
* L'application d'exemple n'appelle plus le canal supprimé.

### Application d'exemple
* La banque de stations devient neutre : un flux de référence par codec pris en
  charge (MP3, AAC-LC, HE-AAC, Ogg Vorbis, Ogg Opus, Ogg FLAC), plus HLS, une
  playlist `.m3u` pour éprouver `PlaylistResolver`, et deux cas limites — un
  flux avec preroll et un 32 kbps mono. Ils viennent des flux de référence de
  Radiomast, publiés pour diagnostiquer les lecteurs et libres d'usage personnel
  et commercial. Qui télécharge le plugin n'hérite plus des stations d'un autre.
  Une station réelle (FIP, en HLS) est conservée pour éprouver les vraies
  métadonnées ID3 in-band et la résolution de pochette, et les exemples de
  métadonnées REST sont devenus des gabarits génériques.

### Limite connue — les pauses provoquées par le focus audio
* Seule une pause **explicite** relâche la source. Une pause provoquée par le
  focus audio (appel entrant, casque débranché via `handleAudioBecomingNoisy`)
  est déclenchée nativement et court-circuite `PlayerController` : elle ne
  relâche rien. C'est voulu pour une interruption courte — la reprise
  instantanée y vaut davantage — mais une interruption longue laisse la source
  en plan exactement comme avant. La fermer proprement suppose de trancher ce
  qu'il advient de la reprise automatique quand le flux doit d'abord être
  re-préparé ; cela mérite sa propre version plutôt qu'un changement au passage.

## 0.1.6

Version d'hygiène — aucun changement de comportement sur la lecture, les
métadonnées ou la reconnexion. Zéro avertissement et zéro info de l'analyseur,
déclaration de la seule plateforme réellement existante, et passage du build
Android au Kotlin DSL avec le bloc `plugins` déclaratif.

### RUPTURE (empaquetage et environnement, pas API)
* Environnement minimal relevé à **Flutter 3.47 / Dart ^3.13**, contre
  Flutter 3.44 / Dart ^3.12. Le Kotlin intégré sous AGP 9 demande Flutter 3.47,
  et rester en dessous aurait maintenu l'échappatoire
  `android.builtInKotlin=false` — celle-là même qu'AGP 10 supprime.
* Le plugin ne déclare plus que **Android** dans `pubspec.yaml`. `ios`,
  `macos`, `windows`, `linux` et `web` ne sont plus déclarés : ces dossiers ne
  contiennent que le squelette de `flutter create` (`getPlatformVersion` et
  rien d'autre). Les déclarer faisait enregistrer un plugin qui ne répondait à
  aucune méthode, et chaque appel remontait une `MissingPluginException`. Les
  sources sont conservées comme point de départ des portages — il suffira de
  réintroduire l'entrée correspondante.
* `ArtworkCache.diskCacheDuration` et `ArtworkCache.diskCacheDir` deviennent
  des champs publics (ils étaient privés et seulement affectés). Classe
  interne, sans impact sur les applications hôtes.

### Ajouté
* `RadioService.isPlatformSupported` — vrai sur Android, faux ailleurs.
* Sur une plateforme non gérée, `setUrl()` émet désormais un `PlayerError`
  nommant la plateforme, au lieu de laisser remonter une
  `MissingPluginException` depuis les profondeurs du canal.
* L'appel `configure()` du constructeur, lancé sans être attendu, est protégé :
  son échec est journalisé au lieu de devenir une erreur asynchrone non
  capturée. Construire `RadioService` sur iOS ou desktop levait hors pile.

### Build Android — Kotlin DSL et nouveau DSL AGP
* `android/build.gradle` (Groovy) remplacé par `android/build.gradle.kts`, et
  `android/settings.gradle` par `android/settings.gradle.kts`.
* Le bloc déclaratif `plugins { id("com.android.library") }` remplace
  `apply plugin:`, et le `buildscript { classpath(AGP/KGP) }` du module
  disparaît : le module du plugin est un sous-projet du build de
  l'application, donc les versions viennent du `pluginManagement` de l'app.
  L'ancien fichier épinglait une seconde version d'AGP pour rien.
* `dependencies { }` sort du bloc `android { }`, où il ne fonctionnait que par
  une délégation Groovy.
* `android.newDsl=false` et `android.builtInKotlin=false` retirés du
  `gradle.properties` de l'exemple. Les deux échappatoires disparaissent avec
  AGP 10, et le passage à Flutter 3.47 débloque le Kotlin intégré. Le module
  du plugin n'applique aucun Kotlin Gradle Plugin en propre — AGP le fournit.
* Media3 monté en 1.11.1.

### Nettoyage — analyseur à zéro
* Imports redondants supprimés (`dart:typed_data` couvert par
  `package:flutter/foundation.dart`, `player_state` / `player_position`
  couverts par l'interface de plateforme, imports inutilisés de l'interface de
  plateforme dont les `export` restent).
* `MethodChannelRadioService` utilise les éléments de map null-aware
  (`'clé': ?valeur`) au lieu des entrées `if (x != null)`.
* `ArtworkCache` utilise des paramètres d'initialisation.
* Accolades ajoutées autour des `if` d'une seule instruction dans
  `MetadataPoller` et `RadioService`.
* Chevrons échappés dans les commentaires de documentation d'`IcyStreamReader`.
* Les tests importent via `package:radio_service/…` au lieu de chemins
  relatifs `../lib/` ; un paramètre de stub mort et un import redondant
  supprimés.
* La vingtaine de constantes de flux éparses de l'exemple est regroupée dans
  une table `_streams` réellement utilisée — rien de perdu, une seule ligne
  (`_selected`) à changer pour tester une autre radio. Le test d'intégration
  vide est devenu un vrai fumigène construction / libération.

### Divers
* Les podspecs iOS et macOS ne sont plus le gabarit généré (version, résumé,
  description, page d'accueil, auteur) et disent clairement que la plateforme
  n'est pas encore implémentée.

## 0.1.5

### RUPTURE
* Nouveau membre `PlayerInterrupted` dans la classe scellée `PlayerState`.
  Tout `switch` exhaustif sur `PlayerState` dans l'application hôte **cesse de
  compiler** tant que le nouveau cas n'est pas traité. C'est voulu : l'échec
  se produit à la compilation et non à l'écran chez la personne. À traiter
  comme « reconnexion en cours » — ce n'est ni un arrêt demandé, ni une
  station cassée.
* Les hôtes doivent passer leur dépendance en `v0.1.5` puis lancer
  `flutter pub get` (le cache git de pub est agressif : au besoin
  `flutter pub cache repair`, ou supprimer l'entrée dans `PubCache/git/`).

### Corrigé — le verrou « source error » après une coupure réseau
* Un arrêt de flux resté en vol pouvait annuler le flux qui l'avait remplacé.
  `_stopStream()` écrivait ses champs partagés (`_icyReader`, `_proxy`)
  *après* ses `await` : un arrêt déclenché pendant un incident réseau
  reprenait la main une fois la station suivante démarrée — et arrêtait ce
  proxy tout neuf. ExoPlayer n'était plus alimenté et rendait un
  `source error` sur une station parfaitement saine. C'est le « la source
  error bloque les autres radios » signalé. Les champs partagés sont
  désormais détachés avant le premier `await`.
* Deux boucles de reconnexion pouvaient tourner en parallèle.
  `IcyStreamReader` se rappelait lui-même via `Future.delayed` et en fin de
  flux, gardé par le seul booléen partagé `_running` ; une reprise réveillée
  juste après `start()` le voyait à `true`, se croyait légitime et se
  reconnectait — sur l'URL de la *nouvelle* station, en parallèle de la vraie
  boucle. Les deux écrivaient `_sub` et `_client`, et l'orpheline continuait
  de pousser ses octets dans le proxy. Le lecteur exécute désormais une boucle
  unique, gardée par un jeton de génération que chaque reprise asynchrone et
  chaque callback compare avant d'agir.
* Les closures de `RadioService` (`onAudioBytes`, `onMetadata`, `onConnected`,
  `onUnavailable`, watchdog premier octet) lisaient le champ partagé `_proxy`
  au lieu de l'instance pour laquelle elles avaient été créées : un lecteur
  périmé pouvait donc pousser dans le proxy de la station suivante. Elles
  capturent maintenant l'instance de proxy et un jeton de génération de flux.
* `AudioProxyServer` présentait le même motif d'écriture tardive dans
  `stop()`, et `_handleRequest()` pouvait remettre à null un
  `_currentRequest` appartenant à une connexion plus récente.
* La pochette résolue pouvait installer l'image d'un titre périmé comme
  fallback de notification quand le téléchargement survivait au titre.

### Modifié — politique de reconnexion
* **Plus de plafond de tentatives.** Le plugin se reconnecte tant que la
  personne n'a pas arrêté la lecture. L'ancienne politique abandonnait
  définitivement après 5 tentatives (15 à 65 secondes) — moins qu'un tunnel,
  qu'un ascenseur ou qu'un changement de cellule, et plus rien ne retentait
  ensuite.
* **Recul croissant et borné** : 1 s, 2 s, 4 s, 8 s, puis 15 s répété. On ne
  martèle pas un réseau absent, et on ne fait pas attendre une minute quand il
  revient au bout de trois secondes.
* `onError` (coupure en cours de flux) et `onDone` (fin de flux propre)
  reçoivent désormais le même traitement. La dissymétrie précédente — une
  coupure comptait dans le plafond, une fin propre remettait le compteur à
  zéro — était un accident, pas une intention.
* `IcyStreamReader.onUnavailable` ne dit plus « j'abandonne » mais « ça fait
  un moment que je n'y arrive pas ». C'est un avis pour l'interface : il ne
  coupe plus ni le lecteur ni le proxy, et la boucle continue de retenter
  derrière.
* Le watchdog « premier octet » (15 s) émet désormais `PlayerInterrupted` au
  lieu de `PlayerError`, et ne coupe plus rien.
* `player.stop()` arrête maintenant aussi la couche réseau Dart (lecteur +
  proxy) avant l'arrêt natif. Sans cela, la reconnexion sans plafond aurait
  continué à consommer données et batterie après un arrêt volontaire. Le site
  d'appel ne change pas.

### Ajouté
* État `PlayerInterrupted` — la lecture est interrompue et le plugin retente.
  La sortie de cet état ne demande aucun événement explicite : ExoPlayer
  réémet `PlayerPlaying` dès que les octets repartent.
* `RadioService.retryNow()` — raccourcit le recul en cours et retente
  immédiatement. Pour les hôtes qui savent que le réseau est revenu (module de
  connectivité) avant que le plugin ne s'en aperçoive. Strictement optionnel :
  la lecture repart toute seule sans cet appel, simplement plus tard.

### Divers
* `IcyStreamReader` ferme le `HttpClient` de la tentative précédente à chaque
  tentative. Chaque tentative en créait un et `stop()` n'en fermait qu'un.
* `AudioProxyServer.stop()` ferme son `StreamController _queue`, qui ne
  l'était jamais.
* `icy-metaint` n'est plus un champ d'instance mais lu par réponse : deux
  connexions ne peuvent plus désaligner la séparation audio / métadonnées.
* Un `stop()` pendant une lecture active ne laisse plus la lecture suspendue
  pour toujours (annuler un abonnement ne déclenche ni `onDone` ni `onError`).
* Nouveau banc `test/stream_reconnect_test.dart` couvrant la politique de
  reconnexion et le jeton de génération face à un serveur ICY local.

### Plateformes
* Aucun changement natif — le côté Android n'était pas en cause.
* L'implémentation web est inchangée : la surface de l'interface de
  plateforme n'a pas bougé (`retryNow` et `PlayerInterrupted` vivent tous deux
  dans la couche Dart).

## 0.1.4

### Maintenance
* Toolchain Android mise à jour vers les versions testées avec Flutter 3.44.6 :
  Android Gradle Plugin 9.2.1 et Kotlin 2.4.10. Les avertissements de
  compatibilité du Kotlin Gradle Plugin (KGP) émis par les versions
  précédentes de Flutter ont disparu.
* Dépendances natives montées : Media3 1.10.1, androidx.core-ktx 1.19.0,
  kotlinx-coroutines 1.11.0 et Mockito 5.23.0 (tests).
* Dépendances Dart montées : web 1.1.1, plugin_platform_interface 2.1.8,
  http 1.6.0, path_provider 2.1.6.

## 0.0.3

### Corrections
* Ajout de la ressource manquante `network_security_config.xml` dans
  `android/src/main/res/xml/`. Le manifeste Android référençait
  `@xml/network_security_config`, mais le fichier n'existait que dans l'appli
  d'exemple, ce qui faisait échouer les builds release à l'édition de liens des
  ressources (`verifyReleaseResources` : « resource xml/network_security_config
  not found »). La configuration autorise le HTTP en clair uniquement vers le
  proxy audio local (127.0.0.1 / localhost) ; tout autre trafic reste en HTTPS.

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
