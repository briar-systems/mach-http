# HTTP/2 connection engine

`http.h2.connection.Engine` is an allocation-free HTTP/2 client and server state
machine. It composes the strict frame codec, transactional HPACK codec, common
ordered transport, and version-neutral service exchange.

## Memory and initialization

Every buffer and table is caller-owned. `init` receives:

- connection read and write buffers
- one complete inbound-frame payload buffer sized for the advertised maximum frame
- one outbound HPACK field-block buffer
- bounded inbound and outbound dynamic-table entry arrays and byte arenas
- bounded encoder shadow entries and a control-frame queue
- a `Stream` and `StreamMemory` array

`capacity` must be greater than `Config.max_streams`. The extra physical slot is a
protocol reserve. When the admitted-stream budget is full, the engine still decodes
one refused header block transactionally before sending `REFUSED_STREAM`. This keeps
the connection HPACK context synchronized under saturation. If even the reserve is
unavailable because closed generations were not released, the connection fails with
`ENHANCE_YOUR_CALM` instead of continuing with a corrupt compression context.

`destroy` returns the engine to the state `init` accepts, so one set of caller-owned
storage can carry a succession of connections. It refuses while the transport still
owns a read, write, or close operation, while the application still borrows an
event, and while any stream is live, because each of those is a reference into
storage the caller is about to reuse. It clears every initialization guard the
engine holds by value, including both HPACK dynamic tables, the frame parser, and
the frame writer, so no consumer has to reach in and clear one. Both dynamic tables
come back empty: a surviving table would decode the next connection against entries
its peer never inserted. The connection itself is not pooled, only the storage, so
the next `init` takes a fresh transport.

HPACK storage must cover the protocol's 4096-byte initial table size even when the
advertised table size is lower. A lower local size takes effect only after its
SETTINGS bytes complete on the transport. The next peer field block must then carry
the required table-size update.

## Preface and settings

Clients write the 24-byte connection preface before their initial SETTINGS. Servers
do not emit HTTP/2 frames until that preface is validated byte for byte. In both
roles, the peer's first frame must be a non-acknowledgement SETTINGS frame.

`send_settings` permits one outstanding local settings transaction. Header-table,
initial-window, frame-size, concurrency, header-list, push, and extended-CONNECT
values are validated before queuing. Peer initial-window changes are applied to every
live stream using signed windows and fail before exceeding the protocol range.

`Config.connection_window_size` expands the connection receive window with an
initial WINDOW_UPDATE. It and every stream receive window are hard budgets. Incoming
DATA charges both windows including padding. Only bytes returned through
`consume_data`, plus padding consumed by the engine, become eligible for a later
WINDOW_UPDATE.

## Streams and exchanges

Stream IDs are role-correct, monotonic, and bounded to 31 bits. The engine implements
idle, reserved-local, reserved-remote, open, half-closed-local,
half-closed-remote, and closed states. Closed slots keep their generation until
`release_stream` succeeds, so stale application references cannot address a reused
stream.

An inbound request header event exposes decoded pseudo-fields and the offset of the
first regular field. Before releasing that event, initialize a common
`http.core.exchange.Exchange` with the event generation and stream ID, then call
`bind_exchange`. `dispatch` begins that exact exchange and invokes a common service.
The protocol engine never owns application request or response objects.

If GOAWAY rejects an unprocessed local stream, `EVENT_STREAM_RETRY` preserves its
generation. `detach_exchange` transfers the bound exchange back to the caller before
the closed stream slot is released. Other reset and connection-failure paths cancel
the bound exchange. A stream with asynchronous cancellation still pending cannot be
released until the exchange reaches a terminal state.

## Headers and bodies

Header blocks may span any number of HEADERS, PUSH_PROMISE, and CONTINUATION frames.
No control frame can interleave with an outbound continuation sequence. Incoming
blocks commit their shared HPACK table before HTTP semantic validation, as required
to keep compression synchronized even when one stream is reset.

The semantic validator enforces:

- required, unique, ordered request and response pseudo-fields
- ordinary CONNECT and negotiated extended CONNECT shapes
- valid methods, schemes, paths, authorities, and three-digit statuses
- lowercase field names and valid field values
- rejection of connection-specific fields and TE values other than `trailers`
- matching Host and `:authority` values
- trailer field restrictions
- identical numeric content lengths, exact body byte counts, and bodyless response
  rules

Inbound DATA events borrow the frame-payload buffer and block another read until all
bytes are consumed. Outbound DATA is copied into the engine write buffer before the
call returns. The application pointer is never retained across a transport
submission.

## Flow control and prioritization

`set_writable` marks streams with application DATA available. `writable_stream` uses
bounded smooth weighted scheduling across streams with positive connection and
stream credit. `offer_data` accepts only the selected stream, copies no more than all
negotiated and configured frame and window limits, and reports partial consumption.

Legacy PRIORITY dependencies, exclusivity, and weights are validated. A dependency
that would create a cycle is reparented before the new relationship is installed.
Scheduling intentionally flattens the dependency tree to weights. HTTP/2 permits
priority information to be ignored, while the weighted scheduler provides bounded
fairness and no starvation without allocating idle priority nodes.

## Shutdown and ownership

PING acknowledgements, SETTINGS acknowledgements, resets, window updates, and
GOAWAY frames use the bounded control queue. Partial writes retain the stable engine
buffer until the matching transport completion. Stale or mismatched completion
tokens fail the connection.

`begin_graceful` queues the first GOAWAY with the maximum stream ID.
`finish_graceful` queues the final GOAWAY with the highest admitted remote stream.
Existing streams may finish between those frames. `progress_close` submits the
physical close only after the final GOAWAY, all admitted streams, all header
continuations, and all queued output have settled. Protocol failure instead flushes
one error GOAWAY when possible, cancels every bound exchange, and closes after that
output completes.
