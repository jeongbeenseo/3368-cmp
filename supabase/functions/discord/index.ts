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
//     - exams (exam seasons) -> a good-luck post in Discord (pinging linked housemates)
//       and a push notification to every device that installed the board and allowed alerts.
//
//  3. POST from Discord itself (the app's Interactions Endpoint URL): the
//     /laundryalert and /dryeralert slash commands, which ping whoever was booked last,
//     and #verification: /setupverify posts a "Get my role" button; Cindy asks for a
//     first name and a colour, then creates that role and gives it to them.
//
//  4. POST {action:"vapid"} from the board: the public key devices need to sign up
//     for push notifications. Made on first use and kept in the database.
//
// Secrets (Supabase -> Edge Functions -> Secrets), never in the repo:
//   DISCORD_CLIENT_ID, DISCORD_CLIENT_SECRET, DISCORD_BOT_TOKEN, DISCORD_GUILD_ID, DISCORD_PUBLIC_KEY,
//   DISCORD_NOTICEBOARD_WEBHOOK, DISCORD_MEETINGS_WEBHOOK, DISCORD_LAUNDRY_WEBHOOK, WEBHOOK_SECRET, SITE_URL
// Optional: DISCORD_EXAMS_WEBHOOK (else exams go to #noticeboard),
//           DISCORD_HOUSE_ROLE (a shared role everyone verified also gets; default "Housemate", skipped if missing)
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
        case "exams": await syncExam(payload); break;
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
    if (body.action === "vapid") return json({ key: (await vapidKeys()).public });
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
  const role = (me.discord_role_id && roles.find(r => r.id === me.discord_role_id))
    || wanted.map((w: string) => roles.find(r => r.name.toLowerCase() === w.toLowerCase())).find(Boolean);

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
    warning: role || me.role === "landlord" || me.role === "guest" ? null
      : `Last step: in #verification on Discord, press "Get my role" and Cindy will make your role in the colour you pick.`,
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

  // #verification: buttons, colour menu and the name form
  const cid: string = i.data?.custom_id ?? "";
  if (i.type === 2 && i.data?.name === "setupverify") return setupVerify(i, reply);
  if ((i.type === 3 || i.type === 5) && cid.startsWith("verify:")) return verifyStep(i, cid, reply);

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
// 6. Exam seasons -> a good-luck post in Discord and a push to installed boards
// ===========================================================================
async function syncExam(payload: any) {
  const key = `exam:${(payload.record ?? payload.old_record)?.id}`;
  const hook = env("DISCORD_EXAMS_WEBHOOK") || env("DISCORD_NOTICEBOARD_WEBHOOK");

  if (payload.type === "DELETE") {
    const state = await getState(key);
    if (state && hook && state.message_id !== "sending") await fetch(`${hook}/messages/${state.message_id}`, { method: "DELETE" });
    await db("DELETE", `discord_state?key=eq.${encodeURIComponent(key)}`).catch(() => {});
    return;
  }
  if (payload.type !== "INSERT") return;
  const e = payload.record;
  if (!(await claimState(key, "sending", null))) return;          // already handled

  // An exam season runs from the start of its first day to the end of its last day
  const first = String(e.member_name || "Someone").split(" ")[0];
  const lastDay = new Date(new Date(e.ends_at).getTime() - 1000);
  const days = Math.round((new Date(e.ends_at).getTime() - new Date(e.starts_at).getTime()) / 86400000);
  const md = (d: Date) => new Intl.DateTimeFormat("en-US", { timeZone: "America/Toronto", month: "short", day: "numeric" }).format(d);
  const range = `${md(new Date(e.starts_at))} – ${md(lastDay)}`;
  const ask = "Send good luck vibes 🍀 and please be as quiet as you can during quiet hours!";

  // Phones and laptops first: they don't depend on Discord being set up
  await pushAll(e.member_id, {
    title: `📚 ${first}'s exam season: ${range}`,
    body: `${days} day${days === 1 ? "" : "s"}${e.course ? ` · ${e.course}` : ""}. ${ask}`,
    tag: key, url: SITE || "/",
  }).catch(err => console.error("exam push", err));

  if (!hook) return;
  const r = await fetch(`${hook}?wait=true`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ...ping(await pingIds({ except: e.member_id })),
      embeds: [{
        color: 0x5B4BB7,
        title: `📚 ${first} is in exam season`,
        description: [`**${ts(e.starts_at, "D")} – ${ts(lastDay.toISOString(), "D")}** (${days} day${days === 1 ? "" : "s"})`,
          e.course ? `📖 ${e.course}` : "", "", ask].filter((l, n) => l || n === 2).join("\n"),
        url: SITE || undefined,
        footer: { text: "House Board calendar" },
      }],
    }),
  });
  if (!r.ok) { console.error("exam post", r.status, await r.text()); return; }
  const { id } = await r.json();
  await db("PATCH", `discord_state?key=eq.${encodeURIComponent(key)}`, { message_id: id });
}

