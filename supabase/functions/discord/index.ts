// House Board <-> Discord, as one Supabase Edge Function.
//
//  1. POST {action:"link", code, member_code}   from link-discord.html
//     Swaps Discord's one-time code for the person's Discord account, checks their
//     House Board code (same lockout as signing in), adds them to the server and
//     gives them their name role.
//
//  2. POST from the database triggers in discord-meetings.sql
//     - docs (noticeboard) -> #noticeboard: new posts appear, edits/replies/"sorted"
//       update the same message, deleted posts disappear.
//     - meetings / suggestions / votes -> the pinned "Next meeting" card in #meetings,
//       with every undecided suggestion as "Things to discuss".
//     - meeting_calls / call_votes -> an early-meeting call in #meetings that pings
//       everyone with a vote, then updates as they vote.
//     - tick (every minute, from discord-laundry.sql) -> "3 minutes left" pings in
//       #laundry-kitchen, to the person who booked only.
//
//  3. POST from Discord itself (the app's Interactions Endpoint URL): the
//     /laundryalert and /dryeralert slash commands, which ping whoever was booked last.
//
// Secrets (Supabase -> Edge Functions -> Secrets), never in the repo:
//   DISCORD_CLIENT_ID, DISCORD_CLIENT_SECRET, DISCORD_BOT_TOKEN, DISCORD_GUILD_ID, DISCORD_PUBLIC_KEY,
//   DISCORD_NOTICEBOARD_WEBHOOK, DISCORD_MEETINGS_WEBHOOK, DISCORD_LAUNDRY_WEBHOOK, WEBHOOK_SECRET, SITE_URL
// Supabase provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY itself.

