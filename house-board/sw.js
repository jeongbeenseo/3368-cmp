// Keeps a copy of the app itself so it opens instantly and still loads on bad
// wifi. It never caches your data — that always comes from the database.
const CACHE = "house-board-v23";
const SHELL = ["./", "./index.html", "./login.html", "./config.js",
               "./manifest.json", "./icon.png", "./icon-192.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);

  // Anything going to the database or the font CDN goes straight to the network.
  if (e.request.method !== "GET" || url.origin !== location.origin) return;

  // Network first, so an updated board reaches everyone on next open.
  e.respondWith(
    fetch(e.request)
      .then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, copy));
        return res;
      })
      .catch(() => caches.match(e.request).then(hit => hit || caches.match("./index.html")))
  );
});

// Push notifications from the house (new exams, for now). They arrive even
// when the board is closed; tapping one opens the board.
self.addEventListener("push", e => {
  let m = {};
  try { m = e.data ? e.data.json() : {}; } catch (err) { m = { title: "House Board", body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(m.title || "House Board", {
    body: m.body || "", tag: m.tag, icon: "icon-192.png", badge: "icon-192.png", data: { url: m.url || "./" }
  }));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "./";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    const open = list.find(c => c.url.startsWith(self.registration.scope));
    return open ? open.focus() : self.clients.openWindow(url);
  }));
});
