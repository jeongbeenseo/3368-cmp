// House Board <-> Discord, as one Supabase Edge Function.
//
//  1. POST {action:"link", code, member_code}   from link-discord.html
//     Swaps Discord's one-time code for the person's Discord account, checks their
//     House Board code (same lockout as signing in), adds them to the server and
//     gives them their name role.
//
//  2. POST from a Supabase Database Webhook on the `docs` table
//     Mirrors the noticeboard into #noticeboard: new posts appear, edits/replies/
//     "sorted" update the same message, deleted posts disappear.
//
// Secrets (Supabase -> Edge Functions -> Secrets), never in the repo:
//   DISCORD_CLIENT_ID, DISCORD_CLIENT_SECRET, DISCORD_BOT_TOKEN, DISCORD_GUILD_ID,
//   DISCORD_NOTICEBOARD_WEBHOOK, WEBHOOK_SECRET, SITE_URL
// Supabase provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY itself.

const env = (k: string) => Deno.env.get(k) ?? "";
const SITE = env("SITE_URL").replace(/\/$/, "");            // https://3368-cmp.pages.dev
const REDIRECT = `${SITE}/link-discord.html`;
const DISCORD = "https://discord.com/api/v10";
const DB_KEY = env("SB_SECRET_KEY") || env("SUPABASE_SERVICE_ROLE_KEY");

const cors = {
  "Access-Control-Allow-Origin": SITE || "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // Database Webhook (noticeboard)
  if (req.headers.get("x-webhook-secret")) {
    if (!env("WEBHOOK_SECRET") || req.headers.get("x-webhook-secret") !== env("WEBHOOK_SECRET")) {
      return json({ error: "bad secret" }, 401);
    }
    try {
      await syncNoticeboard(await req.json());
      return json({ ok: true });
    } catch (e) {
      console.error("noticeboard sync failed", e);
      return json({ error: String(e) }, 500);
    }
  }

  // Account linking
  try {
    const body = await req.json();
    if (body.action !== "link") return json({ error: "Unknown action" }, 400);
    return json(await link(String(body.code || ""), String(body.member_code || "")));
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});

// ===========================================================================
// 1. Linking
// ===========================================================================
async function link(oauthCode: string, memberCode: string) {
  if (!oauthCode || !/^\d{4}$/.test(memberCode)) throw new Error("Something was missing. Start again from the board.");

  // Discord's one-time code -> access token -> who they are
  const tokenRes = await fetch("https://discord.com/api/oauth2/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: oauthCode,
      redirect_uri: REDIRECT,
      client_id: env("DISCORD_CLIENT_ID"),
      client_secret: env("DISCORD_CLIENT_SECRET"),
    }),
  });
  if (!tokenRes.ok) {
    console.error("token exchange", tokenRes.status, await tokenRes.text());
    throw new Error("Discord didn't accept that. Start again from the board.");
  }
  const { access_token } = await tokenRes.json();
  const user = await (await fetch(`${DISCORD}/users/@me`, { headers: { Authorization: `Bearer ${access_token}` } })).json();
  if (!user?.id) throw new Error("Couldn't read your Discord account.");

  // Check their House Board code and save the link
  const rows = await rpc("discord_link", {
    p_code: memberCode, p_discord_id: user.id, p_discord_name: user.global_name || user.username,
  });
  const me = rows[0];

  // Which Discord role they get
  const guild = env("DISCORD_GUILD_ID");
  const roles: { id: string; name: string }[] = await bot("GET", `/guilds/${guild}/roles`);
  const wanted = me.role === "landlord" ? ["Landlord"]
    : me.role === "guest" ? ["Guest"]
    : [me.discord_role, me.name, String(me.name).split(" ")[0]].filter(Boolean);
  const role = wanted.map((w: string) => roles.find(r => r.name.toLowerCase() === w.toLowerCase())).find(Boolean);

  // Add them to the server (with the role), or just give the role if they're already in
  const add = await fetch(`${DISCORD}/guilds/${guild}/members/${user.id}`, {
    method: "PUT",
    headers: { Authorization: `Bot ${env("DISCORD_BOT_TOKEN")}`, "Content-Type": "application/json" },
    body: JSON.stringify({ access_token, ...(role ? { roles: [role.id] } : {}) }),
  });
  if (!add.ok) {
    console.error("add member", add.status, await add.text());
    throw new Error("Couldn't add you to the server. Tell Joey.");
  }
  if (add.status === 204 && role) await bot("PUT", `/guilds/${guild}/members/${user.id}/roles/${role.id}`);

  return {
    ok: true,
    guild_id: guild,
    name: me.name,
    discord_name: user.global_name || user.username,
    role: role?.name ?? null,
    warning: role ? null : `There's no Discord role called "${wanted[0]}" yet, so Joey needs to give you one.`,
  };
}

// ===========================================================================
// 2. Noticeboard -> #noticeboard
// ===========================================================================
type Reply = { id: string; text: string; by: string; ts: number };
type Note = { id: string; text: string; tag: string; by: string; ts: number; resolved: boolean; replies: Reply[] };

