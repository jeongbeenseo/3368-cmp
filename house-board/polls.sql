-- ===========================================================================
-- House Board update: votes on suggestions
-- Paste into Supabase -> SQL Editor -> Run. Add-only, safe to run twice.
-- ===========================================================================

alter table suggestions add column if not exists options text[];   -- null = no vote

create table if not exists suggestion_votes (
  suggestion_id uuid not null references suggestions(id) on delete cascade,
  member_id     uuid not null references members(id) on delete cascade,
  choice        int  not null check (choice >= 0),
  at            timestamptz not null default now(),
  primary key (suggestion_id, member_id)
);
alter table suggestion_votes enable row level security;
drop policy if exists "read suggestion_votes" on suggestion_votes;
create policy "read suggestion_votes" on suggestion_votes for select to anon using (true);
grant select on suggestion_votes to anon;

-- Who votes: every active housemate and the manager. Guests and the landlord don't.
create or replace function poll_voters()
returns setof uuid language sql stable security definer set search_path = public as $$
  select id from members where status = 'active' and role in ('member','manager');
$$;

-- add_suggestion gains an optional list of vote options
drop function if exists add_suggestion(text, text, text, text, jsonb, uuid);
create or replace function add_suggestion(
  p_code text, p_kind text, p_title text, p_body text, p_files jsonb, p_meeting uuid,
  p_options text[] default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me members; sid uuid; opts text[];
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  if length(trim(coalesce(p_title, ''))) = 0 then raise exception 'Give it a title'; end if;
  if p_kind not in ('rule','issue','idea','notice') then raise exception 'Pick a type'; end if;
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

-- Vote, or change your vote, until everyone has voted. Then it's final.
create or replace function vote_suggestion(p_code text, p_id uuid, p_choice int)
returns text language plpgsql security definer set search_path = public as $$
declare me members; s suggestions;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  select * into s from suggestions where id = p_id for update;
  if s.id is null then raise exception 'That suggestion is gone'; end if;
  if s.options is null then raise exception 'There''s no vote on this one'; end if;
  if p_choice < 0 or p_choice >= array_length(s.options, 1) then raise exception 'Pick one of the options'; end if;
  if me.id not in (select poll_voters()) then raise exception 'You don''t have a vote on this one'; end if;
  if not exists (select 1 from poll_voters() v(id)
                 where not exists (select 1 from suggestion_votes x where x.suggestion_id = p_id and x.member_id = v.id)) then
    raise exception 'Everyone has voted, so the result is final';
  end if;
  insert into suggestion_votes (suggestion_id, member_id, choice) values (p_id, me.id, p_choice)
  on conflict (suggestion_id, member_id) do update set choice = excluded.choice, at = now();
  return 'ok';
end; $$;

grant execute on all functions in schema public to anon;

do $$
begin
  begin alter publication supabase_realtime add table suggestion_votes; exception when duplicate_object or undefined_object then null; end;
end $$;

select 'votes ready' as status;
