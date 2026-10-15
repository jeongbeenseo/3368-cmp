-- ===========================================================================
-- Discord, part 3: "3 minutes left" pings in #laundry-kitchen
--
-- Same rule as the board: 3 minutes before your booking ends, and back-to-back
-- hours count as one booking. Only the person who booked gets pinged, and only
-- if they've linked Discord.
--
-- Run once in Supabase -> SQL Editor (after discord-meetings.sql). Safe to re-run.
-- ===========================================================================

create extension if not exists pg_cron;

-- Bookings ending in the next 3 minutes. Server only.
create or replace function discord_bookings_ending()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not is_server() then raise exception 'Not allowed'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', b.id, 'person', m.name, 'discord_id', m.discord_id, 'ends_at', e.ends_at,
             'resource', coalesce((select r ->> 'name' from config c, jsonb_array_elements(c.data -> 'resources') r
                                   where c.id = 1 and r ->> 'id' = b.resource_id limit 1), 'Your booking')))
    from bookings b
    join members m on m.id = b.person_id and m.discord_id is not null
    cross join lateral (select ((b.day + make_interval(hours => b.hour + 1))::timestamp
                                at time zone 'America/Toronto') as ends_at) e
    where e.ends_at > now() and e.ends_at <= now() + interval '3 minutes 5 seconds'
      -- not the last hour if the same person has the next hour too
      and not exists (select 1 from bookings n
                      where n.resource_id = b.resource_id and n.person_id = b.person_id
                        and n.day + make_interval(hours => n.hour) = b.day + make_interval(hours => b.hour + 1))
  ), '[]'::jsonb);
end; $$;

revoke execute on function discord_bookings_ending() from public, anon, authenticated;
grant  execute on function discord_bookings_ending() to service_role;

-- Every minute, nudge the Edge Function to check.
create or replace function discord_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare secret text;
begin
  select value into secret from discord_config where key = 'webhook_secret';
  if secret is null then return; end if;
  -- only bother the function when something is actually about to end
  if not exists (select 1 from bookings b
                 where ((b.day + make_interval(hours => b.hour + 1))::timestamp at time zone 'America/Toronto')
                       between now() and now() + interval '3 minutes 5 seconds') then
    return;
  end if;
  perform net.http_post(
    url     := 'https://gzlvqdcrewfcaegoxcno.supabase.co/functions/v1/discord',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', secret),
    body    := jsonb_build_object('table', 'tick'),
    timeout_milliseconds := 5000);
end $$;
revoke execute on function discord_tick() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'discord-booking-end';
select cron.schedule('discord-booking-end', '* * * * *', $$ select public.discord_tick() $$);
