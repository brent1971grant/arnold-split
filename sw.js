const CACHE = 'arnold-split-v11';
const SHELL = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icon-192.png',
  './icon-512.png',
  './apple-touch-icon.png',
  'https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // Never cache Supabase API traffic
  if (url.hostname.endsWith('.supabase.co')) return;
  if (e.request.method !== 'GET') return;

  // The app page itself: network-first, so an update is live the moment it is
  // published. Falls back to the cached copy when offline, and also when the network
  // takes more than 3 seconds (a weak signal in the gym) - the download carries on in
  // the background, so the newer copy is used on the next open.
  const isPage = e.request.mode === 'navigate' || e.request.destination === 'document'
    || url.pathname.endsWith('/') || url.pathname.endsWith('.html');
  if (isPage) {
    const net = fetch(e.request).then(res => {
      if (res && res.ok) {
        const copy = res.clone();
        return caches.open(CACHE).then(c => c.put(e.request, copy)).then(() => res);
      }
      return res;
    });
    e.waitUntil(net.catch(() => {}));
    e.respondWith((async () => {
      const cached = (await caches.match(e.request)) || (await caches.match('./index.html'));
      if (!cached) return net;
      const slow = new Promise(resolve => setTimeout(() => resolve(null), 3000));
      const res = await Promise.race([net.catch(() => null), slow]);
      return res && res.ok ? res : cached;
    })());
    return;
  }

  e.respondWith(
    caches.match(e.request).then(hit => {
      const fetched = fetch(e.request).then(res => {
        if (res && res.ok && (url.origin === location.origin || url.hostname === 'cdn.jsdelivr.net')) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy));
        }
        return res;
      }).catch(() => hit);
      return hit || fetched;
    })
  );
});
