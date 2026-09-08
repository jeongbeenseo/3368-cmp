// Keeps a copy of the app itself so it opens instantly and still loads on bad
// wifi. It never caches your data — that always comes from the database.
const CACHE = "house-board-v5";
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
