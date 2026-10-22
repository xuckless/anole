// Bun.serve with the same two routes, for comparison.
const port = Number(process.argv[2] || 18510);
Bun.serve({
  port, hostname: '127.0.0.1', reusePort: false,
  routes: { '/native': new Response('Hello, World!') },
  fetch(req) {
    const u = req.url; const i = u.indexOf('/', 8); const p = u.slice(i);
    if (p.startsWith('/users/')) return new Response('user ' + p.slice(7));
    return new Response('Hello, World!');
  },
});
console.error('Bun.serve on ' + port);