import nacl from "npm:tweetnacl@1.0.3";

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

  // Slash commands, sent by Discord
  if (req.headers.get("x-signature-ed25519")) return interaction(req);

  // Database Webhook (noticeboard)
  if (req.headers.get("x-webhook-secret")) {
    if (!env("WEBHOOK_SECRET") || req.headers.get("x-webhook-secret") !== env("WEBHOOK_SECRET")) {
      return json({ error: "bad secret" }, 401);
    }
    try {
      const payload = await req.json();
      const rec = payload.record ?? payload.old_record ?? {};
      switch (payload.table) {
        case "docs": await syncNoticeboard(payload); break;
        case "meetings": case "suggestions": case "suggestion_votes":
          await refreshMeetingBoard(); break;
        case "meeting_calls": await syncCall(rec.id); await refreshMeetingBoard(); break;
        case "call_votes": await syncCall(rec.call_id); await refreshMeetingBoard(); break;
        case "tick": await bookingReminders(); break;
      }
      return json({ ok: true });
    } catch (e) {
      console.error("sync failed", e);
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
  const isNew = new Set(added.map(n => n.id));

  for (const n of [...added, ...changed]) {
    const msg = posted.get(n.id);
    // brand-new posts ping every housemate except whoever wrote it; edits and replies stay quiet
    const body = JSON.stringify({ ...noticeMessage(n, names), ...(isNew.has(n.id) && !msg ? ping(await pingIds({ except: n.by })) : {}) });
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
// 3. #meetings: the "Next meeting" card and early-meeting calls
// ===========================================================================
const KIND: Record<string, string> = { rule: "📏", issue: "⚠️", idea: "💡", notice: "📌" };
const ts = (iso: string, style = "F") => `<t:${Math.floor(new Date(iso).getTime() / 1000)}:${style}>`;

async function getState(key: string): Promise<{ message_id: string; ref: string | null } | null> {
  const rows = await db("GET", `discord_state?select=message_id,ref&key=eq.${encodeURIComponent(key)}`);
  return rows[0] ?? null;
}

// Save a new message id for `key`, unless another run got there first (two
// changes a split second apart). Returns false if we lost, so the caller can
// delete its duplicate message.
async function claimState(key: string, messageId: string, ref: string | null, oldMessageId?: string) {
  const row = { key, message_id: messageId, ref, updated_at: new Date().toISOString() };
  const rows = oldMessageId
    ? await db("PATCH", `discord_state?key=eq.${encodeURIComponent(key)}&message_id=eq.${oldMessageId}`, row,
        { Prefer: "return=representation" })
    : await db("POST", "discord_state?on_conflict=key", row,
        { Prefer: "resolution=ignore-duplicates,return=representation" });
  return Array.isArray(rows) && rows.length > 0;
}

async function hookSend(method: string, path: string, body?: unknown) {
  const hook = env("DISCORD_MEETINGS_WEBHOOK");
  return fetch(`${hook}${path}`, {
    method, headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined,
  });
}

async function pin(channelId: string, messageId: string) {
  await bot("PUT", `/channels/${channelId}/pins/${messageId}`).catch(e => console.error("pin", e));
  // tidy away the "Cindy pinned a message" notice
  const recent = await bot("GET", `/channels/${channelId}/messages?limit=5`).catch(() => []);
  for (const m of recent ?? []) if (m.type === 6) await bot("DELETE", `/channels/${channelId}/messages/${m.id}`).catch(() => {});
}

async function refreshMeetingBoard() {
  if (!env("DISCORD_MEETINGS_WEBHOOK")) return;
  const b = await rpc("discord_meeting_board", {});
  const body = { allowed_mentions: { parse: [] }, embeds: [meetingCard(b)] };
  const ref = b.next?.id ?? "none";
  const state = await getState("meeting_board");

  // Same meeting as before: just update the card in place
  if (state && state.ref === ref) {
    const r = await hookSend("PATCH", `/messages/${state.message_id}`, body);
    if (r.ok || r.status !== 404) return;            // 404 = someone deleted it, so post a new one
  }

  // New meeting (or first time): post a fresh card, pin it, remove the old one.
  // A newly scheduled meeting pings everyone (the landlord too if they're joining);
  // reposting a card someone deleted doesn't.
  const fresh = b.next && state?.ref !== ref;
  const r = await hookSend("POST", "?wait=true", fresh ? { ...body, ...ping(await pingIds({ landlord: !!b.next.landlord })) } : body);
  if (!r.ok) { console.error("meeting card", r.status, await r.text()); return; }
  const msg = await r.json();
  if (!(await claimState("meeting_board", msg.id, ref, state?.message_id))) {
    await hookSend("DELETE", `/messages/${msg.id}`);  // another run already posted it
    return;
  }
  await pin(msg.channel_id, msg.id);
  if (state) await hookSend("DELETE", `/messages/${state.message_id}`);
}

function meetingCard(b: any) {
  const lines: string[] = [];
  if (!b.next) {
    lines.push("No meeting scheduled yet.");
  } else {
    const n = b.next;
    lines.push(`**${ts(n.starts_at)}** · ${ts(n.starts_at, "R")}`);
    if (n.place) lines.push(`📍 ${n.place}`);
    if (n.landlord) lines.push("🏠 The landlord is joining this one");
    if (n.agenda) lines.push("", `📝 ${n.agenda}`);
  }
  if (b.call) {
    lines.push("", `⏩ **${b.call.caller ?? "Someone"} called an early meeting** for ${ts(b.call.starts_at)}. ` +
      `${b.call.yes} of ${b.call.voters} said yes so far. Vote on [House Board](${SITE}).`);
  }
  const items = (b.agenda ?? []).map((s: any) =>
    `${KIND[s.kind] ?? "•"} **${s.title}**${s.author ? ` · ${s.author}` : ""}` +
    (s.vote ? ` · 🗳️ ${s.votes}/${b.voters} voted` : ""));
  lines.push("", `**Things to discuss (${items.length})**`, items.length ? items.join("\n") : "_Nothing yet. Add a suggestion on House Board._");

  let text = lines.join("\n");
  if (text.length > 4000) text = text.slice(0, 3990) + "\n…";
  return {
    color: 0x5865F2,
    title: "📅 Next group meeting",
    url: SITE || undefined,
    description: text,
    footer: { text: "Updates automatically from House Board" },
  };
}

async function syncCall(callId: string) {
  if (!callId || !env("DISCORD_MEETINGS_WEBHOOK")) return;
  const c = await rpc("discord_call", { p_id: callId });
  if (!c) return;
  const key = `call:${callId}`;
  const state = await getState(key);
  const embed = callCard(c);

  if (state) {
    await hookSend("PATCH", `/messages/${state.message_id}`, { embeds: [embed], allowed_mentions: { parse: [] } });
    return;
  }
  if (c.status !== "open") return;                  // never posted, and it's already over

  // First time: post it with a ping
  const ids: string[] = c.discord_ids ?? [];
  const everyone = c.landlord || ids.length === 0;
  const content = everyone ? "@everyone" : ids.map(id => `<@${id}>`).join(" ");
  const r = await hookSend("POST", "?wait=true", {
    content, embeds: [embed],
    allowed_mentions: everyone ? { parse: ["everyone"] } : { parse: [], users: ids },
  });
  if (!r.ok) { console.error("call post", r.status, await r.text()); return; }
  const msg = await r.json();
  if (!(await claimState(key, msg.id, null))) await hookSend("DELETE", `/messages/${msg.id}`);
}

function callCard(c: any) {
  const when = `${ts(c.starts_at)} · ${ts(c.starts_at, "R")}`;
  if (c.status === "passed") {
    return { color: 0x2F7D4F, title: "✅ Everyone's free. The meeting moved", description: `Now **${when}**`, url: SITE || undefined };
  }
  if (c.status === "cancelled") {
    return { color: 0x8E9A93, title: "Early meeting call withdrawn", description: `~~${when}~~`, url: SITE || undefined };
  }
  return {
    color: 0xB0601D,
    title: `⏩ ${c.caller ?? "Someone"} called an early meeting`,
    description: [
      `**${when}**`,
      c.note ? `\n${c.note}` : "",
      `\n✅ ${c.yes} of ${c.voters} said yes${c.no ? ` · ❌ ${c.no} can't make it` : ""}`,
      `It replaces the next meeting once everyone says yes. **[Vote on House Board](${SITE})**`,
    ].join("\n"),
    url: SITE || undefined,
  };
}

// ===========================================================================
// 4. "3 minutes left" in #laundry-kitchen
// ===========================================================================
async function bookingReminders() {
  const hook = env("DISCORD_LAUNDRY_WEBHOOK");
  if (!hook) return;
  const ending: any[] = await rpc("discord_bookings_ending", {});
  for (const b of ending) {
    // claim it first, so the next minute's check doesn't ping twice
    if (!(await claimState(`booking:${b.id}`, "sending", null))) continue;
    const left = Math.max(1, Math.round((new Date(b.ends_at).getTime() - Date.now()) / 60000));
    const r = await fetch(`${hook}?wait=true`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        content: `<@${b.discord_id}>`,
        allowed_mentions: { parse: [], users: [b.discord_id] },   // only the person who booked
        embeds: [{
          color: 0x2A5FA8,
          title: `🧺 ${b.resource}: ${left} min left`,
          description: `Your time ends at ${ts(b.ends_at, "t")}. Please take your things out for the next person.`,
        }],
      }),
    });
    if (!r.ok) { console.error("booking ping", r.status, await r.text()); continue; }
    const { id } = await r.json();
    await db("PATCH", `discord_state?key=eq.${encodeURIComponent(`booking:${b.id}`)}`, { message_id: id });
  }
  // forget reminders older than two days
  const cutoff = new Date(Date.now() - 2 * 86400000).toISOString();
  await db("DELETE", `discord_state?key=like.booking:*&updated_at=lt.${cutoff}`).catch(() => {});
}

