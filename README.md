# Streamplayer — build 5.3.80

APK de production pour Android TV / Google TV / Fire TV, téléphones et tablettes.

## Téléchargement

| Fichier | Architecture |
| --- | --- |
| [`Streamplayer_v5.3.80_arm32.apk`](https://github.com/azroukarim/android/raw/main/Streamplayer_v5.3.80_arm32.apk) | `armeabi-v7a` (boîtiers TV 32 bits) |
| [`Streamplayer_v5.3.80_arm64.apk`](https://github.com/azroukarim/android/raw/main/Streamplayer_v5.3.80_arm64.apk) | `arm64-v8a` (téléphones/tablettes et TV 64 bits) |
| [`Streamplayer_v5.3.80_x86_64.apk`](https://github.com/azroukarim/android/raw/main/Streamplayer_v5.3.80_x86_64.apk) | `x86_64` (émulateurs / WSA / TV x86) |

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
- l'identifiant du boîtier : **MAC dérivé stable** en premier (format
  `AA:BB:CC:DD:EE:FF`), puis la vraie MAC Ethernet si le système l'expose,
  puis l'`ANDROID_ID` en secours.

L'administrateur ajoute cet identifiant dans Supabase (ou via le panneau) :

- Table : `licenses`
- Colonne : `device_fingerprint`
- `is_active` : `true`
- `expires_at` (optionnel) : date d'expiration de l'activation

L'écran **Playlist** affiche la durée restante
(`Activation : 364 jours restants`, `Activation : 2 h restantes`, ou
`illimitée` si `expires_at` est vide).

## Nouveautés 5.3.80

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
