-- ===========================================================================
-- House Board update: basement accounts and "Joint" suggestions
-- ---------------------------------------------------------------------------
-- Paste the whole file into Supabase -> SQL Editor -> Run.
-- Run it AFTER meetings.sql, polls.sql and keep-records.sql.
--
-- ADD-ONLY. Nothing here drops a table or deletes a row of existing data.
-- Safe to run more than once.
--
--   basement — the people living in the basement. On the board they see
--              Calendar, Group Meeting, Groceries, Noticeboard and Housemates.
--              In Group Meeting they can only post "Joint" suggestions, and
--              they can only vote on Joint ones. No cleaning rotation, no
--              bookings, no early-meeting calls. Enforced here, not just in
--              the interface.
--
--   joint    — a suggestion type meaning "this involves everyone in the
--              house". Anyone can post one. Everyone, the basement included,
--              votes on it.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. The new role and the new suggestion type
-- ---------------------------------------------------------------------------
alter table members drop constraint if exists members_role_chk;
alter table members add constraint members_role_chk
  check (role in ('manager','member','landlord','guest','basement'));

-- drop whatever check currently limits the kind, whatever it's called
do $$
declare c text;
begin
  for c in select conname from pg_constraint
           where conrelid = 'suggestions'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ilike '%kind%'
  loop
    execute format('alter table suggestions drop constraint %I', c);
  end loop;
end $$;
alter table suggestions add constraint suggestions_kind_check
  check (kind in ('rule','issue','idea','notice','joint'));

-- A unit for them to pick when they register. Rename it, or add more
-- (e.g. "Basement A", "Basement B") from the Housemates tab: any unit whose
-- name starts with "Basement" makes new registrations basement accounts.
insert into units (name, sort) values ('Basement', 20) on conflict (name) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Who's asking: house_writer() = may touch house-only things
--    (cleaning, bookings, early-meeting calls). writer() stays as it was.
-- ---------------------------------------------------------------------------
create or replace function house_writer(p_code text)
returns members language sql security definer set search_path = public as $$
  select * from members
  where code = p_code and status = 'active' and role not in ('guest','basement');
$$;

