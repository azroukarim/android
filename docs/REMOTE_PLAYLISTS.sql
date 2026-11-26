-- Streamplayer — envoi de playlists à distance
-- À exécuter une seule fois dans Supabase → SQL Editor.
-- Prérequis : la fonction public.is_admin() et la table public.admins
-- existent déjà (voir docs/README.md, section 2).

create table if not exists public.remote_playlists (
  id uuid primary key default gen_random_uuid(),
  device_fingerprint text not null,
  device_key text not null,
  type text not null check (type in ('xtream', 'm3u', 'stalker')),
  name text not null default '',
  url text not null default '',
  username text not null default '',
  password text not null default '',
  mac text not null default '',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  delivered_at timestamptz
);

create index if not exists remote_playlists_pending_idx
  on public.remote_playlists (lower(device_fingerprint), device_key, created_at)
  where delivered_at is null;

alter table public.remote_playlists enable row level security;

drop policy if exists "admins manage remote playlists" on public.remote_playlists;
create policy "admins manage remote playlists"
  on public.remote_playlists
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- The app calls these two functions with the publishable key. They are the
-- only anonymous entry points: a row can only be read with the exact MAC and
-- Device Key pair, and is marked delivered only after the app saved it.
create or replace function public.pull_remote_playlists(
  p_fingerprint text,
  p_key text
)
returns setof public.remote_playlists
language sql
security definer
set search_path = public
as $$
  select *
  from public.remote_playlists
  where lower(device_fingerprint) = lower(trim(p_fingerprint))
    and device_key = trim(p_key)
    and is_active
    and delivered_at is null
  order by created_at
  limit 10;
$$;

