# House Board — 3368 Cider Mill Place

A shared board for a five-unit house: cleaning rota, hourly booking of shared
appliances, grocery runs, and a noticeboard. Housemates register themselves and
sign in with a 4-digit code; the manager approves them and controls everything
structural.

## Files

| File | What it is |
|---|---|
| `login.html` | Register / log in. The entry point. |
| `index.html` | The board itself. Redirects here to log in if you're not signed in. |
| `config.js` | **The only file you edit.** Your two Supabase values. |
| `schema.sql` | Run once in Supabase. Contains no codes, safe to commit. |
| `sw.js`, `manifest.json`, `icon*.png` | Make it installable as an app. |

---

## 1. Make the database

1. Sign up at **supabase.com** — free, student email is fine, no card.
2. **New project**. Any name, nearest region, set a database password and keep it
   in a password manager. Under Security, tick **Enable Data API** and **Enable
   automatic RLS**, and untick **Automatically expose new tables** — the schema
   grants access to the four tables that need it and leaves `members` invisible
   to the API. Wait a minute while it builds.
3. Open **SQL Editor**, paste the whole of `schema.sql`, Run. That creates the
   tables and the five units (Upper A–D, Master A).
4. Now create your own account. Run this separately, with your own 4-digit code:

```sql
insert into members (name, unit, code, status, is_manager, sort)
values ('Joseph', 'Master A', '0000', 'active', true, 0)   -- your code here
on conflict (code) do update set status = 'active', is_manager = true;
```

   This is kept out of `schema.sql` on purpose, so that file stays safe to put
   in a public repo. To change your code later:

```sql
update members set code = '0000' where is_manager;
```

## 2. Plug in the keys

Supabase → **Settings → API**. Copy the **Project URL** and the **anon public**
key into `config.js`:

```js
const SUPABASE_URL = "";   // Project URL
const SUPABASE_KEY = "";   // anon public key
```

Open `login.html` by double-clicking. You should see the address and two buttons.
Log in with the code you just set.

## 3. Put it online

Every file here is safe to publish — no codes are stored in any of them.

**Drag and drop:** drop the folder onto **app.netlify.com/drop**, or in
Cloudflare go to Workers & Pages → Create application → Pages → upload assets.

**Via GitHub:** push this folder to a repository, then in Cloudflare choose
Connect to Git. Build settings for this project:

| Setting | Value |
|---|---|
| Framework preset | None |
| Build command | *(leave empty)* |
| Build output directory | `/` |

There's no build step — the files are served exactly as they are. Every push to
`main` redeploys automatically.

Either way the address must be https, or the app won't install to home screens.

## 4. Let people in

Send the link to the house. Each person taps **Register**, gives their name,
picks their unit, and chooses a 4-digit code. Nothing happens until you approve
them: open the board, go to **Housemates**, and the tab shows a count of people
waiting. Tap *Let them in*.

To install: **iPhone** — open in Safari, share button, Add to Home Screen.
**Android** — Chrome, three dots, Install app. **Desktop** — Chrome or Edge,
install icon in the address bar.

---

## Who can do what

**Manager (you)**
- Approve, block or remove anyone who registers
- Change any housemate's name, unit or code
- Add and remove units, cleaning areas and bookable things
- Set who's on which cleaning area, or let it rotate
- Cancel anyone's booking, delete any post or grocery run

**Housemates**
- Tick cleaning areas off as done
- Book and cancel **their own** hours
- Plan and join grocery runs, add to shopping lists
- Post to the noticeboard, reply, mark things sorted, delete their own posts

Enforced in the database. `members` has row-level security enabled with no
policies at all, so nobody can read the codes table directly — only the
`security definer` functions can see inside it, and every one of them checks the
caller's code before doing anything. Hidden buttons are a convenience; these
functions are the actual rule.

---

## Known limitations

Worth knowing, and worth writing down if you ever show this to anyone.

**4-digit codes are weak.** Ten thousand combinations, five of them valid.
`sign_in` logs failures and locks sign-in for everyone for five minutes after 20
bad attempts in a row, which makes guessing impractical, but it also means a
determined nuisance can lock the house out for five minutes at a time. Proper
email sign-in (Supabase Auth) is the real fix.

**Board content is readable to anyone with the link.** `config`, `docs` and
`bookings` have public read policies, because Supabase's live-update feature
needs them. Names, codes and units are *not* in those tables — but noticeboard
posts and shopping lists are. Don't put anything private on the noticeboard.
Closing this means moving reads behind functions too and giving up live sync, or
moving to real auth.

**Last write wins.** The rota, runs and posts each save as one document, so two
people editing the same one within a second or two means the later save wins.
Bookings don't have this problem — they're one row per hour with a unique index,
so a clash is rejected rather than duplicated.

---

## Odds and ends

**Backups.** Supabase's Table Editor shows every table as rows and exports CSV.

**Free tier.** Supabase pauses projects after a week with no activity. A board
five people use won't hit that, but after a long summer the first person back may
need to un-pause it from the dashboard.

**Updating.** Edit the files, re-upload the folder. Bump `CACHE` in `sw.js`
(`house-board-v2` → `v3`) when you change `index.html`, so phones fetch the new
version instead of the cached one.