// ===========================================================================
// 7. Push notifications (Web Push: RFC 8291 encryption, RFC 8292 VAPID)
//    Written against WebCrypto only, so there's nothing to install.
// ===========================================================================
const te = new TextEncoder();
const b64u = (b: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64u = (s: string) =>
  Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), c => c.charCodeAt(0));
const cat = (...a: Uint8Array[]) => {
  const o = new Uint8Array(a.reduce((n, x) => n + x.length, 0)); let at = 0;
  for (const x of a) { o.set(x, at); at += x.length; }
  return o;
};
const hkdf = async (salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, len: number) => new Uint8Array(
  await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info },
    await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]), len * 8));

let vapidCache: { public: string; private: JsonWebKey } | null = null;
async function vapidKeys() {
  if (vapidCache) return vapidCache;
  const rows = await db("GET", "push_keys?select=public_key,private_jwk&id=eq.1");
  if (rows[0]) return (vapidCache = { public: rows[0].public_key, private: rows[0].private_jwk });
  const k = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const made = { public: b64u(await crypto.subtle.exportKey("raw", k.publicKey)), private: await crypto.subtle.exportKey("jwk", k.privateKey) };
  // two first-ever requests at once: whoever saves first wins, the other reads it back
  await db("POST", "push_keys?on_conflict=id", { id: 1, public_key: made.public, private_jwk: made.private },
    { Prefer: "resolution=ignore-duplicates" });
  vapidCache = null;
  const saved = await db("GET", "push_keys?select=public_key,private_jwk&id=eq.1");
  return (vapidCache = { public: saved[0].public_key, private: saved[0].private_jwk });
}

async function encryptPush(sub: { p256dh: string; auth: string }, payload: string) {
  const uaPub = unb64u(sub.p256dh), auth = unb64u(sub.auth);
  const as = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const asPub = new Uint8Array(await crypto.subtle.exportKey("raw", as.publicKey));
  const ua = await crypto.subtle.importKey("raw", uaPub, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: ua }, as.privateKey, 256));
  const ikm = await hkdf(auth, shared, cat(te.encode("WebPush: info\0"), uaPub, asPub), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, te.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, te.encode("Content-Encoding: nonce\0"), 12);
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const body = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key,
    cat(te.encode(payload), new Uint8Array([2]))));
  return cat(salt, new Uint8Array([0, 0, 16, 0, 65]), asPub, body);   // salt, record size 4096, key id
}

async function vapidAuth(endpoint: string) {
  const keys = await vapidKeys();
  const enc = (o: unknown) => b64u(te.encode(JSON.stringify(o)));
  const unsigned = `${enc({ typ: "JWT", alg: "ES256" })}.${enc({
    aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: SITE || "https://3368-cmp.pages.dev" })}`;
  const k = await crypto.subtle.importKey("jwk", keys.private, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, k, te.encode(unsigned));
  return `vapid t=${unsigned}.${b64u(sig)}, k=${keys.public}`;
}

