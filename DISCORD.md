# House Board ↔ Discord

Two things, both handled by one Supabase Edge Function (`supabase/functions/discord`):

1. **Link Discord**: on House Board, *Housemates → Link Discord*. You sign in with your
   House Board code, Discord asks you to authorize, and you're added to the house server
   with your name role. Your House Board code never goes to Discord.
2. **Noticeboard mirror**: posts on the House Board noticeboard appear in
   #📋・noticeboard as Cindy. Replies, edits and "Mark sorted" update the same message;
   deleting a post removes it.

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
   | `WEBHOOK_SECRET` | a long random string you make up |
   | `SITE_URL` | `https://3368-cmp.pages.dev` |

5. **Database → Webhooks → Create a new hook**
   - Name: `discord-noticeboard` · Table: `docs` · Events: Insert, Update, Delete
   - Type: **Supabase Edge Functions** → function `discord`, method POST, timeout 5000 ms
   - HTTP Headers → add `x-webhook-secret` = the same `WEBHOOK_SECRET`

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
- **Noticeboard posts don't show up**: Edge Functions → `discord` → Logs, and check the webhook's header matches `WEBHOOK_SECRET`.
- Posts from before this was set up appear in Discord the next time they get a reply or change.
