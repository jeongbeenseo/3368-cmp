# House Board

A shared household board for a five-unit house share: cleaning rota, hourly
booking of shared appliances, grocery runs, and a noticeboard. Built because
five people and one washing machine is a scheduling problem, and every roommate
app I found handled chores but not the machine.

Runs as an installable web app — no app store, no accounts to create, no server
to maintain.

## What it does

**Cleaning rota** — define any set of areas, each needing any number of people.
Assignments either rotate automatically on a weekly, fortnightly or monthly
cycle, or are set by hand. The rotation is derived from a single start date
rather than stored, so it never needs maintaining and can be read forwards or
backwards indefinitely.

**Bookings** — hourly slots on anything the house shares. One row per booked
hour with a unique index on `(resource, day, hour)`, so two people tapping the
same slot at once results in one booking and a clear error, not a duplicate.

**Grocery runs** — post a trip, others join, everyone adds to that trip's list.

**Noticeboard** — tagged posts with replies and a resolved state.

## Access model

Two roles, enforced in the database rather than the interface.

Housemates register themselves, choosing a 4-digit code, and stay `pending`
until the manager approves them. They can tick chores off, book and cancel
**their own** hours, and post. The manager approves members, issues codes,
and controls all structure — units, areas, bookable resources, assignments.

The `members` table has row-level security enabled with **no policies at all**,
so the codes cannot be read even with the public API key. Every write goes
through a `security definer` function that resolves the caller's code first:

```sql
create or replace function unbook(p_code text, p_id uuid)
returns void language plpgsql security definer as $$
declare me members;
begin
  me := actor(p_code);
  if me.id is null then raise exception 'Please sign in again'; end if;
  delete from bookings where id = p_id and (person_id = me.id or me.is_manager);
  if not found then raise exception 'That booking is not yours'; end if;
end; $$;
```

Hiding buttons is a convenience. This is the rule.

## Stack

Vanilla JavaScript, no framework and no build step. Supabase (Postgres) for
data, with row-level security and `security definer` functions as the
authorization layer, and realtime subscriptions so changes appear on every
screen without a refresh. Service worker and web manifest make it installable
on iOS, Android and desktop.

Deployed as static files to Cloudflare Pages.

## Setup

See [SETUP.md](SETUP.md). Short version: create a Supabase project, run
`schema.sql`, put your project URL and anon key in `config.js`, host the folder
anywhere static.

## Known limitations

Documented rather than hidden, because they're the interesting part.

**4-digit codes are not real authentication.** Ten thousand combinations. The
`sign_in` function logs failures and locks sign-in for five minutes after 20
consecutive bad attempts, which makes guessing impractical — but that lockout is
global, so it can be abused to lock everyone out temporarily. Migrating to
Supabase Auth with email links removes both problems.

**Board content is publicly readable.** `config`, `docs` and `bookings` carry
public read policies because Supabase realtime requires them. Names, codes and
units are not in those tables, but noticeboard posts are. Closing this means
moving reads behind functions and polling instead of subscribing, or moving to
real auth.

**Documents save whole.** The rota, runs and posts are each one JSON document,
so simultaneous edits resolve last-write-wins. Bookings avoid this by being
row-per-slot.
