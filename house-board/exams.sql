-- ===========================================================================
-- House Board update: exam times
-- ---------------------------------------------------------------------------
-- Paste the whole file into Supabase -> SQL Editor -> Run.
-- Run it AFTER basement.sql. ADD-ONLY and safe to run more than once.
--
-- Anyone who lives here (housemates, the manager, the basement) can put their
-- own exams on the board and take them off again. Nobody can add or remove
-- someone else's, except the manager tidying up. One row per exam, so two
-- people adding at the same moment can't overwrite each other.
-- ===========================================================================

create table if not exists exams (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references members(id) on delete cascade,
  member_name text not null,
  starts_at   timestamptz not null,
  ends_at     timestamptz,
  course      text,
  created_at  timestamptz not null default now(),
  check (ends_at is null or ends_at > starts_at),
  check (course is null or length(course) <= 60)
);
create index if not exists exams_starts on exams (starts_at);

alter table exams enable row level security;
drop policy if exists "read exams" on exams;
create policy "read exams" on exams for select to anon using (true);
grant select on exams to anon;

-- ---------------------------------------------------------------------------
-- Add one of your own
-- ---------------------------------------------------------------------------
create or replace function add_exam(p_code text, p_starts timestamptz, p_ends timestamptz, p_course text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me members; eid uuid;
begin
  me := writer(p_code);
  if me.id is null or me.role = 'landlord' then raise exception 'Exams are for the people living here'; end if;
  if p_starts is null then raise exception 'Pick a day and a start time'; end if;
  if p_starts < now() - interval '1 day' then raise exception 'That one''s already behind you'; end if;
  if p_ends is not null and p_ends <= p_starts then raise exception 'It has to end after it starts'; end if;
  if (select count(*) from exams where member_id = me.id and starts_at > now()) >= 30 then
    raise exception 'That''s a lot of exams. Remove a few old ones first';
  end if;

  insert into exams (member_id, member_name, starts_at, ends_at, course)
  values (me.id, me.name, p_starts, p_ends, nullif(left(trim(coalesce(p_course, '')), 60), ''))
  returning id into eid;

  -- keep the table small: exams more than a month old go
  delete from exams where coalesce(ends_at, starts_at) < now() - interval '30 days';
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
  if not found then raise exception 'That exam isn''t yours'; end if;
end; $$;

grant execute on function add_exam(text, timestamptz, timestamptz, text), drop_exam(text, uuid) to anon;

-- Live updates on everyone's screen
do $$
begin
  begin alter publication supabase_realtime add table exams; exception when duplicate_object or undefined_object then null; end;
end $$;

-- check it over:
select member_name, starts_at, ends_at, course from exams order by starts_at;
