-- ===========================================================================
-- House Board update: exam seasons
-- ---------------------------------------------------------------------------
-- Paste the whole file into Supabase -> SQL Editor -> Run.
-- Run it AFTER basement.sql and discord-meetings.sql. ADD-ONLY and safe to
-- run more than once.
--
-- Everyone declares their exam season: a stretch of days (e.g. Nov 1 - Nov 20)
-- when the house should be extra careful about noise.
--
-- Anyone who lives here (housemates, the manager, the basement) can put their
-- own on the board and take it off again. Nobody can add or remove someone
-- else's, except the manager tidying up. One row per season, so two people
-- adding at the same moment can't overwrite each other.
-- ===========================================================================

create table if not exists exams (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references members(id) on delete cascade,
  member_name text not null,
  starts_at   timestamptz not null,       -- start of the first day
  ends_at     timestamptz not null,       -- end of the last day
  course      text,
  created_at  timestamptz not null default now(),
  check (ends_at > starts_at),
  check (course is null or length(course) <= 60)
);
create index if not exists exams_starts on exams (starts_at);


alter table exams enable row level security;
drop policy if exists "read exams" on exams;
create policy "read exams" on exams for select to anon using (true);
grant select on exams to anon;

-- ---------------------------------------------------------------------------
-- Add your exam season: p_starts is the start of the first day, p_ends the
-- end of the last day (the board works those out in local time).
-- ---------------------------------------------------------------------------
create or replace function add_exam(p_code text, p_starts timestamptz, p_ends timestamptz, p_course text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me members; eid uuid;
begin
  me := writer(p_code);
  if me.id is null or me.role = 'landlord' then raise exception 'Exams are for the people living here'; end if;
  if p_starts is null or p_ends is null then raise exception 'Pick the first and last day'; end if;
  if p_ends <= p_starts then raise exception 'The last day is before the first day'; end if;
  if p_ends < now() then raise exception 'That exam season is already over'; end if;
  if p_ends - p_starts > interval '62 days' + interval '1 hour' then raise exception 'An exam season can be up to two months'; end if;
  if (select count(*) from exams where member_id = me.id and ends_at > now()) >= 10 then
    raise exception 'That''s a lot of exam seasons. Remove an old one first';
  end if;

  insert into exams (member_id, member_name, starts_at, ends_at, course)
  values (me.id, me.name, p_starts, p_ends, nullif(left(trim(coalesce(p_course, '')), 60), ''))
  returning id into eid;

  -- keep the table small: seasons that ended over a month ago go
  delete from exams where ends_at < now() - interval '30 days';
  return eid;
end; $$;

-- ---------------------------------------------------------------------------
-- Take one off: your own, or anyone's if you're the manager
-- ---------------------------------------------------------------------------
create or replace function drop_exam(p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'Please sign in again'; end if;
  delete from exams where id = p_id and (member_id = me.id or me.is_manager);
  if not found then raise exception 'That exam season isn''t yours'; end if;
end; $$;

grant execute on function add_exam(text, timestamptz, timestamptz, text), drop_exam(text, uuid) to anon;

-- Live updates on everyone's screen
do $$
begin
  begin alter publication supabase_realtime add table exams; exception when duplicate_object or undefined_object then null; end;
end $$;

-- ===========================================================================
-- Notifications when someone declares an exam season
--   * Cindy posts them in Discord (pinging linked housemates)
--   * phones / laptops that installed the board get a push notification
-- Both are sent by the `discord` Edge Function, so redeploy it after this.
-- ===========================================================================

-- Devices that said yes to alerts. Nobody can read this through the API;
-- the board writes to it only through save_push / drop_push below.
create table if not exists push_subs (
  endpoint   text primary key,
  member_id  uuid not null references members(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
alter table push_subs enable row level security;
grant select, insert, update, delete on push_subs to service_role;

-- The key pair that signs push messages. The Edge Function makes it the first
-- time it's needed; the private half never leaves the database.
create table if not exists push_keys (
  id         int primary key default 1 check (id = 1),
  public_key text not null,
  private_jwk jsonb not null
);
alter table push_keys enable row level security;
grant select, insert, update on push_keys to service_role;

create or replace function save_push(p_code text, p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'Please sign in again'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'That device can''t take alerts'; end if;
  insert into push_subs (endpoint, member_id, p256dh, auth) values (p_endpoint, me.id, p_p256dh, p_auth)
  on conflict (endpoint) do update set member_id = excluded.member_id, p256dh = excluded.p256dh, auth = excluded.auth;
end; $$;

create or replace function drop_push(p_code text, p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from push_subs where endpoint = p_endpoint and member_id = (writer(p_code)).id;
end; $$;

grant execute on function save_push(text, text, text, text), drop_push(text, text) to anon;

-- Devices to notify: everyone living here except whoever caused it. Server only.
create or replace function push_targets(p_except uuid)
returns table (endpoint text, p256dh text, auth text)
language plpgsql security definer set search_path = public as $$
begin
  if not is_server() then raise exception 'Not allowed'; end if;
  return query select s.endpoint, s.p256dh, s.auth from push_subs s join members m on m.id = s.member_id
   where m.status = 'active' and m.role not in ('guest', 'landlord') and m.id is distinct from p_except;
end; $$;
revoke execute on function push_targets(uuid) from public, anon, authenticated;
grant  execute on function push_targets(uuid) to service_role;

-- Tell the Edge Function when an exam season is added or removed (discord_notify()
-- comes from discord-meetings.sql; skipped quietly if that isn't set up).
do $$
begin
  if to_regprocedure('discord_notify()') is not null then
    drop trigger if exists discord_exams on exams;
    create trigger discord_exams after insert or delete on exams
      for each row execute function discord_notify();
  end if;
end $$;

-- check it over:
select member_name, starts_at, ends_at, course from exams order by starts_at;