const TAGS: Record<string, { label: string; emoji: string; color: number }> = {
  todo:    { label: "Needs doing", emoji: "🧹", color: 0xB0601D },
  concern: { label: "Concern",     emoji: "⚠️", color: 0xA83A5C },
  money:   { label: "Money",       emoji: "💵", color: 0x2F7D4F },
  note:    { label: "Note",        emoji: "📝", color: 0x2A5FA8 },
};

async function syncNoticeboard(payload: any) {
  if (payload?.table !== "docs") return;
  const key = payload.record?.key ?? payload.old_record?.key;
  if (key !== "notes") return;

  const before: Note[] = payload.old_record?.data?.list ?? [];
  const after: Note[] = payload.type === "DELETE" ? [] : (payload.record?.data?.list ?? []);
  const fp = (n: Note) => JSON.stringify([n.text, n.tag, n.resolved, n.replies?.length, n.replies?.at(-1)?.text]);
  const old = new Map(before.map(n => [n.id, fp(n)]));
  const now = new Set(after.map(n => n.id));

  const added   = after.filter(n => !old.has(n.id));
  const changed = after.filter(n => old.has(n.id) && old.get(n.id) !== fp(n));
  const removed = before.filter(n => !now.has(n.id)).map(n => n.id);
  if (!added.length && !changed.length && !removed.length) return;

  const ids = [...added, ...changed].map(n => n.id).concat(removed);
  const posted = new Map<string, string>(
    (await db("GET", `discord_posts?select=note_id,message_id&note_id=in.(${ids.map(i => `"${i}"`).join(",")})`))
      .map((r: any) => [r.note_id, r.message_id]),
  );
  const names = new Map<string, string>((await rpc("discord_names", {})).map((r: any) => [r.id, r.name]));
  const hook = env("DISCORD_NOTICEBOARD_WEBHOOK");

  for (const n of [...added, ...changed]) {
    const msg = posted.get(n.id);
    const body = JSON.stringify(noticeMessage(n, names));
    if (msg) {
      const r = await fetch(`${hook}/messages/${msg}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body });
      if (r.ok || r.status !== 404) continue;          // 404 = someone deleted it in Discord, so post again
    }
    const r = await fetch(`${hook}?wait=true`, { method: "POST", headers: { "Content-Type": "application/json" }, body });
    if (!r.ok) { console.error("post notice", r.status, await r.text()); continue; }
    const { id } = await r.json();
    await db("POST", "discord_posts?on_conflict=note_id", { note_id: n.id, message_id: id, updated_at: new Date().toISOString() },
      { Prefer: "resolution=merge-duplicates" });
  }

  for (const id of removed) {
    const msg = posted.get(id);
    if (msg) await fetch(`${hook}/messages/${msg}`, { method: "DELETE" });
    await db("DELETE", `discord_posts?note_id=eq.${encodeURIComponent(id)}`);
  }
}

function noticeMessage(n: Note, names: Map<string, string>) {
  const t = TAGS[n.tag] ?? TAGS.note;
  const who = (id: string) => names.get(id) ?? "Someone";
  const replies = n.replies ?? [];
  const last = replies.at(-1);
  return {
    allowed_mentions: { parse: [] },          // "@everyone" in a post never pings anyone
    embeds: [{
      color: n.resolved ? 0x8E9A93 : t.color,
      author: { name: `${t.emoji} ${t.label}${n.resolved ? " · sorted ✅" : ""}` },
      description: (n.resolved ? `~~${n.text}~~` : n.text).slice(0, 4000),
      url: SITE || undefined,
      fields: last ? [{
        name: `💬 ${who(last.by)} replied${replies.length > 1 ? ` (${replies.length} replies)` : ""}`,
        value: last.text.slice(0, 1000),
      }] : [],
      footer: { text: `${who(n.by)} · House Board noticeboard` },
      timestamp: new Date(n.ts || Date.now()).toISOString(),
    }],
  };
}

// ===========================================================================
// Helpers
// ===========================================================================
async function bot(method: string, path: string, body?: unknown) {
  const res = await fetch(DISCORD + path, {
    method,
    headers: { Authorization: `Bot ${env("DISCORD_BOT_TOKEN")}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`Discord ${method} ${path} -> ${res.status} ${await res.text()}`);
  return res.status === 204 ? null : res.json();
}

function dbHeaders(extra: Record<string, string> = {}) {
  const h: Record<string, string> = { apikey: DB_KEY, "Content-Type": "application/json", ...extra };
  if (DB_KEY.startsWith("eyJ")) h.Authorization = `Bearer ${DB_KEY}`;  // legacy JWT-style key
  return h;
}

async function rpc(fn: string, args: Record<string, unknown>) {
  const res = await fetch(`${env("SUPABASE_URL")}/rest/v1/rpc/${fn}`, {
    method: "POST", headers: dbHeaders(), body: JSON.stringify(args),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(data?.message || `Database error (${res.status})`);
  return data;
}

async function db(method: string, path: string, body?: unknown, extra: Record<string, string> = {}) {
  const res = await fetch(`${env("SUPABASE_URL")}/rest/v1/${path}`, {
    method, headers: dbHeaders(extra), body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`Database ${method} ${path} -> ${res.status} ${await res.text()}`);
  return method === "GET" ? res.json() : null;
}