// ===========================================================================
// 5. /laundryalert and /dryeralert
// ===========================================================================
const ALERTS: Record<string, string> = {
  laundryalert: "I am going to piss in your load if you don't take your laundry out of the laundry machine. :D",
  dryeralert: "Your filthy clothes are still in the dryer. Please take them out as soon as possible. :))))",
};

const hexBytes = (hex: string) => new Uint8Array((hex.match(/../g) ?? []).map(b => parseInt(b, 16)));

async function interaction(req: Request) {
  // Discord signs every request; anything else is someone pretending to be Discord
  const raw = await req.text();
  let ok = false;
  try {
    ok = nacl.sign.detached.verify(
      new TextEncoder().encode((req.headers.get("x-signature-timestamp") ?? "") + raw),
      hexBytes(req.headers.get("x-signature-ed25519") ?? ""),
      hexBytes(env("DISCORD_PUBLIC_KEY")),
    );
  } catch { /* wrong-length key or signature */ }
  if (!ok) return new Response("bad signature", { status: 401 });

  const i = JSON.parse(raw);
  if (i.type === 1) return Response.json({ type: 1 });             // Discord checking the URL works
  // flags 64 = only the person who ran the command sees the reply
  const reply = (content: string, extra: Record<string, unknown> = {}) =>
    Response.json({ type: 4, data: { content, allowed_mentions: { parse: [] }, ...extra } });

  const alert = ALERTS[i.data?.name];
  if (i.type !== 2 || !alert) return reply("I don't know that command.", { flags: 64 });

  try {
    const last = await rpc("discord_last_laundry", { p_except: i.member?.user?.id ?? null });
    if (!last) return reply("Nobody else has booked the laundry yet.", { flags: 64 });
    if (!last.discord_id) return reply(`${last.name} was booked last but hasn't linked Discord, so I can't ping them.`, { flags: 64 });
    return reply(`<@${last.discord_id}> sama. ${alert}`, { allowed_mentions: { parse: [], users: [last.discord_id] } });
  } catch (e) {
    console.error("laundry alert", e);
    return reply("Couldn't check the bookings just now. Try again in a minute.", { flags: 64 });
  }
}

// ===========================================================================
// Helpers
// ===========================================================================
// Linked members to ping: housemates and the manager, never guests, the landlord only if asked.
async function pingIds({ except, landlord = false }: { except?: string; landlord?: boolean } = {}) {
  const rows: { id: string; discord_id: string; role: string }[] = await rpc("discord_pings", {});
  return rows
    .filter(r => r.id !== except && r.role !== "guest" && (landlord || r.role !== "landlord"))
    .map(r => r.discord_id);
}

// Message fields that ping exactly these Discord users and nobody else
const ping = (ids: string[]) => ids.length
  ? { content: ids.map(id => `<@${id}>`).join(" "), allowed_mentions: { parse: [], users: ids.slice(0, 100) } }
  : {};

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
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}
