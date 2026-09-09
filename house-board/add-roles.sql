-- ===========================================================================
-- Roles: manager, member, landlord, guest
-- ---------------------------------------------------------------------------
--   manager  — everything, as before
--   member   — a housemate; the default
--   landlord — same as a member, but never appears in the cleaning rotation
--   guest    — can read the board and nothing else, enforced here and not just
--              in the interface
--
-- Run once in Supabase -> SQL Editor. Safe to re-run.
-- ===========================================================================

alter table members add column if not exists role text not null default 'member';

do $$
begin
  alter table members add constraint members_role_chk
    check (role in ('manager','member','landlord','guest'));
exception when duplicate_object then null;
end $$;

-- carry the old flag over
update members set role = 'manager' where is_manager and role <> 'manager';

-- ---------------------------------------------------------------------------
-- actor() = may read. writer() = may change things. Guests get the first only.
-- ---------------------------------------------------------------------------
create or replace function writer(p_code text)
returns members language sql security definer set search_path = public as $$
  select * from members
  where code = p_code and status = 'active' and role <> 'guest';
$$;

-- ---------------------------------------------------------------------------
-- These three change shape, so they have to be dropped first
-- ---------------------------------------------------------------------------
drop function if exists sign_in(text);
create or replace function sign_in(p_code text)
returns table (id uuid, name text, unit text, is_manager boolean, status text, role text)
language plpgsql security definer set search_path = public as $$
declare found boolean;
begin
  if (select count(*) from sign_in_log where not ok and at > now() - interval '5 minutes') > 20 then
    raise exception 'Too many failed sign-ins just now. Try again in five minutes.';
  end if;

  select exists (select 1 from members m where m.code = p_code) into found;
  insert into sign_in_log (ok) values (found);
  delete from sign_in_log where at < now() - interval '1 day';

  return query
    select m.id, m.name, m.unit, m.is_manager, m.status, m.role
    from members m where m.code = p_code;
end; $$;

drop function if exists roster(text);
create or replace function roster(p_code text)
returns table (id uuid, name text, unit text, is_manager boolean, role text)
language plpgsql security definer set search_path = public as $$
begin
  if (actor(p_code)).id is null then raise exception 'Please sign in again'; end if;
  return query
    select m.id, m.name, m.unit, m.is_manager, m.role
    from members m join units u on u.name = m.unit
    where m.status = 'active'
    order by m.sort, u.sort, m.name;
end; $$;

drop function if exists list_members(text);
create or replace function list_members(p_code text)
returns table (id uuid, name text, unit text, code text, status text,
               is_manager boolean, role text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not is_manager(p_code) then raise exception 'Only the manager can do that'; end if;
  return query
    select m.id, m.name, m.unit, m.code, m.status, m.is_manager, m.role, m.created_at
    from members m join units u on u.name = m.unit
    order by (m.status = 'pending') desc, m.sort, u.sort, m.name;
end; $$;

-- ---------------------------------------------------------------------------
-- set_member gains a role, and keeps is_manager in step with it
-- ---------------------------------------------------------------------------
drop function if exists set_member(text, uuid, text, text, text, text, boolean);
create or replace function set_member(
  p_code text, p_id uuid,
  p_name text default null, p_unit text default null,
  p_status text default null, p_new_code text default null,
  p_role text default null)
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
  if p_role is not null and p_role not in ('manager','member','landlord','guest') then
    raise exception 'Unknown role';
  end if;
  -- the manager can't lock themselves out
  if p_id = me.id and (p_status in ('blocked','pending') or (p_role is not null and p_role <> 'manager')) then
    raise exception 'You cannot remove your own access';
  end if;

  update members set
    name   = coalesce(nullif(trim(p_name), ''), name),
    unit   = coalesce(p_unit, unit),
    status = coalesce(p_status, status),
    code   = coalesce(p_new_code, code),
    role   = coalesce(p_role, role)
  where id = p_id;

  update members set is_manager = (role = 'manager') where id = p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- Writes now go through writer(), so a guest is refused by the database
-- ---------------------------------------------------------------------------
create or replace function save_doc(p_code text, p_key text, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (writer(p_code)).id is null then raise exception 'No guests allowed in the house'; end if;
  if p_key not in ('progress', 'trips', 'notes', 'birthdays') then
    raise exception 'Only the manager can change that';
  end if;
  insert into docs (key, data, updated_at) values (p_key, p_data, now())
    on conflict (key) do update set data = excluded.data, updated_at = now();
end; $$;

create or replace function book(p_code text, p_resource text, p_day date, p_hour int)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  insert into bookings (resource_id, day, hour, person_id) values (p_resource, p_day, p_hour, me.id);
exception
  when unique_violation then raise exception 'Someone just took that hour';
end; $$;

create or replace function unbook(p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  delete from bookings where id = p_id and (person_id = me.id or me.is_manager);
  if not found then raise exception 'That booking is not yours'; end if;
end; $$;

grant execute on all functions in schema public to anon;

-- check it over:
select name, unit, role, status from members order by role, name;
