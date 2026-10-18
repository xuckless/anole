// The Node WebTransport bench server: /wt/echo (bench/SPEC.md,
// "WebTransport") on @fails-components/webtransport's Http3Server, whose
// HTTP/3 is Chromium's QUICHE (draft-02 and draft-07 WebTransport, the
// versions Chrome itself speaks) in a native addon.
//
// MODE=h3: WebTransport on UDP HTTPS_PORT (default 8443).
//
// Fastify has no HTTP/3 and no WebTransport, so this is not a Fastify app:
// Http3Server owns the UDP port, answers only WebTransport CONNECTs and
// sends 404 for every other request (there is no /plaintext).
import cluster from 'node:cluster'
import { randomBytes } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { Http3Server } from '@fails-components/webtransport'

const mode = process.env.MODE || 'h1'
if (mode !== 'h3') {
  console.error(`unsupported MODE ${JSON.stringify(mode)}: this server only does h3 (WebTransport)`)
  process.exit(3)
}
const workers = Number(process.env.WORKERS || 1)

if (workers > 1 && cluster.isPrimary) {
  for (let i = 0; i < workers; i++) cluster.fork()
  cluster.on('exit', (w, code) => {
    console.error(`worker ${w.process.pid} exited with ${code}`)
    process.exit(1)
  })
} else {
  serve()
}

function serve () {
  const server = new Http3Server({
    port: Number(process.env.HTTPS_PORT || 8443),
    host: '0.0.0.0',
    // Keys QUICHE's stateless resets and address tokens.
    secret: randomBytes(32).toString('hex'),
    cert: readFileSync(process.env.CERT_FILE || '/certs/cert.pem', 'utf8'),
    privKey: readFileSync(process.env.KEY_FILE || '/certs/key.pem', 'utf8'),
    // Under node:cluster each worker binds its own socket in one SO_REUSEPORT
    // group (the kernel keeps a 4-tuple on one worker), not the primary's
    // shared handle, which would hand a connection's packets to any worker.
    quicheNodeSocketOptions: workers > 1 ? { reusePort: true } : {}
  })
  server.startServer()
  acceptSessions(server)
}

async function acceptSessions (server) {
  const sessions = server.sessionStream('/wt/echo').getReader()
  while (true) {
    const { done, value: session } = await sessions.read()
    if (done) return
    echo(session)
  }
}

async function echo (session) {
  session.closed.catch(() => {})
  try {
    await session.ready
  } catch {
    return
  }
  // Each datagram back unchanged.
  const datagrams = session.datagrams.createWritable?.() ?? session.datagrams.writable
  session.datagrams.readable.pipeTo(datagrams).catch(() => {})
  // Each bidirectional stream back on itself; pipeTo closes the writable
  // (our send side) when the readable (the client's) ends.
  const streams = session.incomingBidirectionalStreams.getReader()
  while (true) {
    let next
    try {
      next = await streams.read()
    } catch {
      return
    }
    if (next.done) return
    next.value.readable.pipeTo(next.value.writable).catch(() => {})
  }
}
