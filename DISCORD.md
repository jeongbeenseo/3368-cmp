# House Board ↔ Discord

Everything here is handled by one Supabase Edge Function (`supabase/functions/discord`):

1. **Link Discord**: on House Board, *Housemates → Link Discord*. You sign in with your
   House Board code, Discord asks you to authorize, and you're added to the house server
   with your name role. Your House Board code never goes to Discord.
2. **Noticeboard mirror**: posts on the House Board noticeboard appear in
   #📋・noticeboard as Cindy. A new post pings every linked housemate except whoever wrote
   it. Replies, edits and "Mark sorted" update the same message quietly; deleting a post
   removes it.
3. **#📅・meetings**: a pinned *Next meeting* card with every undecided suggestion as
   "Things to discuss", kept up to date. A newly scheduled meeting pings every linked
   housemate (and the landlord if they're joining). When someone calls an early meeting, Cindy posts
   it and pings everyone with a vote (their linked Discord accounts, or @everyone if the
   landlord is included), then updates it as people vote.
4. **#🧺・laundry-kitchen**: 3 minutes before your booking ends (the same reminder the
   board gives), Cindy pings you, and only you. Back-to-back hours count as one booking.
5. **`/laundryalert` and `/dryeralert`**: anyone can type these in Discord to have Cindy
   ping whoever was booked on the laundry last (the latest booking that has started,
   never the person who typed it) to come get their washer or dryer load.
6. **#verification: Cindy makes your role.** After linking, press **Get my role** on
   Cindy's message in #verification. She asks your first name (filled in for you) and,
   optionally, a hex colour. Leave the colour blank and she shows a palette of 20 to pick
   from, or lets you type a hex. Then she creates a role with that name and colour and
   gives it to you (plus `Housemate`, if that role exists). Press it again any time to
   change your colour or name. Only linked housemates can use it.
7. **Exam seasons**: when someone declares their exam season on the board's Calendar
   (e.g. Nov 1 – Nov 20), Cindy posts a card asking for good luck vibes and quiet during
   quiet hours (12 midnight to 6 AM) (in #exams if you give it a webhook, otherwise #noticeboard) and pings
   every linked housemate except them. Removing it removes the post. Every device that
   installed the board and turned on alerts also gets a push notification.

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
   | `DISCORD_PUBLIC_KEY` | Developer Portal → General Information → Public Key |
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
   check (pg_cron) that only calls the function when a booking is about to end, and the
   lookup behind `/laundryalert` and `/dryeralert`.
7. **Developer Portal → General Information → Interactions Endpoint URL:**
   `https://gzlvqdcrewfcaegoxcno.supabase.co/functions/v1/discord` → Save. Discord checks
   it right away, so deploy the function with `DISCORD_PUBLIC_KEY` set first.

The two slash commands are registered on the server once, with Cindy's token:
`POST /applications/1560068767289974934/guilds/<server ID>/commands` with
`{"name":"laundryalert","description":"…","type":1}` (and the same for `dryeralert`).
Posting one again with the same name just updates it.

8. **Exams and roles** (newer; do these even if everything above is already set up):
   1. **SQL Editor:** run `house-board/discord-roles.sql`, then `house-board/exams.sql`.
   2. **Edge Functions → `discord`:** paste the new `supabase/functions/discord/index.ts` → Deploy.
   3. Optional secret `DISCORD_EXAMS_WEBHOOK`: a webhook for an #exams channel. Without
      it, exam posts go to #noticeboard.
   4. Register `/setupverify` (only people who can manage the server see it), the same way
      as the laundry commands: `POST /applications/1560068767289974934/guilds/<server ID>/commands`
      with `{"name":"setupverify","description":"Post Cindy's Get my role button here","type":1,"default_member_permissions":"32"}`.
   5. In Discord: **Server Settings → Roles → Cindy**: turn on **Manage Roles**, and drag
      Cindy's role **above** everyone's name roles (Discord only lets her edit roles below her own).
   6. Go to #verification and type `/setupverify`. Cindy posts the welcome message with the
      button. Pin it.

   Push notifications need no keys from you: Cindy makes the signing key the first time a
   device signs up and keeps it in the `push_keys` table.

### 3. Discord server

In the discord-setup folder, `npm start`. That adds #✅・verify and locks everything
else until people link.

## Who gets which role

- Landlord accounts → `Landlord`, guest accounts → `Guest`
- Everyone else picks their own in #verification (name + colour). Cindy remembers it in
  `members.discord_role_id`, so relinking gives the same role back.
- Before they've picked one, linking still looks for a role named `members.discord_role`,
  their House Board name, or their first name (`Derek Smith` → `Derek`). Someone who
  already has a hand-made role with the name they type keeps it, just recoloured.
- The manager gets `Joey` (set by `discord.sql`)
- If a role called `Housemate` exists, everyone who picks a role also gets it. Give
  `Housemate` access to the house channels and new people are let in automatically.

To change someone's by hand: `update members set discord_role = 'Milo' where name = '...';`

## If something goes wrong

- **"Discord didn't accept that"**: the redirect in step 1 doesn't exactly match, or the client secret is wrong.
- **"Not allowed" / database errors**: in Supabase → Settings → API Keys, copy the **secret** key and add it as an
  Edge Function secret named `SB_SECRET_KEY`.
- **"I'm not allowed to manage roles"** in #verification: step 8.5 above.
- **No push notifications**: on iPhone the board has to be opened from the Home Screen
  (Share → Add to Home Screen) before "Ping me when someone adds one" appears.
- **Nothing shows up in Discord**: Edge Functions → `discord` → Logs. A `bad secret` error means the value in `discord_config` doesn't match the `WEBHOOK_SECRET` secret.
- Posts from before this was set up appear in Discord the next time they get a reply or change.
