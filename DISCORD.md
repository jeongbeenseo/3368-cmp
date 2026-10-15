# House Board ↔ Discord

Four things, all handled by one Supabase Edge Function (`supabase/functions/discord`):

1. **Link Discord**: on House Board, *Housemates → Link Discord*. You sign in with your
   House Board code, Discord asks you to authorize, and you're added to the house server
   with your name role. Your House Board code never goes to Discord.
2. **Noticeboard mirror**: posts on the House Board noticeboard appear in
   #📋・noticeboard as Cindy. Replies, edits and "Mark sorted" update the same message;
   deleting a post removes it.
3. **#📅・meetings**: a pinned *Next meeting* card with every undecided suggestion as
   "Things to discuss", kept up to date. When someone calls an early meeting, Cindy posts
   it and pings everyone with a vote (their linked Discord accounts, or @everyone if the
   landlord is included), then updates it as people vote.
4. **#🧺・laundry-kitchen**: 3 minutes before your booking ends (the same reminder the
   board gives), Cindy pings you, and only you. Back-to-back hours count as one booking.

Nothing secret is in this repo. Secrets live in Supabase → Edge Functions → Secrets.

## Setup

### 1. Discord Developer Portal (your bot's app)

- **OAuth2 → Redirects → Add Redirect:** `https://3368-cmp.pages.dev/link-discord.html` → Save.
- **OAuth2 → Client Secret → Reset Secret** → copy it.
- **Bot → Requires OAuth2 Code Grant** stays **off**.

### 2. Supabase

1. **SQL Editor:** paste `house-board/discord.sql` → Run.
2. **Edge Functions → Deploy a new function → Via Editor.** Name it `discord`, paste
   `supabase/functions/discord/index.ts`, Deploy.
3. Open the function → **Details/Settings** → turn **Verify JWT** (Enforce JWT verification) **off** → Save.
   The function checks callers itself: House Board codes for linking, a shared secret for the webhook.
4. **Edge Functions → Secrets**, add:

   | Name | Value |
   |---|---|
   | `DISCORD_CLIENT_ID` | `1560068767289974934` |
   | `DISCORD_CLIENT_SECRET` | from step 1 |
   | `DISCORD_BOT_TOKEN` | Cindy's token (same as `.env` in discord-setup) |
   | `DISCORD_GUILD_ID` | the server ID (same as `.env`) |
   | `DISCORD_NOTICEBOARD_WEBHOOK` | the `noticeboard=` URL from `webhook-urls.txt` |
   | `DISCORD_MEETINGS_WEBHOOK` | the `meetings=` URL from `webhook-urls.txt` |
   | `DISCORD_LAUNDRY_WEBHOOK` | the `laundry-kitchen=` URL from `webhook-urls.txt` |
   | `WEBHOOK_SECRET` | a long random string you make up |
   | `SITE_URL` | `https://3368-cmp.pages.dev` |

5. **SQL Editor:** paste `house-board/discord-meetings.sql` → Run. Then run the one-line
   `insert into discord_config ...` from the bottom of that file with your `WEBHOOK_SECRET`.
   This sets up the database triggers that tell the function when the noticeboard,
   meetings, suggestions or calls change. (Don't also create a Database Webhook in the
   dashboard, or posts would arrive twice.)
6. **SQL Editor:** paste `house-board/discord-laundry.sql` → Run. This adds a once-a-minute
   check (pg_cron) that only calls the function when a booking is about to end.

### 3. Discord server

In the discord-setup folder, `npm start`. That adds #✅・verify and locks everything
else until people link.

## Who gets which role

- Landlord accounts → `Landlord`, guest accounts → `Guest`
- Everyone else → the role named in `members.discord_role`, or else their House Board
  name, or else their first name (`Derek Smith` → `Derek`)
- The manager gets `Joey` (set by `discord.sql`)

To change someone's: `update members set discord_role = 'Milo' where name = '...';`

## If something goes wrong

- **"Discord didn't accept that"**: the redirect in step 1 doesn't exactly match, or the client secret is wrong.
- **"Not allowed" / database errors**: in Supabase → Settings → API Keys, copy the **secret** key and add it as an
  Edge Function secret named `SB_SECRET_KEY`.
- **Nothing shows up in Discord**: Edge Functions → `discord` → Logs. A `bad secret` error means the value in `discord_config` doesn't match the `WEBHOOK_SECRET` secret.
- Posts from before this was set up appear in Discord the next time they get a reply or change.
