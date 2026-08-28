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
upgrade and HTTP/2 or HTTP/3 extended CONNECT. The HTTP/2 frame, HPACK, connection,
and stream engines are complete. HTTP/3 frame, SETTINGS, critical-stream, QPACK,
connection, and request-stream engines are complete.

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
- HTTP/2 frame parsing is incremental across the nine-byte header and payload.
  Continuation sequences, frame-specific lengths, settings, padding, dependencies,
  and flow-control increments fail before connection state consumes the frame.
- HPACK input may arrive in arbitrary chunks and is decoded transactionally.
  Dynamic table changes commit only after the complete field block validates.
- HPACK field count, decompressed list size, encoded block size, individual string,
  table memory, and table-entry count have independent caller-selected bounds.
- HTTP/2 connections validate the client preface and first SETTINGS boundary before
  admitting streams. Settings, ping, reset, GOAWAY, push, and window updates remain
  ordered with header-block continuations under partial transport completion.
- HTTP/2 stream state is generation-bound and allocation-free. One physical stream
  slot beyond `max_streams` is reserved to decode refused field blocks, preserving
  the shared HPACK context under saturation.
- Connection and stream receive windows replenish only after application data is
  consumed. Outbound DATA is copied, flow-controlled, and selected by a bounded
  weighted scheduler before transport ownership begins.
- Request, response, informational, trailer, and push pseudo-fields are validated at
  the connection boundary. Forbidden fields, authority conflicts, content-length
  mismatches, and data on bodyless responses reset only the affected stream.
- Header, request, idle, write, and total deadlines are absolute. Slow progress does
  not refresh them. Graceful close finishes admitted work before write half-close.
- HTTP/3 frame headers, SETTINGS pairs, typed control payloads, and unidirectional
  stream headers accept arbitrary fragmentation and retain borrowed payload input
  only until explicit release.
- QPACK encoder and decoder instructions are incremental and bounded independently
  from encoded field sections. Dynamic entries own their bytes in caller storage.
- QPACK field decoding retains a blocked section in its QUIC stream flow-control
  window until its Required Insert Count arrives. Blocked streams, outstanding
  sections, references, fields, decompressed bytes, strings, and wire bytes have
  independent caller-selected limits.
- QPACK encoders protect every referenced dynamic entry until Section Acknowledgment
  or Stream Cancellation. Insert Count Increment advances only through inserts that
  were actually sent.
- HTTP/3 connections open and validate all three critical streams, enforce bounded
  request and peer-stream admission, and keep QPACK-blocked field-section bytes out
  of QUIC flow-control credit while unrelated requests continue.
- HTTP/3 request DATA borrows one stream buffer until explicit consumption. Partial
  writes remain in caller-owned output, and request FIN is published only after the
  complete frame is accepted by QUIC.
- HTTP/3 request, response, informational, trailer, target, body byte, DATA frame,
  request admission, and peer-stream limits remain independent.
- HTTP/3 GOAWAY boundaries are monotonic. Graceful close rejects only work beyond the
  final boundary and waits for admitted exchanges and critical output to settle.
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

## HTTP/2 codecs

`http.h2.frame.Parser` returns a validated header followed by borrowed payload views.
Each payload must be released before parsing continues. Unknown extension frame types
remain available to the caller while mandatory continuation sequencing still applies.
The matching writer copies caller payload into output slices and retains no payload
pointer between calls.

`http.h2.hpack.Decoder` accepts fragmented encoded input into caller storage, then
decodes the completed block into caller-owned fields and bytes. Dynamic table size
updates, insertions, and evictions are simulated in a bounded shadow and commit only
after the block passes every limit and representation check. The encoder uses the
same transaction rule. See [doc/h2-codecs.md](doc/h2-codecs.md) for API ownership and
resource contracts.

## HTTP/2 connections

`http.h2.connection.Engine` binds the frame and HPACK codecs to the common ordered
transport. Reads and writes retain the engine's buffers only through their exact
transport completion tokens. Header and DATA events borrow caller storage until
`release_event` or `consume_data` returns it.

Each accepted request stream has one generation and must bind one
`http.core.exchange.Exchange` before its request-header event is released. This
keeps service cancellation, response construction, streaming bodies, and terminal
completion version-neutral. See [doc/h2-connection.md](doc/h2-connection.md) for the
state, memory, flow-control, and graceful-drain contracts.

## HTTP/3 codecs

`http.h3.frame.Parser` decodes QUIC variable-length frame headers and returns borrowed
payload views. It enforces frame placement, SETTINGS-first control streams, duplicate
and reserved settings, exact typed control payloads, reserved HTTP/2 frame types, and
bounded unknown extensions. `StreamParser` claims the single control, QPACK encoder,
and QPACK decoder streams and rejects client push streams.

`http.h3.qpack` implements the complete RFC 9204 static table, dynamic insertion and
eviction, both instruction streams, field-section prefixes, all indexed and literal
representations, Huffman strings, blocked-section retry, reference protection, and
decoder feedback. Tables and sections use caller-owned arrays and arenas. See
[doc/h3-codecs.md](doc/h3-codecs.md) for memory, lifetime, and flow-control contracts.

`http.h3.connection.Engine` binds those codecs to a bounded QUIC stream adapter.
Reads separate delivery from flow-control credit, writes copy accepted bytes, and
every server request must bind the common service exchange before its header event is
released. See [doc/h3-connection.md](doc/h3-connection.md) for stream, memory, error,
and graceful-close contracts.

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