// Every installed board except the person who caused it. Dead devices are forgotten.
async function pushAll(except: string | null, msg: { title: string; body: string; tag?: string; url?: string }) {
  const subs: { endpoint: string; p256dh: string; auth: string }[] = await rpc("push_targets", { p_except: except });
  const payload = JSON.stringify(msg);
  await Promise.all(subs.map(async (s) => {
    try {
      const r = await fetch(s.endpoint, {
        method: "POST",
        headers: { Authorization: await vapidAuth(s.endpoint), "Content-Encoding": "aes128gcm",
                   "Content-Type": "application/octet-stream", TTL: "86400", Urgency: "normal" },
        body: await encryptPush(s, payload),
      });
      if (r.status === 404 || r.status === 410) await db("DELETE", `push_subs?endpoint=eq.${encodeURIComponent(s.endpoint)}`);
      else if (!r.ok) console.error("push", r.status, await r.text());
    } catch (e) { console.error("push", e); }
  }));
}

// ===========================================================================
// 8. #verification: everyone picks a name and a colour, Cindy makes the role
// ===========================================================================
const PALETTE: [string, string, string][] = [
  ["Rose", "#FF6FAE", "🌸"], ["Strawberry", "#E5484D", "🍓"], ["Peach", "#FF9E7A", "🍑"], ["Orange", "#F76B15", "🍊"],
  ["Sunflower", "#FFB224", "🌻"], ["Lemon", "#FFE629", "🍋"], ["Lime", "#99D52A", "🥝"], ["Leaf", "#30A46C", "🌿"],
  ["Mint", "#3DD9B3", "🍃"], ["Teal", "#12A594", "🐢"], ["Sky", "#68DDFD", "💧"], ["Blue", "#0090FF", "🦋"],
  ["Indigo", "#3E63DD", "🌌"], ["Grape", "#8E4EC6", "🍇"], ["Lavender", "#B4A7F5", "💜"], ["Flamingo", "#F76BDE", "🦩"],
  ["Teddy", "#A07553", "🧸"], ["Sand", "#D4B48C", "🏖️"], ["Elephant", "#8B8D98", "🐘"], ["Cloud", "#F5F5F5", "🤍"],
];
const RESERVED = ["everyone", "here", "joey", "landlord", "guest", "housemate", "cindy", "admin", "mod", "moderator", "bot"];
const HOUSE_ROLE = () => env("DISCORD_HOUSE_ROLE") || "Housemate";

