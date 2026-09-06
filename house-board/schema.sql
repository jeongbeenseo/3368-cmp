-- ===========================================================================
-- 3368 Cider Mill Place — House Board database
-- Paste the whole file into Supabase → SQL Editor → Run. Safe to re-run.
--
-- Design note: none of these tables can be written to directly, even with the
-- public key. Every change goes through a function that looks up the caller's
-- code first. The interface hides buttons people shouldn't press; this is what
-- actually stops them.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Units in the house. Publicly readable so the registration page can list them.
-- ---------------------------------------------------------------------------
create table if not exists units (
  name text primary key,
  sort int not null default 0
);
insert into units (name, sort) values
  ('Upper A', 1), ('Upper B', 2), ('Upper C', 3), ('Upper D', 4), ('Master A', 5)
on conflict (name) do nothing;

alter table units enable row level security;
drop policy if exists "read units" on units;
create policy "read units" on units for select to anon using (true);

-- ---------------------------------------------------------------------------
-- Members. No read policy at all, so codes can never be fished out — only the
-- functions below can see inside this table.
-- ---------------------------------------------------------------------------
create table if not exists members (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  unit       text not null references units(name) on update cascade,
  code       text not null unique check (code ~ '^[0-9]{4}$'),
  status     text not null default 'pending' check (status in ('pending','active','blocked')),
  is_manager boolean not null default false,
  sort       int not null default 0,
  created_at timestamptz default now()
);
alter table members enable row level security;

-- Failed sign-ins, so a 4-digit code can't simply be guessed 10,000 times.
create table if not exists sign_in_log (
  id bigserial primary key,
  ok boolean not null,
  at timestamptz not null default now()
);
alter table sign_in_log enable row level security;

-- ---------------------------------------------------------------------------
-- The board itself
-- ---------------------------------------------------------------------------
create table if not exists config (
  id int primary key default 1,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz default now()
);
insert into config (id, data) values (1, '{}'::jsonb) on conflict (id) do nothing;

create table if not exists docs (
  key text primary key,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz default now()
);

create table if not exists bookings (
  id          uuid primary key default gen_random_uuid(),
  resource_id text not null,
  day         date not null,
  hour        int  not null check (hour between 0 and 23),
  person_id   uuid not null references members(id) on delete cascade,
  created_at  timestamptz default now()
);
create unique index if not exists bookings_slot on bookings (resource_id, day, hour);

alter table config   enable row level security;
alter table docs     enable row level security;
alter table bookings enable row level security;

drop policy if exists "read config"   on config;
drop policy if exists "read docs"     on docs;
drop policy if exists "read bookings" on bookings;
create policy "read config"   on config   for select to anon using (true);
create policy "read docs"     on docs     for select to anon using (true);
create policy "read bookings" on bookings for select to anon using (true);

-- ===========================================================================
-- Who's asking? Every write function starts here.
-- ===========================================================================
create or replace function actor(p_code text)
returns members language sql security definer set search_path = public as $$
  select * from members where code = p_code and status = 'active';
$$;

create or replace function is_manager(p_code text)
returns boolean language sql security definer set search_path = public as $$
  select coalesce((select is_manager from members where code = p_code and status = 'active'), false);
$$;

