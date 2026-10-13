-- ===========================================================================
-- House Board update: Group Meetings, booking history, file uploads
-- ---------------------------------------------------------------------------
-- Paste the whole file into Supabase -> SQL Editor -> Run.
--
-- ADD-ONLY. Nothing here drops a table or deletes a row of existing data.
-- It creates new tables, replaces a few functions, and changes one rule on
-- bookings so they survive a housemate being removed. Safe to run more than
-- once.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 0. Make sure the roles from add-roles.sql are in place (no-op if they are)
-- ---------------------------------------------------------------------------
alter table members add column if not exists role text not null default 'member';
update members set role = 'manager' where is_manager and role = 'member';

create or replace function writer(p_code text)
returns members language sql security definer set search_path = public as $$
  select * from members
  where code = p_code and status = 'active' and role <> 'guest';
$$;

-- ---------------------------------------------------------------------------
-- 1. Bookings: keep the record when someone is removed, lock the past
-- ---------------------------------------------------------------------------
-- Each booking also remembers the person's name, so history still reads
-- "Sam, 9:00-11:00" after Sam moves out. Removing a member used to delete
-- their bookings; now it only unlinks them.
alter table bookings add column if not exists person_name text;
update bookings b set person_name = m.name
  from members m where m.id = b.person_id and b.person_name is null;

alter table bookings alter column person_id drop not null;
alter table bookings drop constraint if exists bookings_person_id_fkey;
alter table bookings add constraint bookings_person_id_fkey
  foreign key (person_id) references members(id) on delete set null;

-- An hour counts as past once it has finished, in Toronto time.
create or replace function hour_over(p_day date, p_hour int)
returns boolean language sql stable as $$
  select (p_day + make_interval(hours => p_hour + 1)) <= (now() at time zone 'America/Toronto');
$$;

create or replace function book(p_code text, p_resource text, p_day date, p_hour int)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  if hour_over(p_day, p_hour) then raise exception 'That hour has already passed'; end if;
  insert into bookings (resource_id, day, hour, person_id, person_name)
  values (p_resource, p_day, p_hour, me.id, me.name);
exception
  when unique_violation then raise exception 'Someone just took that hour';
end; $$;