create or replace function public.ack_remote_playlist(
  p_id uuid,
  p_fingerprint text,
  p_key text
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.remote_playlists
  set delivered_at = now()
  where id = p_id
    and lower(device_fingerprint) = lower(trim(p_fingerprint))
    and device_key = trim(p_key)
    and delivered_at is null;
$$;

revoke all on function public.pull_remote_playlists(text, text) from public;
revoke all on function public.ack_remote_playlist(uuid, text, text) from public;
grant execute on function public.pull_remote_playlists(text, text) to anon, authenticated;
grant execute on function public.ack_remote_playlist(uuid, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Portail isolé du boîtier (device.html)
-- ---------------------------------------------------------------------------
-- L'accès est conditionné uniquement à la paire MAC + Device Key fournie par
-- l'application. Aucun mot de passe supplémentaire n'est demandé.

-- Nettoyage d'une éventuelle version précédente (3 arguments avec mot de passe)
-- pour éviter que PostgREST continue à exposer l'ancienne signature.
drop function if exists public.device_portal_set_password(text, text, text);
drop function if exists public.device_portal_login(text, text, text);
drop function if exists public.device_portal_list(text, text, text);
drop function if exists public.device_portal_save(uuid, text, text, text, text, text, text, text, text, text);
drop function if exists public.device_portal_delete(uuid, text, text, text);
drop function if exists public.device_portal_resend(uuid, text, text, text);
drop table if exists public.device_secrets;

-- Device Keys modifiables depuis le portail. La clé d'origine est conservée
-- comme « previous_key » pour que le boîtier puisse encore récupérer la
-- nouvelle clé avec son ancienne valeur au prochain démarrage.
create table if not exists public.device_key_overrides (
  device_fingerprint text primary key,
  device_key text not null,
  previous_key text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.device_key_overrides enable row level security;

create or replace function public.device_portal_authorized(
  p_fingerprint text,
  p_key text
)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.remote_playlists
    where lower(device_fingerprint) = lower(trim(p_fingerprint))
      and device_key = trim(p_key)
  ) or exists (
    select 1 from public.device_key_overrides o
    where lower(o.device_fingerprint) = lower(trim(p_fingerprint))
      and trim(p_key) in (o.device_key, o.previous_key)
      and exists (
        select 1 from public.licenses l
        where lower(l.device_fingerprint) = lower(trim(p_fingerprint))
      )
  ) or (
    not exists (
      select 1 from public.device_key_overrides o
      where lower(o.device_fingerprint) = lower(trim(p_fingerprint))
    )
    and exists (
      select 1 from public.licenses l
      where lower(l.device_fingerprint) = lower(trim(p_fingerprint))
    )
  );
$$;

create or replace function public.device_portal_login(
  p_fingerprint text,
  p_key text
)
returns boolean
language sql
security definer
set search_path = public
as $$
  select public.device_portal_authorized(p_fingerprint, p_key);
$$;

create or replace function public.device_portal_list(
  p_fingerprint text,
  p_key text
)
returns setof public.remote_playlists
language sql
security definer
set search_path = public
as $$
  select r.*
  from public.remote_playlists r
  where lower(r.device_fingerprint) = lower(trim(p_fingerprint))
    and r.device_key = trim(p_key)
    and public.device_portal_authorized(p_fingerprint, p_key)
  order by r.created_at desc;
$$;

create or replace function public.device_portal_save(
  p_id uuid,
  p_fingerprint text,
  p_key text,
  p_type text,
  p_name text,
  p_url text,
  p_username text,
  p_password text,
  p_mac text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.device_portal_authorized(p_fingerprint, p_key) then
    raise exception 'access denied';
  end if;
  if p_type not in ('xtream', 'm3u', 'stalker') then
    raise exception 'invalid server type';
  end if;

  if p_id is null then
    insert into public.remote_playlists
      (device_fingerprint, device_key, type, name, url, username, password, mac, is_active)
    values
      (upper(trim(p_fingerprint)), trim(p_key), p_type,
       coalesce(p_name, ''), coalesce(p_url, ''), coalesce(p_username, ''),
       coalesce(p_password, ''), coalesce(p_mac, ''), true)
    returning id into v_id;
  else
    update public.remote_playlists
    set type = p_type,
        name = coalesce(p_name, ''),
        url = coalesce(p_url, ''),
        username = coalesce(p_username, ''),
        password = coalesce(p_password, ''),
        mac = coalesce(p_mac, ''),
        is_active = true,
        delivered_at = null
    where id = p_id
      and lower(device_fingerprint) = lower(trim(p_fingerprint))
      and device_key = trim(p_key)
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

create or replace function public.device_portal_delete(
  p_id uuid,
  p_fingerprint text,
  p_key text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.device_portal_authorized(p_fingerprint, p_key) then
    raise exception 'access denied';
  end if;
  delete from public.remote_playlists
  where id = p_id
    and lower(device_fingerprint) = lower(trim(p_fingerprint))
    and device_key = trim(p_key);
end;
$$;

create or replace function public.device_portal_resend(
  p_id uuid,
  p_fingerprint text,
  p_key text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.device_portal_authorized(p_fingerprint, p_key) then
    raise exception 'access denied';
  end if;
  update public.remote_playlists
  set delivered_at = null, is_active = true
  where id = p_id
    and lower(device_fingerprint) = lower(trim(p_fingerprint))
    and device_key = trim(p_key);
end;
$$;

revoke all on function public.device_portal_authorized(text, text) from public;
grant execute on function public.device_portal_authorized(text, text) to anon, authenticated;

revoke all on function public.device_portal_login(text, text) from public;
grant execute on function public.device_portal_login(text, text) to anon, authenticated;

revoke all on function public.device_portal_list(text, text) from public;
grant execute on function public.device_portal_list(text, text) to anon, authenticated;

revoke all on function public.device_portal_save(uuid, text, text, text, text, text, text, text, text) from public;
grant execute on function public.device_portal_save(uuid, text, text, text, text, text, text, text, text) to anon, authenticated;

revoke all on function public.device_portal_delete(uuid, text, text) from public;
grant execute on function public.device_portal_delete(uuid, text, text) to anon, authenticated;

revoke all on function public.device_portal_resend(uuid, text, text) from public;
grant execute on function public.device_portal_resend(uuid, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Commandes envoyées au boîtier (modification / suppression d'un serveur local)
-- ---------------------------------------------------------------------------
create table if not exists public.remote_commands (
  id uuid primary key default gen_random_uuid(),
  device_fingerprint text not null,
  device_key text not null,
  action text not null,
  local_id text not null default '',
  type text not null default '',
  name text not null default '',
  url text not null default '',
  username text not null default '',
  password text not null default '',
  mac text not null default '',
  created_at timestamptz not null default now(),
  delivered_at timestamptz
);

-- Migration depuis une version précédente de cette table.
alter table public.remote_commands drop constraint if exists remote_commands_action_check;
alter table public.remote_commands add constraint remote_commands_action_check
  check (action in ('delete_server', 'update_server'));
alter table public.remote_commands add column if not exists type text not null default '';
alter table public.remote_commands add column if not exists name text not null default '';
alter table public.remote_commands add column if not exists url text not null default '';
alter table public.remote_commands add column if not exists username text not null default '';
alter table public.remote_commands add column if not exists password text not null default '';
alter table public.remote_commands add column if not exists mac text not null default '';

alter table public.remote_commands enable row level security;

create index if not exists remote_commands_pending_idx
  on public.remote_commands (lower(device_fingerprint), device_key, created_at)
  where delivered_at is null;

-- File d'attente lue par l'application au démarrage et via « Recevoir une
-- playlist ». Les anciennes commandes en attente pour le même serveur sont
-- remplacées pour éviter d'appliquer des changements périmés.
create or replace function public.device_portal_queue_command(
  p_action text,
  p_fingerprint text,
  p_key text,
  p_local_id text,
  p_type text default null,
  p_name text default null,
  p_url text default null,
  p_username text default null,
  p_password text default null,
  p_mac text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fp text := upper(trim(p_fingerprint));
  v_key text := trim(p_key);
  v_id uuid;
begin
  if not public.device_portal_authorized(p_fingerprint, p_key) then
    raise exception 'access denied';
  end if;
  if p_action not in ('delete_server', 'update_server') then
    raise exception 'invalid command';
  end if;
  if coalesce(p_local_id, '') = '' then
    raise exception 'missing local_id';
  end if;
  if p_action = 'update_server' and (
    lower(coalesce(p_type, '')) not in ('xtream', 'm3u', 'stalker')
    or coalesce(p_url, '') = ''
  ) then
    raise exception 'invalid server';
  end if;
  if p_action = 'update_server' and not exists (
    select 1 from public.device_servers s
    where lower(s.device_fingerprint) = lower(v_fp)
      and s.device_key = v_key
      and s.local_id = p_local_id
  ) then
    raise exception 'unknown local server';
  end if;

  delete from public.remote_commands c
  where lower(c.device_fingerprint) = lower(v_fp)
    and c.device_key = v_key
    and c.local_id = p_local_id
    and c.delivered_at is null;

  insert into public.remote_commands
    (device_fingerprint, device_key, action, local_id,
     type, name, url, username, password, mac)
  values
    (v_fp, v_key, p_action, p_local_id,
     lower(coalesce(p_type, '')), coalesce(p_name, ''), coalesce(p_url, ''),
     coalesce(p_username, ''), coalesce(p_password, ''), coalesce(p_mac, ''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.pull_remote_commands(
  p_fingerprint text,
  p_key text
)
returns setof public.remote_commands
language sql
security definer
set search_path = public
as $$
  select *
  from public.remote_commands
  where lower(device_fingerprint) = lower(trim(p_fingerprint))
    and device_key = trim(p_key)
    and delivered_at is null
  order by created_at
  limit 20;
$$;

create or replace function public.ack_remote_command(
  p_id uuid,
  p_fingerprint text,
  p_key text
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.remote_commands
  set delivered_at = now()
  where id = p_id
    and lower(device_fingerprint) = lower(trim(p_fingerprint))
    and device_key = trim(p_key)
    and delivered_at is null;
$$;

revoke all on function public.device_portal_queue_command(text, text, text, text, text, text, text, text, text, text) from public;
grant execute on function public.device_portal_queue_command(text, text, text, text, text, text, text, text, text, text) to anon, authenticated;

revoke all on function public.pull_remote_commands(text, text) from public;
grant execute on function public.pull_remote_commands(text, text) to anon, authenticated;

revoke all on function public.ack_remote_command(uuid, text, text) from public;
grant execute on function public.ack_remote_command(uuid, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Serveurs configurés dans l'application (remontée boîtier → portail)
-- ---------------------------------------------------------------------------
-- Le boîtier envoie la liste complète de ses serveurs locaux. Le portail les
-- affiche à côté des envois faits depuis le panneau administrateur.

create table if not exists public.device_servers (
  device_fingerprint text not null,
  device_key text not null,
  local_id text not null,
  type text not null check (type in ('xtream', 'm3u', 'stalker')),
  name text not null default '',
  url text not null default '',
  username text not null default '',
  password text not null default '',
  mac text not null default '',
  is_active boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (device_fingerprint, local_id)
);

alter table public.device_servers enable row level security;

create or replace function public.device_report_servers(
  p_fingerprint text,
  p_key text,
  p_servers jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fp text := upper(trim(p_fingerprint));
  v_key text := trim(p_key);
  v_count integer;
begin
  -- The portal may have changed the key: always store reports under the
  -- current one so device.html keeps showing the right pair.
  select coalesce(
    (select o.device_key from public.device_key_overrides o
     where lower(o.device_fingerprint) = lower(v_fp)),
    v_key
  ) into v_key;

  if p_servers is null or jsonb_typeof(p_servers) <> 'array' then
    raise exception 'invalid servers payload';
  end if;
  if not exists (
    select 1 from public.licenses
    where lower(device_fingerprint) = lower(v_fp)
  ) and not exists (
    select 1 from public.remote_playlists
    where lower(device_fingerprint) = lower(v_fp) and device_key = v_key
  ) then
    raise exception 'access denied';
  end if;

  delete from public.device_servers
  where lower(device_fingerprint) = lower(v_fp) and device_key = v_key;

  insert into public.device_servers
    (device_fingerprint, device_key, local_id, type, name, url,
     username, password, mac, is_active, updated_at)
  select
    v_fp,
    v_key,
    s->>'local_id',
    lower(coalesce(s->>'type', 'm3u')),
    coalesce(s->>'name', ''),
    coalesce(s->>'url', ''),
    coalesce(s->>'username', ''),
    coalesce(s->>'password', ''),
    coalesce(s->>'mac', ''),
    coalesce((s->>'is_active')::boolean, true),
    now()
  from jsonb_array_elements(p_servers) as s
  where coalesce(s->>'local_id', '') <> ''
    and lower(coalesce(s->>'type', 'm3u')) in ('xtream', 'm3u', 'stalker');

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Liste unifiée : envois du panneau + serveurs remontés par le boîtier.
create or replace function public.device_portal_servers(
  p_fingerprint text,
  p_key text
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(item order by item->>'created_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', r.id,
      'local_id', r.id::text,
      'source', 'admin',
      'type', r.type,
      'name', r.name,
      'url', r.url,
      'username', r.username,
      'password', r.password,
      'mac', r.mac,
      'is_active', r.is_active,
      'created_at', r.created_at,
      'delivered_at', r.delivered_at
    ) as item
    from public.remote_playlists r
    where lower(r.device_fingerprint) = lower(trim(p_fingerprint))
      and r.device_key = trim(p_key)
      and public.device_portal_authorized(p_fingerprint, p_key)

    union all

    select jsonb_build_object(
      'id', null,
      'local_id', s.local_id,
      'source', 'app',
      'type', coalesce(pending.type, s.type),
      'name', coalesce(pending.name, s.name),
      'url', coalesce(pending.url, s.url),
      'username', coalesce(pending.username, s.username),
      'password', coalesce(pending.password, s.password),
      'mac', coalesce(pending.mac, s.mac),
      'is_active', s.is_active,
      'pending', pending.action is not null,
      'created_at', s.updated_at,
      'delivered_at', null
    ) as item
    from public.device_servers s
    left join lateral (
      select c.action, c.type, c.name, c.url, c.username, c.password, c.mac
      from public.remote_commands c
      where lower(c.device_fingerprint) = lower(s.device_fingerprint)
        and c.device_key = s.device_key
        and c.local_id = s.local_id
        and c.action = 'update_server'
        and c.delivered_at is null
      order by c.created_at desc
      limit 1
    ) as pending on true
    where lower(s.device_fingerprint) = lower(trim(p_fingerprint))
      and s.device_key = trim(p_key)
      and public.device_portal_authorized(p_fingerprint, p_key)
      and not exists (
        select 1
        from public.remote_commands d
        where lower(d.device_fingerprint) = lower(s.device_fingerprint)
          and d.device_key = s.device_key
          and d.local_id = s.local_id
          and d.action = 'delete_server'
          and d.delivered_at is null
      )
      and not exists (
        select 1
        from public.remote_playlists r2
        where lower(r2.device_fingerprint) = lower(s.device_fingerprint)
          and r2.device_key = s.device_key
          and r2.type = s.type
          and r2.url = s.url
          and r2.username = s.username
          and r2.password = s.password
          and r2.mac = s.mac
      )
  ) as rows;
$$;

-- ---------------------------------------------------------------------------
-- Changement de Device Key depuis le panneau / le portail
-- ---------------------------------------------------------------------------
-- clé actuelle pour un boîtier (admin connecté). Sert à ouvrir device.html
-- directement depuis l'identifiant MAC du panneau.
create or replace function public.device_admin_key(
  p_fingerprint text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
begin
  if not public.is_admin() then
    raise exception 'access denied';
  end if;

  select device_key into v_key
  from public.device_key_overrides
  where lower(device_fingerprint) = lower(trim(p_fingerprint));
  if v_key is not null then return v_key; end if;

  select device_key into v_key
  from public.remote_playlists
  where lower(device_fingerprint) = lower(trim(p_fingerprint))
  order by created_at desc
  limit 1;
  if v_key is not null then return v_key; end if;

  select device_key into v_key
  from public.device_servers
  where lower(device_fingerprint) = lower(trim(p_fingerprint))
  order by updated_at desc
  limit 1;
  return coalesce(v_key, '');
end;
$$;

-- Le portail vérifie l'ancienne clé (ou la clé d'origine mémorisée) avant
-- d'enregistrer la nouvelle, puis met toutes les tables à la nouvelle paire.
create or replace function public.device_portal_set_key(
  p_fingerprint text,
  p_key text,
  p_new_key text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fp text := upper(trim(p_fingerprint));
  v_old text := trim(p_key);
  v_new text := trim(p_new_key);
  v_previous text;
begin
  if v_new !~ '^[0-9]{6}$' then
    raise exception 'invalid device key';
  end if;
  if not public.device_portal_authorized(p_fingerprint, p_key) then
    raise exception 'access denied';
  end if;

  select device_key into v_previous
  from public.device_key_overrides
  where lower(device_fingerprint) = lower(v_fp);
  v_previous := coalesce(v_previous, v_old);

  insert into public.device_key_overrides
    (device_fingerprint, device_key, previous_key, created_at, updated_at)
  values (v_fp, v_new, v_previous, now(), now())
  on conflict (device_fingerprint) do update
    set device_key = excluded.device_key,
        previous_key = excluded.previous_key,
        updated_at = now();

  update public.remote_playlists
  set device_key = v_new
  where lower(device_fingerprint) = lower(v_fp);

  update public.device_servers
  set device_key = v_new
  where lower(device_fingerprint) = lower(v_fp);

  update public.remote_commands
  set device_key = v_new
  where lower(device_fingerprint) = lower(v_fp);

  return true;
end;
$$;

-- Appelé par le boîtier au démarrage avec sa clé courante (ou l'ancienne clé
-- mémorisée) ; renvoie la nouvelle clé à adopter, ou une chaîne vide.
create or replace function public.device_key_fetch(
  p_fingerprint text,
  p_key text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
begin
  if not public.device_portal_authorized(p_fingerprint, p_key) then
    return '';
  end if;
  select device_key into v_key
  from public.device_key_overrides
  where lower(device_fingerprint) = lower(trim(p_fingerprint));
  return coalesce(v_key, '');
end;
$$;

revoke all on function public.device_admin_key(text) from public;
grant execute on function public.device_admin_key(text) to authenticated;

revoke all on function public.device_portal_set_key(text, text, text) from public;
grant execute on function public.device_portal_set_key(text, text, text) to anon, authenticated;

revoke all on function public.device_key_fetch(text, text) from public;
grant execute on function public.device_key_fetch(text, text) to anon, authenticated;

revoke all on function public.device_report_servers(text, text, jsonb) from public;
grant execute on function public.device_report_servers(text, text, jsonb) to anon, authenticated;

revoke all on function public.device_portal_servers(text, text) from public;
grant execute on function public.device_portal_servers(text, text) to anon, authenticated;

-- Force PostgREST to refresh its schema cache immediately.
notify pgrst, 'reload schema';
