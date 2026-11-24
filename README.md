# Streamplayer — build 5.3.75

APK de production pour Android TV / Google TV / Fire TV, téléphones et tablettes.

## Téléchargement

Les APK sont attachés à la release GitHub :

**https://github.com/azroukarim/android/releases/tag/v5.3.75**

| Fichier | Architecture |
| --- | --- |
| `Streamplayer_v5.3.75_arm32.apk` | `armeabi-v7a` (boîtiers TV 32 bits) |
| `Streamplayer_v5.3.75_arm64.apk` | `arm64-v8a` (téléphones/tablettes et TV 64 bits) |
| `Streamplayer_v5.3.75_x86_64.apk` | `x86_64` (émulateurs / WSA / TV x86) |

## Mise à jour automatique

L'application lit :

```
https://raw.githubusercontent.com/azroukarim/android/main/version.json
```

`version.json` contient la version, les notes, le SHA-256 et l'URL de chaque APK.
Les sommes sont aussi disponibles dans `SHA256SUMS`.

## Panneau d'activation

**https://azroukarim.github.io/android/**

Panneau statique connecté à Supabase (authentification administrateur + RLS).
Voir `docs/README.md` pour l'installation et les policies SQL.

## Activation

Au premier lancement, l'application affiche les identifiants du boîtier
(MAC si disponible, sinon `ANDROID_ID`). L'administrateur ajoute cet identifiant
dans Supabase (ou via le panneau) :

- Table : `licenses`
- Colonne : `device_fingerprint`
- `is_active` : `true`

Puis l'utilisateur appuie sur **Vérifier l'activation**. Une vérification
réussie reste valable 7 jours hors ligne.

## Nouveautés 5.3.75

- Activation par boîtier via Supabase (MAC / ANDROID_ID).
- Panneau d'administration des activations.
- Épisodes Stalker / portails restream affichés et lisibles.
- Barre de seek du lecteur : pas de 30 s (boutons ±10 s conservés).
