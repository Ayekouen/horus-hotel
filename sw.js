// Horus Hotel : installation et ouverture hors connexion de l'interface (les données restent en ligne)
const C = 'horus-v27';
const CDN = /^https:\/\/(cdn\.jsdelivr\.net|unpkg\.com|fonts\.(googleapis|gstatic)\.com)\//;
self.addEventListener('install', e => { self.skipWaiting(); e.waitUntil(caches.open(C).then(c => c.addAll(['./', './manifest.webmanifest', './icon.svg']))); });
self.addEventListener('activate', e => e.waitUntil(caches.keys().then(k => Promise.all(k.filter(x => x !== C).map(x => caches.delete(x)))).then(() => self.clients.claim())));
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const u = new URL(e.request.url);
  // Bibliothèques et polices : servies depuis le cache (mises à jour en arrière-plan)
  if (CDN.test(e.request.url)) {
    e.respondWith(caches.open(C).then(c => c.match(e.request).then(m => { const net = fetch(e.request).then(r => { if (r.ok || r.type === 'opaque') c.put(e.request, r.clone()); return r; }).catch(() => m); return m || net; })));
    return;
  }
  if (u.origin !== location.origin) return;
  const fresh = e.request.mode === 'navigate' || u.pathname.endsWith('/') || u.pathname.endsWith('.html') || u.pathname.endsWith('sw.js');
  e.respondWith(fetch(e.request, fresh ? { cache: 'no-cache' } : undefined).then(r => { const c = r.clone(); caches.open(C).then(x => x.put(fresh && e.request.mode === 'navigate' ? './' : e.request, c)); return r; }).catch(() => caches.match(e.request, { ignoreSearch: true }).then(m => m || caches.match('./'))));
});
self.addEventListener('message', e => { if (e.data === 'skipWaiting') self.skipWaiting(); });
