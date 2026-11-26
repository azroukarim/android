# Streamplayer — build 5.3.83

APK de production pour Android TV / Google TV / Fire TV, téléphones et tablettes.

## Téléchargement

| Fichier | Architecture |
| --- | --- |
| [`Streamplayer_v5.3.83_arm32.apk`](https://github.com/azroukarim/android/raw/main/Streamplayer_v5.3.83_arm32.apk) | `armeabi-v7a` (boîtiers TV 32 bits) |
| [`Streamplayer_v5.3.83_arm64.apk`](https://github.com/azroukarim/android/raw/main/Streamplayer_v5.3.83_arm64.apk) | `arm64-v8a` (téléphones/tablettes et TV 64 bits) |
| [`Streamplayer_v5.3.83_x86_64.apk`](https://github.com/azroukarim/android/raw/main/Streamplayer_v5.3.83_x86_64.apk) | `x86_64` (émulateurs / WSA / TV x86) |

## Mise à jour automatique

L'application lit :

```
https://raw.githubusercontent.com/azroukarim/android/main/version.json
```

`version.json` contient la version, les notes et le SHA-256 de chaque APK.
Les sommes sont aussi disponibles dans `SHA256SUMS`.

## Panneau d'activation

**https://azroukarim.github.io/android/**

Panneau statique connecté à Supabase (authentification administrateur + RLS).
Durées rapides disponibles : **2 heures**, **24 heures**, **12 mois**,
**jusqu'à 2200** ou **illimité**. Voir `docs/README.md` pour l'installation et
les policies SQL.

## Activation

L'application vérifie la licence **à chaque ouverture** auprès de Supabase.
Si le boîtier n'est pas autorisé, l'écran d'activation s'affiche aux couleurs de
l'application avec :

- un **QR code WhatsApp** (`+212 670 965 351`) pour contacter le propriétaire ;
- **un seul identifiant affiché** : la **MAC dérivée de l'`ANDROID_ID`**
  (format `AA:BB:CC:DD:EE:FF`). C'est celle qui change après une remise à zéro
  du boîtier ; les vraies MAC et l'`ANDROID_ID` restent envoyées au serveur
  comme secours pour les anciennes licences, mais ne sont plus affichées.

L'administrateur ajoute cet identifiant dans Supabase (ou via le panneau) :

- Table : `licenses`
- Colonne : `device_fingerprint`
- `is_active` : `true`
- `expires_at` (optionnel) : date d'expiration de l'activation

L'écran **Playlist** affiche la durée restante
(`Activation : 364 jours restants`, `Activation : 2 h restantes`, ou
`illimitée` si `expires_at` est vide).

## Envoi de playlists à distance

Le panneau **https://azroukarim.github.io/android/** permet d'envoyer un
serveur **Xtream**, un lien **M3U** ou un portail **MAG / Stalker** à un boîtier
précis :

1. Exécuter une fois `docs/REMOTE_PLAYLISTS.sql` dans Supabase → SQL Editor.
2. Sur le boîtier : **Compte** affiche l'**Identifiant** (MAC) et la
   **Clé appareil** (6 chiffres).
3. Dans le panneau : section **Envoyer une playlist à distance**, saisir la MAC,
   la clé et le serveur.
4. Le boîtier importe et active la playlist à son prochain démarrage (ou via
   **Compte → Recevoir une playlist**).

### Portail isolé du boîtier

**https://azroukarim.github.io/android/device.html**

Le client y saisit **MAC + Device Key + mot de passe d'accès** (défini par
l'administrateur dans le panneau principal). Il voit alors tous les serveurs
Xtream / M3U / MAG de son boîtier, peut les modifier, en ajouter, les renvoyer
ou les supprimer. Les mots de passe Xtream restent masqués jusqu'à un clic
explicite. Voir `docs/README.md`, section 6.

### Identité dans le gestionnaire local

Le gestionnaire ouvert depuis le QR code (`http://192.168.0.95:8089`) affiche
désormais, en haut de page, **l'adresse locale**, la **MAC Address** et la
**Device Key** du boîtier, avec des boutons **Copier** et un lien direct vers le
portail isolé. La même paire apparaît dans l'application, à côté du QR code,
dans **Changer la liste → QR / gestion Web**.

## Nouveautés 5.3.83

- **Portail isolé `device.html`** : accès par MAC + Device Key + mot de passe,
  avec consultation, modification, ajout, renvoi et suppression des serveurs du
  boîtier. Les secrets ne sont visibles qu'après déverrouillage.
- **Identité dans le gestionnaire local** : la MAC et la Device Key sont
  affichées à côté de `http://192.168.0.95:8089`, et également à côté du QR code
  dans **Changer la liste**.
- **Clé appareil à 6 chiffres** : dérivée elle aussi de l'`ANDROID_ID`, affichée
  sur l'écran d'activation et dans **Compte**. Elle change uniquement après une
  remise à zéro, comme la MAC dérivée.
- **Envoi de playlist à distance** : le panneau web pousse un serveur Xtream,
  un lien M3U ou un portail MAG vers un boîtier identifié par sa MAC + sa clé.
  Le boîtier importe la playlist au démarrage et marque l'envoi comme livré.
- **Écran d'activation épuré** : un seul identifiant visible, la MAC dérivée
  qui change après chaque formatage du boîtier. Les autres candidats restent
  transmis au serveur pour ne pas casser les licences existantes.
- **Identifiant stable au format MAC**, dérivé de l'`ANDROID_ID` : il survit aux
  mises à jour, à l'effacement des données et aux réinstallations ; il ne change
  qu'après une remise à zéro du boîtier.
- **Expiration vérifiée avec l'heure du serveur** : un licenciement de 2 heures
  s'arrête vraiment après 2 heures, même si le boîtier est hors ligne.
- **Protection contre le recul de l'horloge** : un retour de plus de 6 heures
  invalide le cache local.
- Tolérance hors ligne ramenée de 7 à **3 jours**.
- Durées courtes affichées en **heures et minutes**.
- Panneau d'activation : durées rapides **2 h / 24 h / 12 mois / 2200 /
  illimité**, aussi bien à l'ajout que sur chaque ligne existante.

## Nouveautés 5.3.77

- Ajout de playlist à la télécommande : DOWN depuis le dernier champ atteint
  **Enregistrer**, le clavier tactile se masque sans perdre le focus, OK
  sauvegarde l'abonnement et reste sur la liste des playlists.
- DOWN depuis un sélecteur de mode (M3U / Xtream / MAG) ouvre directement le
  premier champ du formulaire.

## Nouveautés 5.3.76

- Écran d'activation aux couleurs de l'application (fond, carte rouge, accents)
  avec QR code WhatsApp du propriétaire.
- Jours d'activation restants affichés dans l'écran Playlist.
- Vérification de la licence en ligne à chaque ouverture (plus de blocage lié
  au cache local).
- Épisodes Stalker / portails restream affichés et lisibles.
- Barre de seek du lecteur : pas de 30 s (boutons ±10 s conservés).
