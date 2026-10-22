-- ===========================================================================
-- Discord: link House Board accounts to the house Discord server, and mirror
-- the noticeboard into #noticeboard.
--
-- Run once in Supabase -> SQL Editor. Safe to re-run. Contains no secrets.
-- The Discord secrets live in the Edge Function's secrets, never in here.
-- ===========================================================================

-- Who each member is on Discord.
alter table members add column if not exists discord_id   text unique;
alter table members add column if not exists discord_name text;
-- Name of their role on the Discord server. Empty = use their first name.
alter table members add column if not exists discord_role text;

-- The manager's Discord role is "Joey", not their House Board name.
update members set discord_role = 'Joey' where role = 'manager' and discord_role is null;

-- Which Discord message shows which noticeboard post, so edits and deletes
-- on the board can follow it to Discord. Only the Edge Function touches this.
create table if not exists discord_posts (
  note_id    text primary key,
  message_id text not null,
  updated_at timestamptz default now()
);
alter table discord_posts enable row level security;   -- no policies: invisible to the public API

-- ---------------------------------------------------------------------------
-- Only the Edge Function (which holds the secret key) may call the functions
-- below. They check for it themselves, so even a later
-- "grant execute on all functions ... to anon" can't open them up.
-- ---------------------------------------------------------------------------
create or replace function is_server()
returns boolean language sql stable as $$
  select coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') = 'service_role';
$$;

-- Checks a House Board code exactly like sign_in does (same lockout against
-- guessing), then links that member to a Discord account.
-- Returns what the Edge Function needs to give them the right role.
create or replace function discord_link(p_code text, p_discord_id text, p_discord_name text)
returns table (name text, role text, discord_role text)
language plpgsql security definer set search_path = public as $$
declare me members;
begin
  if not is_server() then raise exception 'Not allowed'; end if;

  if (select count(*) from sign_in_log where not ok and at > now() - interval '5 minutes') > 20 then
    raise exception 'Too many failed sign-ins just now. Try again in five minutes.';
  end if;

  select * into me from members m where m.code = p_code and m.status = 'active';
  insert into sign_in_log (ok) values (me.id is not null);
  if me.id is null then raise exception 'Your House Board sign-in has expired. Sign in again.'; end if;

  -- one Discord account per member, and one member per Discord account
  update members set discord_id = null, discord_name = null
   where discord_id = p_discord_id and id <> me.id;
  update members set discord_id = p_discord_id, discord_name = p_discord_name where id = me.id;

  return query select me.name, me.role, me.discord_role;
end; $$;

-- Member names by id, for showing who wrote a noticeboard post.
create or replace function discord_names()
returns table (id uuid, name text)
language plpgsql security definer set search_path = public as $$
begin
  if not is_server() then raise exception 'Not allowed'; end if;
  return query select m.id, m.name from members m;
end; $$;

-- Active members who've linked Discord, for pinging new noticeboard posts and meetings.
create or replace function discord_pings()
returns table (id uuid, discord_id text, role text)
language plpgsql security definer set search_path = public as $$
begin
  if not is_server() then raise exception 'Not allowed'; end if;
  return query select m.id, m.discord_id, m.role from members m
   where m.discord_id is not null and m.status = 'active';
end; $$;

revoke execute on function discord_link(text, text, text) from public, anon, authenticated;
revoke execute on function discord_names()                from public, anon, authenticated;
revoke execute on function discord_pings()                from public, anon, authenticated;
grant  execute on function discord_link(text, text, text) to service_role;
grant  execute on function discord_names()                to service_role;
grant  execute on function discord_pings()                to service_role;
grant  select, insert, update, delete on discord_posts    to service_role;