-- Past bookings are a record: nobody can cancel them, the manager included.
create or replace function unbook(p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me members; b bookings;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  select * into b from bookings where id = p_id;
  if b.id is null then raise exception 'That booking is already gone'; end if;
  if hour_over(b.day, b.hour) then raise exception 'Past bookings can''t be changed'; end if;
  if b.person_id is distinct from me.id and not me.is_manager then
    raise exception 'That booking is not yours';
  end if;
  delete from bookings where id = p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- 2. Group meetings
-- ---------------------------------------------------------------------------
create table if not exists meetings (
  id         uuid primary key default gen_random_uuid(),
  starts_at  timestamptz not null,
  ends_at    timestamptz,
  place      text,
  agenda     text,
  landlord   boolean not null default false,   -- landlord invited to this one
  reminded   boolean not null default false,   -- 1-hour reminder already sent
  created_by uuid references members(id) on delete set null,
  created_at timestamptz not null default now()
);

-- A call for an earlier meeting. When every voter says yes it replaces the
-- next scheduled meeting.
create table if not exists meeting_calls (
  id         uuid primary key default gen_random_uuid(),
  starts_at  timestamptz not null,
  ends_at    timestamptz,
  note       text,
  landlord   boolean not null default false,   -- landlord gets a vote too
  called_by  uuid references members(id) on delete set null,
  caller_name text,
  replaces   uuid references meetings(id) on delete set null,
  status     text not null default 'open'
             check (status in ('open','passed','cancelled')),
  created_at timestamptz not null default now()
);

create table if not exists call_votes (
  call_id   uuid not null references meeting_calls(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  vote      text not null check (vote in ('yes','no')),
  at        timestamptz not null default now(),
  primary key (call_id, member_id)
);

-- Suggestions can't be edited: there is no function that updates one.
create table if not exists suggestions (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null default 'idea' check (kind in ('rule','issue','idea','notice')),
  title       text not null check (length(title) between 1 and 120),
  body        text,
  files       jsonb not null default '[]'::jsonb,   -- [{path, name, type}]
  meeting_id  uuid references meetings(id) on delete set null,
  author_id   uuid references members(id) on delete set null,
  author_name text,
  created_at  timestamptz not null default now()
);

-- What the board tells people: early-meeting calls, new meetings, reminders.
-- The board shows these as alerts; phone notifications can be added on top.
create table if not exists notices (
  id         bigserial primary key,
  kind       text not null,
  title      text not null,
  body       text,
  landlord   boolean not null default false,   -- landlord should see it too
  created_at timestamptz not null default now()
);

alter table meetings      enable row level security;
alter table meeting_calls enable row level security;
alter table call_votes    enable row level security;
alter table suggestions   enable row level security;
alter table notices       enable row level security;

drop policy if exists "read meetings"      on meetings;
drop policy if exists "read meeting_calls" on meeting_calls;
drop policy if exists "read call_votes"    on call_votes;
drop policy if exists "read suggestions"   on suggestions;
drop policy if exists "read notices"       on notices;
create policy "read meetings"      on meetings      for select to anon using (true);
create policy "read meeting_calls" on meeting_calls for select to anon using (true);
create policy "read call_votes"    on call_votes    for select to anon using (true);
create policy "read suggestions"   on suggestions   for select to anon using (true);
create policy "read notices"       on notices       for select to anon using (true);

grant select on meetings, meeting_calls, call_votes, suggestions, notices to anon;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function to_local_label(t timestamptz)
returns text language sql immutable as $$
  select to_char(t at time zone 'America/Toronto', 'Dy, Mon FMDD "at" FMHH12:MI AM');
$$;

-- The next meeting that hasn't started yet.
create or replace function next_meeting()
returns meetings language sql stable security definer set search_path = public as $$
  select * from meetings where starts_at > now() order by starts_at limit 1;
$$;

-- Who votes on a call: every active housemate (and the manager), plus the
-- landlord only when she's included. Guests never vote.
create or replace function call_voters(p_call uuid)
returns setof uuid language sql stable security definer set search_path = public as $$
  select m.id from members m, meeting_calls c
  where c.id = p_call and m.status = 'active'
    and (m.role in ('member','manager') or (m.role = 'landlord' and c.landlord));
$$;

-- ---------------------------------------------------------------------------
-- Manager: set, change or delete a meeting
-- ---------------------------------------------------------------------------
create or replace function set_meeting(
  p_code text, p_id uuid, p_starts timestamptz, p_ends timestamptz,
  p_place text, p_agenda text, p_landlord boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare me members; mid uuid; was meetings;
begin
  me := actor(p_code);
  if not coalesce(me.is_manager, false) then raise exception 'Only the manager can set meetings'; end if;
  if p_starts is null then raise exception 'Pick a day and time'; end if;
  if p_ends is not null and p_ends <= p_starts then raise exception 'The meeting has to end after it starts'; end if;

  if p_id is null then
    insert into meetings (starts_at, ends_at, place, agenda, landlord, created_by)
    values (p_starts, p_ends, nullif(trim(p_place), ''), nullif(trim(p_agenda), ''), coalesce(p_landlord, false), me.id)
    returning id into mid;
    insert into notices (kind, title, body, landlord)
    values ('meeting', 'New group meeting', to_local_label(p_starts)
            || coalesce(' · ' || nullif(trim(p_agenda), ''), ''), coalesce(p_landlord, false));
  else
    select * into was from meetings where id = p_id;
    if was.id is null then raise exception 'That meeting no longer exists'; end if;
    update meetings set starts_at = p_starts, ends_at = p_ends,
           place = nullif(trim(p_place), ''), agenda = nullif(trim(p_agenda), ''),
           landlord = coalesce(p_landlord, false),
           reminded = case when p_starts <> was.starts_at then false else reminded end
     where id = p_id;
    mid := p_id;
    if p_starts <> was.starts_at then
      insert into notices (kind, title, body, landlord)
      values ('meeting', 'Group meeting moved', 'Now ' || to_local_label(p_starts), coalesce(p_landlord, false));
    elsif coalesce(p_landlord, false) and not was.landlord then
      insert into notices (kind, title, body, landlord)
      values ('meeting', 'Landlord invited', 'The landlord will join the meeting on ' || to_local_label(p_starts), true);
    end if;
  end if;
  return mid;
end; $$;

-- Deleting a meeting moves its suggestions to the next one, so nothing is lost.
create or replace function delete_meeting(p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me members; gone meetings; nxt uuid;
begin
  me := actor(p_code);
  if not coalesce(me.is_manager, false) then raise exception 'Only the manager can delete meetings'; end if;
  select * into gone from meetings where id = p_id;
  if gone.id is null then return; end if;
  select id into nxt from meetings
   where id <> p_id and starts_at > now() order by starts_at limit 1;
  update suggestions set meeting_id = nxt where meeting_id = p_id;
  delete from meetings where id = p_id;
  if gone.starts_at > now() then
    insert into notices (kind, title, body, landlord)
    values ('meeting', 'Group meeting cancelled', 'The meeting on ' || to_local_label(gone.starts_at) || ' is off', gone.landlord);
  end if;
end; $$;

-- ---------------------------------------------------------------------------
-- Suggestions: anyone in the house can post; author or manager can delete
-- ---------------------------------------------------------------------------
create or replace function add_suggestion(
  p_code text, p_kind text, p_title text, p_body text, p_files jsonb, p_meeting uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare me members; sid uuid;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  if length(trim(coalesce(p_title, ''))) = 0 then raise exception 'Give it a title'; end if;
  if p_kind not in ('rule','issue','idea','notice') then raise exception 'Pick a type'; end if;
  if p_meeting is not null and not exists (select 1 from meetings where id = p_meeting) then
    raise exception 'That meeting no longer exists';
  end if;
  insert into suggestions (kind, title, body, files, meeting_id, author_id, author_name)
  values (p_kind, trim(p_title), nullif(trim(p_body), ''), coalesce(p_files, '[]'::jsonb),
          coalesce(p_meeting, (next_meeting()).id), me.id, me.name)
  returning id into sid;
  return sid;
end; $$;

create or replace function delete_suggestion(p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  delete from suggestions where id = p_id and (author_id = me.id or me.is_manager);
  if not found then raise exception 'You can only delete your own suggestions'; end if;
end; $$;

-- ---------------------------------------------------------------------------
-- Early meeting calls and votes
-- ---------------------------------------------------------------------------
create or replace function call_meeting(
  p_code text, p_starts timestamptz, p_ends timestamptz, p_note text, p_landlord boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare me members; nxt meetings; cid uuid;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
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

create or replace function vote_call(p_code text, p_call uuid, p_vote text)
returns text language plpgsql security definer set search_path = public as $$
declare me members; c meeting_calls; rep meetings; mid uuid;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  if p_vote not in ('yes','no') then raise exception 'Vote yes or no'; end if;

  select * into c from meeting_calls where id = p_call for update;   -- one final vote at a time
  if c.id is null or c.status <> 'open' or c.starts_at <= now() then
    raise exception 'This call has already closed';
  end if;
  if me.id not in (select call_voters(c.id)) then
    raise exception 'You don''t have a vote on this one';
  end if;

  insert into call_votes (call_id, member_id, vote) values (c.id, me.id, p_vote)
  on conflict (call_id, member_id) do update set vote = excluded.vote, at = now();

  -- everyone said yes?
  if exists (select 1 from call_voters(c.id) v(id)
             where not exists (select 1 from call_votes cv
                               where cv.call_id = c.id and cv.member_id = v.id and cv.vote = 'yes')) then
    return 'open';
  end if;

  select * into rep from meetings where id = c.replaces;
  insert into meetings (starts_at, ends_at, place, agenda, landlord, created_by)
  values (c.starts_at, c.ends_at, rep.place, coalesce(c.note, rep.agenda, 'Early meeting'),
          c.landlord or coalesce(rep.landlord, false), c.called_by)
  returning id into mid;
  if rep.id is not null then
    update suggestions set meeting_id = mid where meeting_id = rep.id;
    delete from meetings where id = rep.id;
  end if;
  update meeting_calls set status = 'passed' where id = c.id;

  insert into notices (kind, title, body, landlord)
  values ('meeting', 'Everyone''s free. Meeting moved',
          'Group meeting is now ' || to_local_label(c.starts_at), c.landlord or coalesce(rep.landlord, false));
  return 'passed';
end; $$;

-- The person who called it, or the manager, can withdraw a call.
create or replace function cancel_call(p_code text, p_call uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me members;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  update meeting_calls set status = 'cancelled'
   where id = p_call and status = 'open' and (called_by = me.id or me.is_manager);
  if not found then raise exception 'Only the person who called it, or the manager, can withdraw it'; end if;
end; $$;

grant execute on all functions in schema public to anon;

-- ---------------------------------------------------------------------------
-- 3. Photos and documents attached to suggestions
-- ---------------------------------------------------------------------------
-- A public bucket, 10 MB per file, images / PDF / Word / text only. People can
-- add files but not change or remove them through the API.
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('meeting-files', 'meeting-files', true, 10485760,
            array['image/jpeg','image/png','image/webp','image/gif','image/heic','image/heif',
                  'application/pdf','application/msword',
                  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                  'text/plain'])
    on conflict (id) do nothing;

    drop policy if exists "add meeting files" on storage.objects;
    create policy "add meeting files" on storage.objects
      for insert to anon with check (bucket_id = 'meeting-files');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Live updates for the new tables
-- ---------------------------------------------------------------------------
do $$
begin
  begin alter publication supabase_realtime add table meetings;      exception when duplicate_object or undefined_object then null; end;
  begin alter publication supabase_realtime add table meeting_calls; exception when duplicate_object or undefined_object then null; end;
  begin alter publication supabase_realtime add table call_votes;    exception when duplicate_object or undefined_object then null; end;
  begin alter publication supabase_realtime add table suggestions;   exception when duplicate_object or undefined_object then null; end;
  begin alter publication supabase_realtime add table notices;       exception when duplicate_object or undefined_object then null; end;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Tonight's meeting, Tue Oct 13 2026, 5-7 PM, landlord attending.
--    Added only if no meeting exists at that time yet.
-- ---------------------------------------------------------------------------
insert into meetings (starts_at, ends_at, agenda, landlord)
select timestamptz '2026-10-13 17:00 America/Toronto', timestamptz '2026-10-13 19:00 America/Toronto',
       'House rules and steps toward healthy living', true
where not exists (select 1 from meetings where starts_at = timestamptz '2026-10-13 17:00 America/Toronto');

-- check it over:
select 'meetings' as tbl, count(*) from meetings
union all select 'bookings kept', count(*) from bookings
union all select 'members', count(*) from members;
