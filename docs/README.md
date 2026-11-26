# Panneau d'activation Streamplayer

Panneau statique (HTML/JS) hébergé par GitHub Pages et connecté à Supabase.

## 1. Créer le compte administrateur

Dans Supabase :

1. **Authentication → Users → Add user**
2. Email : `mohammedridaeltaoilib@gmail.com`
3. Choisissez un mot de passe et cochez **Auto Confirm User**.

## 2. Créer la table des administrateurs et les policies

Dans **SQL Editor**, exécutez :

```sql
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);

alter table public.admins enable row level security;

drop policy if exists "admins can read themselves" on public.admins;
create policy "admins can read themselves"
  on public.admins for select
  to authenticated
  using (user_id = auth.uid());

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admins where user_id = auth.uid()
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

drop policy if exists "admins read licenses" on public.licenses;
create policy "admins read licenses" on public.licenses
  for select to authenticated using (public.is_admin());

drop policy if exists "admins insert licenses" on public.licenses;
create policy "admins insert licenses" on public.licenses
  for insert to authenticated with check (public.is_admin());

drop policy if exists "admins update licenses" on public.licenses;
create policy "admins update licenses" on public.licenses
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "admins delete licenses" on public.licenses;
create policy "admins delete licenses" on public.licenses
  for delete to authenticated using (public.is_admin());

insert into public.admins (user_id, email)
select id, email
from auth.users
where email = 'mohammedridaeltaoilib@gmail.com'
on conflict (user_id) do nothing;
```

## 3. Activer GitHub Pages

Dépôt `azroukarim/android` :

1. **Settings → Pages**
2. Source : **Deploy from a branch**
3. Branche : `main`, dossier : `/docs`
4. **Save**

Le panneau sera disponible à :

```
https://azroukarim.github.io/android/
```

## 4. Utilisation

- Connectez-vous avec l'email/mot de passe administrateur.
- Ajoutez la MAC ou l'ANDROID_ID affiché par l'application (le client peut
  aussi envoyer le QR code WhatsApp affiché sur l'écran d'activation).
- `Activer` / `Désactiver` contrôle l'accès du boîtier.
- Renseignez `expires_at` pour une activation limitée dans le temps : l'écran
  Playlist du boîtier affiche alors les jours restants. Laissez la colonne vide
  pour une activation illimitée.
- Durées rapides : sur le formulaire d'ajout comme dans la liste, choisissez
  `+ 2 heures`, `+ 24 heures`, `+ 12 mois`, `Jusqu'à 2200` ou `Illimité`.
  Les durées s'ajoutent à la date existante si elle est encore dans le futur,
  donc « + 2 heures » prolonge un abonnement au lieu de le raccourcir.
- **Modifier** ouvre une fenêtre avec tous les champs de la licence
  (`device_fingerprint`, `license_key`, notes, date d'activation, expiration,
  actif/inactif) ; l'enregistrement met à jour la ligne en conservant son `id`.
- La table affiche les colonnes **Activation** et **Expiration** côte à côte.
- La suppression est définitive.

## 5. Envoi de playlists à distance

1. Exécutez `docs/REMOTE_PLAYLISTS.sql` dans **SQL Editor** (une seule fois).
2. Sur le boîtier, ouvrez **Compte** : notez l'**Identifiant** (MAC dérivée) et
   la **Clé appareil** (6 chiffres).
3. Dans le panneau, section **Envoyer une playlist à distance**, saisissez ces
   deux valeurs et le serveur :
   - **Xtream** : URL du serveur + utilisateur + mot de passe (ou collez un lien
     `get.php?...` complet dans le champ URL) ;
   - **M3U** : lien complet de la playlist ;
   - **MAG / Stalker** : URL du portail + MAC `00:1A:79:…`.
4. Le boîtier importe la playlist à son prochain démarrage, l'active et
   l'affiche sur l'écran Home. La ligne passe à **Livrée** ; **Renvoyer** remet
   l'envoi en attente.

La table `remote_playlists` est protégée par RLS (admin uniquement). Le boîtier
ne peut lire que ses propres lignes, avec le couple MAC + Clé appareil exact,
via les fonctions `pull_remote_playlists` et `ack_remote_playlist`.

> Le panneau utilise uniquement la clé **publishable**. Les policies RLS
> n'autorisent que les comptes présents dans `public.admins`. Ne mettez jamais
> la clé `secret` / `service_role` dans ce fichier.