-- ---------------------------------------------------------------------------
-- 3. Registration: picking a basement unit makes it a basement account.
--    Still pending until the manager lets them in.
-- ---------------------------------------------------------------------------
create or replace function register(p_name text, p_unit text, p_code text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if length(trim(p_name)) < 2 then raise exception 'Please give your full name'; end if;
  if not exists (select 1 from units where name = p_unit) then raise exception 'Pick a unit from the list'; end if;
  if p_code !~ '^[0-9]{4}$' then raise exception 'Your code must be exactly 4 digits'; end if;
  if exists (select 1 from members where code = p_code) then
    raise exception 'That code is already taken — pick a different one';
  end if;

  insert into members (name, unit, code, status, role)
  values (trim(p_name), p_unit, p_code, 'pending',
          case when p_unit ilike 'basement%' then 'basement' else 'member' end);

  return 'pending';
end; $$;

-- ---------------------------------------------------------------------------
-- 4. The manager can give someone the basement role
-- ---------------------------------------------------------------------------
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
  if p_role is not null and p_role not in ('manager','member','landlord','guest','basement') then
    raise exception 'Unknown role';
  end if;
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
-- 5. Board documents: basement can use groceries, noticeboard and birthdays,
--    but not the cleaning progress
-- ---------------------------------------------------------------------------
create or replace function save_doc(p_code text, p_key text, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  if p_key not in ('progress', 'trips', 'notes', 'birthdays') then
    raise exception 'Only the manager can change that';
  end if;
  if p_key = 'progress' and me.role = 'basement' then
    raise exception 'The cleaning rotation is for the upstairs housemates';
  end if;
  insert into docs (key, data, updated_at) values (p_key, p_data, now())
    on conflict (key) do update set data = excluded.data, updated_at = now();
end; $$;

-- ---------------------------------------------------------------------------
-- 6. Bookings: house only (same rules as meetings.sql otherwise)
-- ---------------------------------------------------------------------------
create or replace function book(p_code text, p_resource text, p_day date, p_hour int)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := house_writer(p_code);
  if me.id is null then raise exception 'Bookings are for the upstairs housemates'; end if;
  if hour_over(p_day, p_hour) then raise exception 'That hour has already passed'; end if;
  insert into bookings (resource_id, day, hour, person_id, person_name)
  values (p_resource, p_day, p_hour, me.id, me.name);
exception
  when unique_violation then raise exception 'Someone just took that hour';
end; $$;

create or replace function unbook(p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me members; b bookings;
begin
  me := house_writer(p_code);
  if me.id is null then raise exception 'Bookings are for the upstairs housemates'; end if;
  select * into b from bookings where id = p_id;
  if b.id is null then raise exception 'That booking is already gone'; end if;
  if hour_over(b.day, b.hour) then raise exception 'Past bookings can''t be changed'; end if;
  if b.person_id is distinct from me.id and not me.is_manager then
    raise exception 'That booking is not yours';
  end if;
  delete from bookings where id = p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- 7. Suggestions: Joint is a type anyone can use; basement can only post Joint
-- ---------------------------------------------------------------------------
create or replace function add_suggestion(
  p_code text, p_kind text, p_title text, p_body text, p_files jsonb, p_meeting uuid,
  p_options text[] default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me members; sid uuid; opts text[];
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  if length(trim(coalesce(p_title, ''))) = 0 then raise exception 'Give it a title'; end if;
  if p_kind not in ('rule','issue','idea','notice','joint') then raise exception 'Pick a type'; end if;
  if me.role = 'basement' and p_kind <> 'joint' then
    raise exception 'Basement suggestions are always Joint';
  end if;
  if p_meeting is not null and not exists (select 1 from meetings where id = p_meeting) then
    raise exception 'That meeting no longer exists';
  end if;
  select array_agg(trim(o)) into opts from unnest(p_options) o where length(trim(o)) > 0;
  if opts is not null and (array_length(opts, 1) < 2 or array_length(opts, 1) > 8) then
    raise exception 'A vote needs between 2 and 8 options';
  end if;
  insert into suggestions (kind, title, body, files, meeting_id, author_id, author_name, options)
  values (p_kind, trim(p_title), nullif(trim(p_body), ''), coalesce(p_files, '[]'::jsonb),
          coalesce(p_meeting, (next_meeting()).id), me.id, me.name, opts)
  returning id into sid;
  return sid;
end; $$;

-- ---------------------------------------------------------------------------
-- 8. Who votes on a suggestion: housemates and the manager, plus the basement
--    when it's Joint. poll_voters() is left as it was.
-- ---------------------------------------------------------------------------
create or replace function suggestion_voters(p_kind text)
returns setof uuid language sql stable security definer set search_path = public as $$
  select id from members
  where status = 'active'
    and (role in ('member','manager') or (role = 'basement' and p_kind = 'joint'));
$$;

create or replace function vote_suggestion(p_code text, p_id uuid, p_choice int)
returns text language plpgsql security definer set search_path = public as $$
declare me members; s suggestions; top int; winners text[];
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  select * into s from suggestions where id = p_id for update;
  if s.id is null then raise exception 'That suggestion is gone'; end if;
  if s.options is null then raise exception 'There''s no vote on this one'; end if;
  if s.decided_at is not null then raise exception 'Everyone has voted, so the result is final'; end if;
  if p_choice < 0 or p_choice >= array_length(s.options, 1) then raise exception 'Pick one of the options'; end if;
  if me.id not in (select suggestion_voters(s.kind)) then
    raise exception '%', case when me.role = 'basement'
      then 'You can vote on Joint suggestions only' else 'You don''t have a vote on this one' end;
  end if;

  insert into suggestion_votes (suggestion_id, member_id, choice, voter_name) values (p_id, me.id, p_choice, me.name)
  on conflict (suggestion_id, member_id) do update set choice = excluded.choice, voter_name = excluded.voter_name, at = now();

  -- everyone who has a vote has voted? freeze it
  if not exists (select 1 from suggestion_voters(s.kind) v(id)
                 where not exists (select 1 from suggestion_votes x where x.suggestion_id = p_id and x.member_id = v.id)) then
    select max(c) into top from (select count(*) c from suggestion_votes where suggestion_id = p_id group by choice) t;
    select array_agg(s.options[choice + 1] order by choice) into winners
      from (select choice from suggestion_votes where suggestion_id = p_id group by choice having count(*) = top) w;
    update suggestions set decided_at = now(),
           result = case when array_length(winners, 1) = 1 then winners[1] else 'Tie: ' || array_to_string(winners, ' / ') end
     where id = p_id;
    return 'decided';
  end if;
  return 'ok';
end; $$;

-- ---------------------------------------------------------------------------
-- 9. Early-meeting calls stay with the upstairs house. (call_voters() already
--    leaves the basement out, so they can't vote on calls either.)
-- ---------------------------------------------------------------------------
create or replace function call_meeting(
  p_code text, p_starts timestamptz, p_ends timestamptz, p_note text, p_landlord boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare me members; nxt meetings; cid uuid;
begin
  me := house_writer(p_code);
  if me.id is null then raise exception 'Only the upstairs housemates can call an early meeting'; end if;
  if p_starts is null or p_starts <= now() then raise exception 'Pick a time in the future'; end if;
  if p_ends is not null and p_ends <= p_starts then raise exception 'The meeting has to end after it starts'; end if;
  if exists (select 1 from meeting_calls where status = 'open' and starts_at > now()) then
    raise exception 'There''s already an early meeting call open. Vote on that one first.';
  end if;
  nxt := next_meeting();
  if nxt.id is not null and p_starts >= nxt.starts_at then
    raise exception 'An early meeting has to be before the next one (%)', to_local_label(nxt.starts_at);
  end if;

  insert into meeting_calls (starts_at, ends_at, note, landlord, called_by, caller_name, replaces)
  values (p_starts, p_ends, nullif(trim(p_note), ''), coalesce(p_landlord, false), me.id, me.name, nxt.id)
  returning id into cid;

  if me.id in (select call_voters(cid)) then
    insert into call_votes (call_id, member_id, vote) values (cid, me.id, 'yes');
  end if;

  insert into notices (kind, title, body, landlord)
  values ('call', me.name || ' called an early meeting',
          to_local_label(p_starts) || '. Open the board and vote if you''re free.', coalesce(p_landlord, false));
  return cid;
end; $$;

-- ---------------------------------------------------------------------------
-- 10. The house Discord is for upstairs: don't ping basement accounts
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_name = 'members' and column_name = 'discord_id') then
    execute $f$
      create or replace function discord_pings()
      returns table (id uuid, discord_id text, role text)
      language plpgsql security definer set search_path = public as $b$
      begin
        if not is_server() then raise exception 'Not allowed'; end if;
        return query select m.id, m.discord_id, m.role from members m
         where m.discord_id is not null and m.status = 'active' and m.role <> 'basement';
      end; $b$;
    $f$;
    revoke execute on function discord_pings() from public, anon, authenticated;
    grant  execute on function discord_pings() to service_role;
  end if;
end $$;

grant execute on function house_writer(text), suggestion_voters(text), register(text, text, text),
  set_member(text, uuid, text, text, text, text, text), save_doc(text, text, jsonb),
  book(text, text, date, int), unbook(text, uuid),
  add_suggestion(text, text, text, text, jsonb, uuid, text[]), vote_suggestion(text, uuid, int),
  call_meeting(text, timestamptz, timestamptz, text, boolean) to anon;

-- check it over:
select name, sort from units order by sort;
select name, unit, role, status from members order by role, name;
