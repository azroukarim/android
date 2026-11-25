# Streamplayer — build 5.3.76

APK de production pour Android TV / Google TV / Fire TV, téléphones et tablettes.

## Téléchargement

| Fichier | Architecture |
| --- | --- |
| [`Streamplayer_v5.3.76_arm32.apk`](https://github.com/azroukarim/android/raw/main/Streamplayer_v5.3.76_arm32.apk) | `armeabi-v7a` (boîtiers TV 32 bits) |
| [`Streamplayer_v5.3.76_arm64.apk`](https://github.com/azroukarim/android/raw/main/Streamplayer_v5.3.76_arm64.apk) | `arm64-v8a` (téléphones/tablettes et TV 64 bits) |
| [`Streamplayer_v5.3.76_x86_64.apk`](https://github.com/azroukarim/android/raw/main/Streamplayer_v5.3.76_x86_64.apk) | `x86_64` (émulateurs / WSA / TV x86) |

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
Voir `docs/README.md` pour l'installation et les policies SQL.

## Activation

L'application vérifie la licence **à chaque ouverture** auprès de Supabase.
Si le boîtier n'est pas autorisé, l'écran d'activation s'affiche aux couleurs de
l'application avec :

- un **QR code WhatsApp** (`+212 670 965 351`) pour contacter le propriétaire ;
- l'identifiant du boîtier (MAC si disponible, sinon `ANDROID_ID`).

L'administrateur ajoute cet identifiant dans Supabase (ou via le panneau) :

- Table : `licenses`
- Colonne : `device_fingerprint`
- `is_active` : `true`
- `expires_at` (optionnel) : date d'expiration de l'activation

L'écran **Playlist** affiche les jours d'activation restants
(`Activation : 364 jours restants`, ou `illimitée` si `expires_at` est vide).

## Nouveautés 5.3.76

- Écran d'activation aux couleurs de l'application (fond, carte rouge, accents)
  avec QR code WhatsApp du propriétaire.
- Jours d'activation restants affichés dans l'écran Playlist.
- Vérification de la licence en ligne à chaque ouverture (plus de blocage lié
  au cache local).
- Épisodes Stalker / portails restream affichés et lisibles.
- Barre de seek du lecteur : pas de 30 s (boutons ±10 s conservés).
