# mach-http

Lightweight HTTP protocol, transport, and application contracts for Mach.

The version-neutral service exchange is implemented. It provides bounded methods,
statuses, fields, targets, metadata, informational responses, trailers, response
construction, hierarchical cancellation, and streaming body lifecycles shared by
HTTP/1, HTTP/2, and HTTP/3. The ordered-byte transport boundary is also implemented
with completion-driven plaintext and secured adapters. HTTP/1 wire parsing, framing,
serialization, and bounded client and server connection engines are implemented.
Bounded route compilation and zero-allocation dispatch are implemented. WebSocket
negotiation, framing, and completion-driven connections are implemented for HTTP/1
upgrade and HTTP/2 or HTTP/3 extended CONNECT. The HTTP/2 and HTTP/3 wire layers
remain under development.

## Design

- Core request and response types do not expose HTTP/1 connection details.
- Header and target values are borrowed bounded views.
- Bodies are streaming and bounded by caller-provided buffers.
- Body readers and writers expose stable pending-operation tokens, exact completion,
  drain, rejection, cancellation, deadlines, trailers, and protocol-decided reuse.
- Transports use caller-owned bounded slots and stable generation tokens. Three
  slots is the minimum, reserving concurrent read, write-side, and close ownership.
- Reads, writes, write half-close, and physical close preserve partial completion,
  buffer ownership, hierarchical cancellation, and deadlines.
- Plaintext runtime completions have a built-in adapter. Secured adapters may drive
  handshake reads and writes internally before publishing one logical completion.
- Data operations share one cancellation root. Physical close uses an independent
  control scope, so close and cancellation races settle exactly once.
- Routing storage is caller-owned. Routes compile once into caller-provided route and
  segment arrays. Dispatch performs no allocation.
- Route precedence is independent of registration order. Exact hosts precede suffix
  hosts and host-independent routes. Literal path segments precede parameters and
  terminal catch-alls. Exact methods precede method-independent routes.
- Route parameters preserve bounded raw request views and may be percent-decoded into
  caller storage. Malformed encodings, encoded separators, backslashes, controls, and
  dot segments fail before matching.
- HTTP/1.1, HTTP/2, HTTP/3, and WebSocket state are isolated from the version-neutral application contract.
- HTTP/1 parser-owned message views live until reset. Body views borrow only the
  current input. Serializers retain no body pointer across calls and borrow trailer
  fields until terminal chunk serialization.
- HTTP/1 connection slots own independent parser storage. Pipelined message views
  remain stable until their slot is released, responses remain wire-ordered, and
  reads stop at configured saturation or while a body view is borrowed.
- HTTP/1 request bodies have explicit deliver, bounded drain, reject, and close
  dispositions. Upgrade and CONNECT handoff preserve every unread tunnel byte.
- WebSocket decoding is incremental across every byte boundary. Inbound data views
  borrow the active input until explicit release. Control frames use caller-provided
  bounded scratch storage.
- WebSocket writes copy application payload into the caller-provided connection
  buffer before returning ownership. Transport submissions retain only that stable
  buffer through their exact completion token.
- Frame, message, and fragmentation limits are independent. Mask direction,
  minimally encoded lengths, streaming UTF-8, control interleaving, close codes,
  and abnormal EOF outcomes are enforced before another frame is admitted.
- Header, request, idle, write, and total deadlines are absolute. Slow progress does
  not refresh them. Graceful close finishes admitted work before write half-close.
- TLS belongs below the transport contract and is not a dependency of this package.

## Routing

Route methods use an HTTP token, with `*` or an empty view matching any method. Hosts
are case-insensitive exact authorities, `*.example.com` suffix patterns, `*`, or an
empty view. An explicit route port is required to match that port. A route without a
port matches the same host on any port.

Path patterns begin with `/`. `:name` captures one non-empty segment and a terminal
`*name` captures the remaining path. The standalone `*` pattern handles asterisk and
authority request targets. Compiled routes borrow method, host, pattern, and parameter
name views for the router generation. Dispatch captures borrow the request path for
the request generation. Recompilation advances the router generation and invalidates
prior matches. `decode_capture` writes decoded values into caller storage.

## WebSocket

`http.websocket.negotiation.server` commits HTTP/1 upgrade or HTTP/2 and HTTP/3
extended CONNECT through the common service exchange. The caller owns the accept-key
scratch and any selected subprotocol view. Client response validation checks the
exact accept value and case-sensitive subprotocol selection.

`http.websocket.Decoder` and `Encoder` are allocation-free incremental codecs.
`Connection` binds them to the common completion-driven transport and supports exact
upgrade-buffer adoption, partial reads and writes, cancellation, timeout outcomes,
and physical close. Clients must supply a fresh unpredictable four-byte mask key for
every outbound frame. See [doc/websocket.md](doc/websocket.md) for lifecycle and
ownership details.

## Layout

```text
src/
  core/       request, response, body, and transport contracts
  h1/         strict incremental HTTP/1 framing, parsing, and serialization
  h2/         HTTP/2 frames, HPACK, flow control, and connection state
  h3/         HTTP/3 frames, QPACK, control streams, and connection state
  server/     server configuration and lifecycle state
  client/     client configuration and lifecycle state
  router/     compiled routing, captures, dispatch, and handler invocation
  websocket   negotiation, framing, and completion-driven connection state
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