-- ===========================================================================
-- Registration and sign-in
-- ===========================================================================
create or replace function register(p_name text, p_unit text, p_code text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if length(trim(p_name)) < 2 then raise exception 'Please give your full name'; end if;
  if not exists (select 1 from units where name = p_unit) then raise exception 'Pick a unit from the list'; end if;
  if p_code !~ '^[0-9]{4}$' then raise exception 'Your code must be exactly 4 digits'; end if;
  if exists (select 1 from members where code = p_code) then
    raise exception 'That code is already taken — pick a different one';
  end if;

  insert into members (name, unit, code, status)
  values (trim(p_name), p_unit, p_code, 'pending');

  return 'pending';
end; $$;

create or replace function sign_in(p_code text)
returns table (id uuid, name text, unit text, is_manager boolean, status text)
language plpgsql security definer set search_path = public as $$
declare found boolean;
begin
  -- crude but effective brake on guessing: too many recent failures, everyone waits
  if (select count(*) from sign_in_log where not ok and at > now() - interval '5 minutes') > 20 then
    raise exception 'Too many failed sign-ins just now. Try again in five minutes.';
  end if;

  select exists (select 1 from members m where m.code = p_code) into found;
  insert into sign_in_log (ok) values (found);
  delete from sign_in_log where at < now() - interval '1 day';

  return query
    select m.id, m.name, m.unit, m.is_manager, m.status
    from members m where m.code = p_code;
end; $$;

-- Names for the board. Active members only, and never anybody's code.
create or replace function roster(p_code text)
returns table (id uuid, name text, unit text, is_manager boolean)
language plpgsql security definer set search_path = public as $$
begin
  if (actor(p_code)).id is null then raise exception 'Please sign in again'; end if;
  return query
    select m.id, m.name, m.unit, m.is_manager
    from members m join units u on u.name = m.unit
    where m.status = 'active'
    order by m.sort, u.sort, m.name;
end; $$;

-- ===========================================================================
-- Manager-only: who's in the house
-- ===========================================================================
create or replace function list_members(p_code text)
returns table (id uuid, name text, unit text, code text, status text, is_manager boolean, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not is_manager(p_code) then raise exception 'Only the manager can do that'; end if;
  return query
    select m.id, m.name, m.unit, m.code, m.status, m.is_manager, m.created_at
    from members m join units u on u.name = m.unit
    order by (m.status = 'pending') desc, m.sort, u.sort, m.name;
end; $$;

create or replace function set_member(
  p_code text, p_id uuid,
  p_name text default null, p_unit text default null,
  p_status text default null, p_new_code text default null,
  p_is_manager boolean default null)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := actor(p_code);
  if not coalesce(me.is_manager, false) then raise exception 'Only the manager can do that'; end if;

  if p_new_code is not null then
    if p_new_code !~ '^[0-9]{4}$' then raise exception 'Codes must be exactly 4 digits'; end if;
    if exists (select 1 from members where code = p_new_code and id <> p_id) then
      raise exception 'Another housemate already uses that code';
    end if;
  end if;
  if p_unit is not null and not exists (select 1 from units where name = p_unit) then
    raise exception 'That unit does not exist';
  end if;
  -- don't let the manager lock themselves out
  if p_id = me.id and (p_is_manager = false or p_status in ('blocked','pending')) then
    raise exception 'You cannot remove your own access';
  end if;

  update members set
    name       = coalesce(nullif(trim(p_name), ''), name),
    unit       = coalesce(p_unit, unit),
    status     = coalesce(p_status, status),
    code       = coalesce(p_new_code, code),
    is_manager = coalesce(p_is_manager, is_manager)
  where id = p_id;
end; $$;

create or replace function remove_member(p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := actor(p_code);
  if not coalesce(me.is_manager, false) then raise exception 'Only the manager can do that'; end if;
  if p_id = me.id then raise exception 'You cannot remove yourself'; end if;
  delete from members where id = p_id;   -- their bookings go with them
end; $$;

create or replace function set_unit(p_code text, p_name text, p_sort int default 99)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_manager(p_code) then raise exception 'Only the manager can do that'; end if;
  insert into units (name, sort) values (trim(p_name), p_sort)
    on conflict (name) do update set sort = excluded.sort;
end; $$;

create or replace function drop_unit(p_code text, p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_manager(p_code) then raise exception 'Only the manager can do that'; end if;
  if exists (select 1 from members where unit = p_name) then
    raise exception 'Someone still lives in that unit — move them first';
  end if;
  delete from units where name = p_name;
end; $$;

-- ===========================================================================
-- The board: config is manager-only, everything else is any active member
-- ===========================================================================
create or replace function save_config(p_code text, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_manager(p_code) then raise exception 'Only the manager can change that'; end if;
  insert into config (id, data, updated_at) values (1, p_data, now())
    on conflict (id) do update set data = excluded.data, updated_at = now();
end; $$;

create or replace function save_doc(p_code text, p_key text, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (actor(p_code)).id is null then raise exception 'Please sign in again'; end if;
  if p_key not in ('progress', 'trips', 'notes') then
    raise exception 'Only the manager can change that';
  end if;
  insert into docs (key, data, updated_at) values (p_key, p_data, now())
    on conflict (key) do update set data = excluded.data, updated_at = now();
end; $$;

create or replace function book(p_code text, p_resource text, p_day date, p_hour int)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := actor(p_code);
  if me.id is null then raise exception 'Please sign in again'; end if;
  insert into bookings (resource_id, day, hour, person_id) values (p_resource, p_day, p_hour, me.id);
exception
  when unique_violation then raise exception 'Someone just took that hour';
end; $$;

create or replace function unbook(p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := actor(p_code);
  if me.id is null then raise exception 'Please sign in again'; end if;
  delete from bookings where id = p_id and (person_id = me.id or me.is_manager);
  if not found then raise exception 'That booking is not yours'; end if;
end; $$;

-- ===========================================================================
-- Explicit API access
-- ---------------------------------------------------------------------------
-- Written out rather than relying on Supabase's "automatically expose new
-- tables" setting, which should be OFF. Only these four tables are readable
-- from a browser. `members` and `sign_in_log` are named nowhere below, so the
-- API cannot see them at all — codes are unreachable even before RLS applies.
-- ===========================================================================
grant usage on schema public to anon;
grant select on units, config, docs, bookings to anon;
grant execute on all functions in schema public to anon;

-- ===========================================================================
-- Live updates on everyone's screen
-- ===========================================================================
do $$
begin
  begin alter publication supabase_realtime add table config;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table docs;     exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table bookings; exception when duplicate_object then null; end;
end $$;

-- ===========================================================================
-- CREATE YOUR MANAGER ACCOUNT
-- ---------------------------------------------------------------------------
-- Deliberately not included above: this file is safe to put in a public repo,
-- so no real code lives in it. Run this separately in the SQL Editor, with
-- your own 4-digit code in place of 0000, and don't commit the edited version.
--
--   insert into members (name, unit, code, status, is_manager, sort)
--   values ('Joseph', 'Master A', '0000', 'active', true, 0)
--   on conflict (code) do update set status = 'active', is_manager = true;
--
-- To change it later:
--
--   update members set code = '0000' where is_manager;
-- ===========================================================================
