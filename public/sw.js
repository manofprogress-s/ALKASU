// ALKASU service worker: uygulama kabuğunu ve satış ekranını çevrimdışı açılabilir tutar (D-004).
// Veri yazma işlemleri burada önbelleğe alınmaz; çevrimdışı satışlar IndexedDB kuyruğundadır.
const VERSION = "alkasu-v1";
const STATIC = `${VERSION}-static`;
const PAGES = `${VERSION}-pages`;
const OFFLINE_PAGES = ["/satis", "/"];

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => !k.startsWith(VERSION)).map((k) => caches.delete(k)))).then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // Supabase isteklerine dokunma

  // Derlenmiş statik dosyalar: önce önbellek
  if (url.pathname.startsWith("/_next/static/") || url.pathname.startsWith("/icons/")) {
    event.respondWith(
      caches.match(req).then((hit) => hit || fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(STATIC).then((c) => c.put(req, copy));
        return res;
      })),
    );
    return;
  }

  // Sayfa gezinmeleri: önce ağ; ağ yoksa son görülen sayfa, o da yoksa satış ekranı
  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req)
        .then((res) => {
          if (res.ok && OFFLINE_PAGES.includes(url.pathname)) {
            const copy = res.clone();
            caches.open(PAGES).then((c) => c.put(url.pathname, copy));
          }
          return res;
        })
        .catch(async () => (await caches.match(url.pathname)) || (await caches.match("/satis")) || new Response(
          "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><title>ALKASU</title><body style='font-family:system-ui;padding:24px'><h1>İnternet yok</h1><p>Satış ekranını çevrimdışı kullanabilmek için önce bir kez internete bağlıyken açın.</p>",
          { headers: { "Content-Type": "text/html; charset=utf-8" } },
        )),
    );
  }
});