function parseHex(v: string): number | null {
  let h = v.trim().replace(/^#/, "");
  if (/^[0-9a-f]{3}$/i.test(h)) h = h.split("").map(c => c + c).join("");
  if (!/^[0-9a-f]{6}$/i.test(h)) return null;
  return parseInt(h, 16) || 0x010101;            // 0 means "no colour" to Discord
}
const cleanName = (v: string) => v.trim().replace(/\s+/g, " ");
function nameProblem(n: string) {
  if (!n) return "Type your first name.";
  if (n.length > 32) return "That's a bit long for a role. 32 characters max.";
  if (!/^[\p{L}\p{M}][\p{L}\p{M}0-9 '.\-]*$/u.test(n)) return "Just letters please (spaces, hyphens and apostrophes are fine).";
  if (RESERVED.includes(n.toLowerCase())) return `"${n}" is taken by a house role. Try your own name.`;
  return null;
}
const isAdmin = (i: any) => { try { return (BigInt(i.member?.permissions ?? "0") & 0x28n) !== 0n; } catch { return false; } };  // Administrator or Manage Server

// Finish slow work after answering Discord (it only waits 3 seconds)
// deno-lint-ignore no-explicit-any
const later = (p: Promise<unknown>) => { const rt = (globalThis as any).EdgeRuntime; rt?.waitUntil ? rt.waitUntil(p) : p.catch(console.error); };
const editReply = (i: any, body: unknown) =>
  fetch(`${DISCORD}/webhooks/${i.application_id}/${i.token}/messages/@original`, {
    method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

async function setupVerify(i: any, reply: (c: string, x?: Record<string, unknown>) => Response) {
  if (!isAdmin(i)) return reply("Only Joey can do that.", { flags: 64 });
  try {
    await bot("POST", `/channels/${i.channel_id}/messages`, {
      embeds: [{
        color: 0x5865F2,
        title: "👋 Welcome to the house!",
        description: [
          "**1.** Link your House Board account: open the board → *Housemates* → **Link Discord**.",
          "**2.** Press **Get my role** below. Tell Cindy your first name and pick a colour, and she'll make your role.",
          "",
          "Want a different colour later? Press the button again any time.",
        ].join("\n"),
        url: SITE || undefined,
      }],
      components: [{ type: 1, components: [
        { type: 2, style: 1, label: "Get my role", emoji: { name: "🎨" }, custom_id: "verify:start" },
        ...(SITE ? [{ type: 2, style: 5, label: "Open House Board", url: SITE }] : []),
      ] }],
    });
    return reply("Posted. Pin it if you like.", { flags: 64 });
  } catch (e) {
    console.error("setupverify", e);
    return reply("I couldn't post here. Check I can send messages in this channel.", { flags: 64 });
  }
}

async function verifyStep(i: any, cid: string, reply: (c: string, x?: Record<string, unknown>) => Response) {
  const user = i.member?.user?.id;
  if (!user) return reply("Use this in the house server.", { flags: 64 });
  const [, step, ...rest] = cid.split(":");
  const carried = rest.join(":");                 // the name, carried through the colour menu
  const field = (id: string) => (i.data?.components ?? []).flatMap((r: any) => r.components ?? [])
    .find((c: any) => c.custom_id === id)?.value ?? "";

  // 1. The button: are they linked? then ask their name
  if (step === "start") {
    let me: any;
    try { me = (await rpc("discord_member", { p_discord_id: user }))[0]; }
    catch (e) { console.error("verify lookup", e); return reply("I can't reach House Board right now. Try again in a minute.", { flags: 64 }); }
    if (!me) return reply(`I don't know you yet! Link your House Board account first: open the board → *Housemates* → **Link Discord**${SITE ? ` (${SITE})` : ""}. Then come back and press the button again.`, { flags: 64 });
    if (me.role === "landlord" || me.role === "guest") return reply("You're all set already. Roles here are for the people living in the house.", { flags: 64 });
    const guess = me.discord_role || String(me.name).split(" ")[0];
    return Response.json({ type: 9, data: {
      custom_id: "verify:name", title: "Hi! I'm Cindy 👋",
      components: [
        { type: 1, components: [{ type: 4, custom_id: "name", label: "What's your first name?", style: 1,
          min_length: 1, max_length: 32, required: true, value: guess.slice(0, 32) }] },
        { type: 1, components: [{ type: 4, custom_id: "hex", label: "Colour hex code (optional)", style: 1,
          min_length: 0, max_length: 7, required: false, placeholder: "#FF6FAE, or leave blank to see the palette" }] },
      ] } });
  }

  // 2. Name (and maybe a hex) typed in
  if (step === "name") {
    const name = cleanName(field("name")), hex = field("hex").trim();
    const bad = nameProblem(name);
    if (bad) return reply(bad + " Press **Get my role** to try again.", { flags: 64 });
    if (hex) {
      const color = parseHex(hex);
      if (color === null) return reply(`"${hex}" isn't a hex colour. It looks like **#FF6FAE**. Press **Get my role** to try again.`, { flags: 64 });
      later(makeRole(i, name, color).then(m => editReply(i, m)));
      return Response.json({ type: 5, data: { flags: 64 } });       // "Cindy is thinking…"
    }
    return reply("", { flags: 64, ...palette(name) });
  }

  // 3a. Picked from the palette
  if (step === "pick") {
    const color = parseHex(i.data?.values?.[0] ?? "");
    if (color === null || nameProblem(carried)) return reply("Something went wrong. Press **Get my role** again.", { flags: 64 });
    later(makeRole(i, carried, color).then(m => editReply(i, m)));
    return Response.json({ type: 6 });                                 // update the palette message when done
  }

  // 3b. Wants to type a hex instead
  if (step === "hex") {
    return Response.json({ type: 9, data: {
      custom_id: `verify:hexed:${carried}`, title: "Your colour",
      components: [{ type: 1, components: [{ type: 4, custom_id: "hex", label: "Hex code", style: 1,
        min_length: 3, max_length: 7, required: true, placeholder: "#FF6FAE" }] }] } });
  }
  if (step === "hexed") {
    const color = parseHex(field("hex"));
    if (color === null) return Response.json({ type: 7, data: { content: `"${field("hex")}" isn't a hex colour. It looks like **#FF6FAE**. Pick one below or try again.`, ...palette(carried) } });
    later(makeRole(i, carried, color).then(m => editReply(i, m)));
    return Response.json({ type: 6 });
  }

  return reply("That button is out of date. Press **Get my role** again.", { flags: 64 });
}

function palette(name: string) {
  return {
    content: `Nice to meet you, **${name}**! Pick a colour for your role:`,
    embeds: SITE ? [{ color: 0x5865F2, image: { url: `${SITE}/palette.png` } }] : [],
    allowed_mentions: { parse: [] },
    components: [
      { type: 1, components: [{ type: 3, custom_id: `verify:pick:${name}`, placeholder: "Choose a colour",
        options: PALETTE.map(([label, hex, emoji]) => ({ label, value: hex, description: hex, emoji: { name: emoji } })) }] },
      { type: 1, components: [{ type: 2, style: 2, label: "Type a hex code instead", emoji: { name: "🎨" }, custom_id: `verify:hex:${name}` }] },
    ],
  };
}

// Create (or recolour) their role, give it to them, remember it.
async function makeRole(i: any, name: string, color: number) {
  const fail = (content: string) => ({ content, embeds: [], components: [], allowed_mentions: { parse: [] } });
  const user = i.member.user.id, guild = i.guild_id || env("DISCORD_GUILD_ID");
  const hex = "#" + color.toString(16).padStart(6, "0").toUpperCase();
  try {
    const me = (await rpc("discord_member", { p_discord_id: user }))[0];
    if (!me) return fail("Link your House Board account first, then press **Get my role** again.");

    const roles: { id: string; name: string; managed: boolean }[] = await bot("GET", `/guilds/${guild}/roles`);
    let mine = roles.find(r => r.id === me.discord_role_id);
    const clash = roles.find(r => r.name.toLowerCase() === name.toLowerCase() && r.id !== mine?.id);
    if (clash) {
      // a role with this name that they already have (e.g. made by hand before) becomes theirs
      const theirs = !clash.managed && clash.id !== guild && (i.member.roles ?? []).includes(clash.id)
        && !(await rpc("discord_role_taken", { p_role_id: clash.id, p_discord_id: user }));
      if (!theirs) return fail(`There's already a role called **${clash.name}**. Try adding an initial (like **${name} ${String(me.name).split(" ").at(-1)?.[0] ?? "B"}**) and press **Get my role** again.`);
      mine = clash;
    }

    const role = mine
      ? await bot("PATCH", `/guilds/${guild}/roles/${mine.id}`, { name, color })
      : await bot("POST", `/guilds/${guild}/roles`, { name, color, permissions: "0", mentionable: true, hoist: false });
    await rpc("discord_set_role", { p_discord_id: user, p_role_name: name, p_role_id: role.id });
    await bot("PUT", `/guilds/${guild}/members/${user}/roles/${role.id}`);
    const house = roles.find(r => r.name.toLowerCase() === HOUSE_ROLE().toLowerCase() && !r.managed);
    if (house && !(i.member.roles ?? []).includes(house.id)) {
      await bot("PUT", `/guilds/${guild}/members/${user}/roles/${house.id}`).catch(e => console.error("house role", e));
    }

    return { content: "", components: [], allowed_mentions: { parse: [] }, embeds: [{
      color, title: mine ? `🎨 Updated! You're now ${name} in ${hex}` : `🎉 You're in, ${name}!`,
      description: `${mine ? "Your role has the new colour." : `I made your role <@&${role.id}> in **${hex}** and gave it to you.`}\nWant a different colour later? Press **Get my role** again.`,
    }] };
  } catch (e) {
    console.error("make role", e);
    const s = String(e);
    if (s.includes("-> 403")) return fail("I'm not allowed to manage roles. Joey: give Cindy the **Manage Roles** permission and drag her role above everyone's name roles.");
    if (s.includes("belongs to someone else")) return fail("That role belongs to another housemate. Pick a different name.");
    return fail("Something went wrong making your role. Try again in a minute, or tell Joey.");
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
