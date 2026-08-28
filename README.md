# mach-http

Lightweight HTTP protocol and application contracts for Mach.

The version-neutral service exchange is implemented. It provides bounded methods,
statuses, fields, targets, metadata, informational responses, trailers, response
construction, hierarchical cancellation, and streaming body lifecycles shared by
HTTP/1, HTTP/2, and HTTP/3. Protocol parsing, serialization, routing, connection
engines, and network I/O remain under development.

## Design

- Core request and response types do not expose HTTP/1 connection details.
- Header and target values are borrowed bounded views.
- Bodies are streaming and bounded by caller-provided buffers.
- Body readers and writers expose stable pending-operation tokens, exact completion,
  drain, rejection, cancellation, deadlines, trailers, and protocol-decided reuse.
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

The remaining protocol and integration work is tracked in this repository.

## Development

Dependencies use pinned Git tags.

```sh
mach dep pull .
mach build .
mach test .
```

Build products are written to Mach's default `out/` directory.
