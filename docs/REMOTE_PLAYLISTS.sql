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
    select 1 from public.licenses
    where lower(device_fingerprint) = lower(trim(p_fingerprint))
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

-- Force PostgREST to refresh its schema cache immediately.
notify pgrst, 'reload schema';
