// node:http with the same routes, for comparison (one process).
const http = require('http');
const port = Number(process.argv[2] || 18520);
http.createServer((req, res) => {
  const body = req.url.startsWith('/users/') ? 'user ' + req.url.slice(7) : 'Hello, World!';
  res.writeHead(200, { 'content-type': 'text/plain', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}).listen(port, '127.0.0.1', () => console.error('node:http on ' + port));
