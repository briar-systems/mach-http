# mach-http

Lightweight HTTP protocol and application contracts for Mach.

This repository currently establishes the public shapes that the protocol engines,
servers, clients, routers, and application frameworks share. It is scaffolding, not
a working HTTP implementation. Parsing, serialization, routing, and network I/O are
intentionally not represented as complete.

## Design

- Core request and response types do not expose HTTP/1 connection details.
- Header and target values are borrowed bounded views.
- Bodies are streaming and bounded by caller-provided buffers.
- Transports use stable operation tokens so readiness and completion backends fit.
- Routing storage is caller-owned. The router does not require a global allocator.
- HTTP/1.1, HTTP/2, HTTP/3, and WebSocket state are isolated from the version-neutral application contract.
- TLS belongs below the transport contract and is not a dependency of this package.

## Layout

```text
src/
  core/       request, response, body, and transport contracts
  h1/         HTTP/1 parser, framing, and serializer state
  h2/         HTTP/2 frames, HPACK, flow control, and connection state
  h3/         HTTP/3 frames, QPACK, control streams, and connection state
  server/     server configuration and lifecycle state
  client/     client configuration and lifecycle state
  router/     handler and route storage contracts
  websocket   upgrade and message framing contracts
```

The missing implementation and validation work is tracked in Hedge, which owns the
production server roadmap and integration requirements.

## Development

Dependencies use pinned Git tags.

```sh
mach dep pull .
mach build .
mach test .
```

Build products are written to Mach's default `out/` directory.
