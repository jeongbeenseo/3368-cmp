-- ===========================================================================
-- Discord, part 2: #meetings
--   * a pinned "Next meeting" card with every undecided suggestion as
--     "Things to discuss", kept up to date
--   * early-meeting calls posted with a ping, updated as people vote
--
-- Run once in Supabase -> SQL Editor (after discord.sql). Safe to re-run.
-- No secrets in this file. After running it, run the one-line insert at the
-- bottom with your own WEBHOOK_SECRET.
-- ===========================================================================

create extension if not exists pg_net with schema extensions;

-- Private settings and message ids for the Edge Function. No policies = not
-- readable through the public API.
create table if not exists discord_config (key text primary key, value text not null);
alter table discord_config enable row level security;

create table if not exists discord_state (
  key        text primary key,          -- 'meeting_board' or 'call:<id>'
  message_id text not null,
  ref        text,                      -- which meeting the board card is for
  updated_at timestamptz default now()
);
alter table discord_state enable row level security;
grant select, insert, update, delete on discord_state to service_role;

-- ---------------------------------------------------------------------------
-- One trigger function for everything Discord cares about. It replaces the
-- notify_discord() you pasted by hand earlier, and reads the secret from
-- discord_config instead of having it typed into the function.
-- ---------------------------------------------------------------------------
create or replace function discord_notify() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare secret text;
begin
  if TG_TABLE_NAME = 'docs' then
    if coalesce(new.key, old.key) <> 'notes' then return null; end if;
  end if;
  select value into secret from discord_config where key = 'webhook_secret';
  if secret is null then return null; end if;
  perform net.http_post(
    url     := 'https://gzlvqdcrewfcaegoxcno.supabase.co/functions/v1/discord',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', secret),
    body    := jsonb_build_object('type', TG_OP, 'table', TG_TABLE_NAME,
                                  'record', to_jsonb(new), 'old_record', to_jsonb(old)),
    timeout_milliseconds := 5000);
  return null;
end $$;

drop trigger if exists discord_noticeboard on docs;
drop function if exists notify_discord();

drop trigger if exists discord_docs on docs;
create trigger discord_docs after insert or update or delete on docs
  for each row execute function discord_notify();
drop trigger if exists discord_meetings on meetings;
create trigger discord_meetings after insert or update or delete on meetings
  for each row execute function discord_notify();
drop trigger if exists discord_suggestions on suggestions;
create trigger discord_suggestions after insert or update or delete on suggestions
  for each row execute function discord_notify();
drop trigger if exists discord_suggestion_votes on suggestion_votes;
create trigger discord_suggestion_votes after insert or update or delete on suggestion_votes
  for each row execute function discord_notify();
drop trigger if exists discord_calls on meeting_calls;
create trigger discord_calls after insert or update on meeting_calls
  for each row execute function discord_notify();
drop trigger if exists discord_call_votes on call_votes;
create trigger discord_call_votes after insert or update or delete on call_votes
  for each row execute function discord_notify();

-- ---------------------------------------------------------------------------
-- What the Edge Function reads. Server only (is_server() is from discord.sql).
-- ---------------------------------------------------------------------------
create or replace function discord_meeting_board()
returns jsonb language plpgsql security definer set search_path = public as $$
declare nm meetings; out jsonb;
begin
  if not is_server() then raise exception 'Not allowed'; end if;
  select * into nm from next_meeting();

  select jsonb_build_object(
    'next', case when nm.id is null then null else jsonb_build_object(
      'id', nm.id, 'starts_at', nm.starts_at, 'ends_at', nm.ends_at,
      'place', nm.place, 'agenda', nm.agenda, 'landlord', nm.landlord) end,
    'voters', (select count(*) from poll_voters()),
    'agenda', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', s.kind, 'title', s.title, 'author', s.author_name,
               'vote', s.options is not null,
               'votes', (select count(*) from suggestion_votes v where v.suggestion_id = s.id))
             order by s.created_at)
      from suggestions s
      where s.decided_at is null
        and (s.meeting_id is null or s.meeting_id = nm.id)), '[]'::jsonb),
    'call', (
      select jsonb_build_object('id', c.id, 'starts_at', c.starts_at, 'caller', c.caller_name,
               'yes', (select count(*) from call_votes v where v.call_id = c.id and v.vote = 'yes'),
               'voters', (select count(*) from call_voters(c.id)))
      from meeting_calls c where c.status = 'open' and c.starts_at > now()
      order by c.created_at desc limit 1)
  ) into out;
  return out;
end; $$;

create or replace function discord_call(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c meeting_calls;
begin
  if not is_server() then raise exception 'Not allowed'; end if;
  select * into c from meeting_calls where id = p_id;
  if c.id is null then return null; end if;
  return jsonb_build_object(
    'id', c.id, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'note', c.note,
    'caller', c.caller_name, 'status', c.status, 'landlord', c.landlord,
    'yes', (select count(*) from call_votes v where v.call_id = c.id and v.vote = 'yes'),
    'no',  (select count(*) from call_votes v where v.call_id = c.id and v.vote = 'no'),
    'voters', (select count(*) from call_voters(c.id)),
    'discord_ids', coalesce((select jsonb_agg(m.discord_id) from members m
                             where m.id in (select call_voters(c.id)) and m.discord_id is not null), '[]'::jsonb));
end; $$;

revoke execute on function discord_meeting_board() from public, anon, authenticated;
revoke execute on function discord_call(uuid)      from public, anon, authenticated;
grant  execute on function discord_meeting_board() to service_role;
grant  execute on function discord_call(uuid)      to service_role;

-- ---------------------------------------------------------------------------
-- Now run this line on its own, with your WEBHOOK_SECRET between the quotes:
--
--   insert into discord_config values ('webhook_secret', 'PASTE_YOUR_SECRET_HERE')
--   on conflict (key) do update set value = excluded.value;
-- ---------------------------------------------------------------------------
