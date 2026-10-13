-- ===========================================================================
-- House Board update: suggestions and votes are permanent records
-- Paste into Supabase -> SQL Editor -> Run. Add-only, safe to run twice.
-- ===========================================================================

-- 1. A finished vote is frozen with its result, so it never "reopens" when
--    someone new moves in, and never changes when someone moves out.
alter table suggestions add column if not exists decided_at timestamptz;
alter table suggestions add column if not exists result text;

-- 2. Votes survive a housemate being removed (their name is kept with the vote).
alter table suggestion_votes add column if not exists voter_name text;
update suggestion_votes v set voter_name = m.name from members m where m.id = v.member_id and v.voter_name is null;
alter table suggestion_votes drop constraint if exists suggestion_votes_member_id_fkey;

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
  if me.id not in (select poll_voters()) then raise exception 'You don''t have a vote on this one'; end if;

  insert into suggestion_votes (suggestion_id, member_id, choice, voter_name) values (p_id, me.id, p_choice, me.name)
  on conflict (suggestion_id, member_id) do update set choice = excluded.choice, voter_name = excluded.voter_name, at = now();

  -- everyone voted? freeze it
  if not exists (select 1 from poll_voters() v(id)
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

-- 3. Once a suggestion's meeting is over, or its vote is decided, it is part of
--    the house record: only the manager can remove it.
create or replace function delete_suggestion(p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me members; s suggestions; m meetings;
begin
  me := writer(p_code);
  if me.id is null then raise exception 'No guests allowed in the house'; end if;
  select * into s from suggestions where id = p_id;
  if s.id is null then return; end if;
  select * into m from meetings where id = s.meeting_id;
  if not me.is_manager then
    if s.author_id is distinct from me.id then raise exception 'You can only delete your own suggestions'; end if;
    if s.decided_at is not null or (m.id is not null and coalesce(m.ends_at, m.starts_at + interval '2 hours') < now()) then
      raise exception 'This is part of the house record now. Only the manager can remove it.';
    end if;
  end if;
  delete from suggestions where id = p_id;
end; $$;

-- 4. Deleting a meeting that already happened keeps its suggestions attached
--    to nothing rather than moving them forward.
create or replace function delete_meeting(p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me members; gone meetings; nxt uuid;
begin
  me := actor(p_code);
  if not coalesce(me.is_manager, false) then raise exception 'Only the manager can delete meetings'; end if;
  select * into gone from meetings where id = p_id;
  if gone.id is null then return; end if;
  if gone.starts_at <= now() then raise exception 'That meeting already happened, so it stays on the record'; end if;
  select id into nxt from meetings where id <> p_id and starts_at > now() order by starts_at limit 1;
  update suggestions set meeting_id = nxt where meeting_id = p_id;
  delete from meetings where id = p_id;
  insert into notices (kind, title, body, landlord)
  values ('meeting', 'Group meeting cancelled', 'The meeting on ' || to_local_label(gone.starts_at) || ' is off', gone.landlord);
end; $$;

grant execute on all functions in schema public to anon;
select 'records protected' as status;
