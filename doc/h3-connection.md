# HTTP/3 connection ownership

`http.h3.connection.Engine[T]` binds the HTTP/3 frame and QPACK codecs to a
bounded QUIC stream adapter. It never allocates, and owns no packet, recovery,
TLS, socket, or QUIC connection state. Stream records and request buffers are
borrowed from a `std.memory.buffers` account.

## QUIC boundary

`Transport[T]` carries `context: *T`, and every adapter callback accepts that same
typed pointer. The type is part of `Engine[T]` and every engine operation. This
lets a production adapter retain a QUIC driver that reaches secret-welded packet
keys, which cannot be erased to an untyped `ptr`. The engine only passes the
context to callbacks. It never inspects its bytes or claims its ownership, so the
transport contract needs no context range.

The adapter exposes local stream creation, peer stream acceptance, readiness,
receive, explicit receive credit, copied writes, FIN, RESET_STREAM, STOP_SENDING,
release, and application close. Stream handles carry source, slot, generation, and QUIC
stream ID identity. A stale or structurally invalid result fails the connection.

Receive is deliberately two phase. `Transport.read` advances delivery into the
engine-owned stream buffer without returning connection or stream flow-control
credit. `Transport.credit` returns exactly the bytes whose HTTP ownership has ended.
This distinction is required for QPACK-blocked field sections and application-held
DATA. An adapter that grants credit during `read` does not satisfy this contract.

Writes copy every accepted byte before returning. Partial acceptance leaves the
remaining bytes in the stream's caller-owned output buffer. HTTP retains no
application payload pointer across the adapter call. A write status answers
whether the call made progress, not whether the whole offer was taken: any
accepted byte is reported as success with the accepted count, and a blocked
status means no byte was accepted.

Successful FIN reports must carry the exact delivered final size. Resets may name a
larger final size but never one below already delivered bytes. Stale handles, invalid
status combinations, duplicate local stream IDs, and failed cancellation close the
connection as transport failures. A blocked connection close is retried and is never
reported complete early.

## Readiness

`Transport.ready` returns the next stream whose transport state changed, as a
`TransportReady` carrying the stream handle and `readable`, `writable`, and `reset`
bits, or `TRANSPORT_EMPTY` when nothing is waiting. Any other status fails the
connection. The engine only reads and writes streams it has work for, so this is
the only way it learns that a parked stream can make progress. The contract is
written against the hardest adapter, one whose readiness queue can repeat itself:

- Report every stream whose readable, writable, or reset state changed since that
  stream's last `read` returned EMPTY or BLOCKED, or its last `write` or `finish`
  returned BLOCKED. Set `readable` for new data or a FIN, `writable` for new send
  capacity, and `reset` for RESET_STREAM or STOP_SENDING.
- No report may be dropped. A lost report can strand a stream forever.
- Duplicate reports, reports with no news, reports for streams the engine never
  held or already released, and reports with a stale generation are all harmless.
  A spurious report with `readable` set costs at most one empty read.
- A stream that `accept` has not yet returned needs no report. The engine reads
  every stream once when it accepts or opens it, and once when it places a parked
  stream.
- The peer's control and QPACK streams follow the same rule. Nothing is read
  unconditionally on each call.
- The engine's own control, encoder, and decoder streams are written on every
  `process` while their queues hold bytes, so reports for them are ignored.

A report with `readable` or `reset` set on a stream whose field section is blocked
on QPACK makes the engine probe it with a zero-length read, which is how a reset of
a blocked stream is noticed.

`release` means the stream is settled, not merely finished with. A stream this side
has just reset still owes the peer's acknowledgment of that reset, so `release`
reports `TRANSPORT_BLOCKED` until the transport can free the handle. The engine
retries every blocked release on each `process` and only a stale or failing release
closes the connection.

`test/h3-quic` binds this adapter to the `mach-quic` connection driver and drives
two real drivers against each other. Stream handle identity, delivery, and receive
credit map one to one, and the driver's own uncredited total proves that `read`
returns no window. `ready` maps one to one onto mach-quic's
`transport.ready_stream`. Two statuses need translating: the QUIC write status answers
whether the entire write was accepted rather than whether the call made progress,
and QUIC names an unsettled release a stream state error rather than a blocked one.
No packet, TLS, or recovery API crosses this boundary.

The engine does not advertise HTTP Datagrams because the adapter intentionally has
no datagram surface. A peer may advertise datagram support without changing request
stream operation. A future datagram extension can add a separate bounded adapter
without changing stream delivery or credit ownership.

## Memory and limits

`Storage` is caller storage for per-connection state:

- both QPACK tables with their arenas and scratch, and the outstanding section and
  reference arrays
- the three local critical-stream queues
- the pending-release array, which holds handles whose release the transport has not
  yet completed
- a `CriticalMemory`, which the peer's control, QPACK encoder, and QPACK decoder
  streams read through
- a `std.memory.buffers.Source` and the connection's open account on it, both of
  which must outlive the engine

Each critical stream uses only the buffers its kind needs:

| Stream | Buffers |
| --- | --- |
| control | `read`, and `settings` for at least `frames.max_settings` entries |
| QPACK encoder | `read`, `encoded` for an inbound instruction, `scratch` for twice an inbound field |
| QPACK decoder | `read`, and `encoded` for an outbound instruction |

Everything else is borrowed from the account. `Config` sizes it:

| Memory | Size | Held | Lane |
| --- | --- | --- | --- |
| stream records and the index | `initial_streams` records at first, then doubling | from `init` until `destroy`, growing up to `max_requests + max_peer_unidirectional` | `connection_lane` |
| request set | `read_bytes`, `output_bytes`, and the encoded section, fields, strings, scratch, and references from the QPACK limits | from stream allocation until `release_stream`, or until `destroy` if it was never released | `stream_lane` |

`init` takes the first record chunk and its index, and a refusal there fails `init`.
At `config_default` an idle engine holds 12,544 bytes on x86_64: eight 1,536-byte
records and a 16-entry index. A request set is 217,808 bytes. Records live in
`http.core.records` chunks, so a record never moves once handed out. When the table
grows, the index is rebuilt at the new size. The table never shrinks while the
connection lives.

`request_requests(configured, out)` writes the `REQUEST_BUFFERS` requests a request
set is acquired with, the same table `acquire_request_memory` reads.
`request_footprint(source, configured)` measures that table against a source with
`buffers.source_measure`, so it is the bytes `account.held` grows by when a request
is admitted on that pool, at the pool's own class sizes. Both return nothing useful
for a config `init` would refuse, and the footprint is 0 for a source that would
refuse the set. A host sizing lane budgets or admission limits should use the
footprint, not the sum of the requests, since a pool with size classes charges each
chunk its class.

A peer unidirectional stream borrows no buffer. Until its type is known it reads one
byte at a time into its own record, so no frame byte arrives before the stream is
classified. A critical stream then reads through its `CriticalMemory`. A stream of an
unknown type is drained through a 64-byte buffer inside the engine, and its bytes
are credited in the same call that reads them.

A refusal never fails the connection:

- A refused request set or record for a peer request rejects it with
  `H3_REQUEST_REJECTED`, as the request budget does, and registers nothing.
- A refused request set or record for a client request makes `open_request` return
  `NO_STREAM` before any transport stream is opened.
- A peer unidirectional stream may be critical, so a refused record does not refuse
  it. The engine parks the accepted handle and accepts nothing else. The stream stays
  unread in the transport. `process` returns `EVENT_MEMORY_BLOCKED` and places the
  stream once a record is free. If the pool was exhausted, or its backing refused,
  the account is registered for one wake-up. After the source reports it ready, call
  `process`. A refusal against the account's own lane budget ends when this
  connection releases a stream.

A request holds its record and set until `release_stream`, closed or not. Request
admission and `open_request` therefore also stop once `max_requests` sets are held.
Peer unidirectional streams never hold more than `max_peer_unidirectional` records.
Once the table reaches its cap, a record is always free for the admission checks.

`destroy` returns every borrowed record and buffer to the account and the engine to
the state `init` accepts, so one set of caller-owned storage can carry a succession of
connections. It refuses while a request is live, and while the transport still owes a
release before the connection has closed, because both are references into state the
caller is about to reuse. Releases the peer never acknowledged stop blocking once the
engine is closed. After a failure or close, a terminal request's header event can be
released without an exchange, and held data can still be consumed. The engine then
grants the transport no more credit, so a failed engine can always be destroyed. The
peer's control and QPACK streams stay live for the whole connection and are reclaimed
by the transport close, so they do not block teardown. It clears every initialization
guard the engine holds by value, including both QPACK tables, the inbound and
outbound section sets, and the critical-stream record, and both tables come back
empty. The QUIC connection is not pooled, only the storage.

The caller zero-initializes `Engine` and codec records before their first
initialization. `init` validates every configured table, section, queue, critical
buffer, and request size before the engine becomes live. Closed streams keep their
generation until `release_stream` succeeds, and reuse then advances the generation.

`max_requests` and `max_peer_unidirectional` are enforced independently. A request
beyond the request budget is rejected with `H3_REQUEST_REJECTED`, and a QPACK Stream
Cancellation is queued without admitting the request. Rejecting a request never
consumes a stream record, so its handle is held in the pending-release array until the
transport settles it. Exhausting the peer unidirectional budget is a connection-level
excessive-load failure because doing otherwise could discard a required critical
stream.

`max_pending_release` bounds the handles awaiting release and must be sized against
the peer-initiated streams the transport can hand over between two `process` calls,
which in steady state is the peer's stream concurrency limit. Exhausting it is a
connection-level excessive-load failure, because the alternative is abandoning a
transport handle the peer is still owed credit for.

Common HTTP limits remain independent of QPACK limits. Request, response,
informational, and trailer regular fields use their own count, byte, name, and value
bounds. Method, protocol, scheme, authority, path, and query views use the common
request and target bounds. Request and response bodies separately bound total bytes,
DATA frame bytes, and DATA frame count in each direction. A rejected offer does not
advance any byte or frame counter.

The local SETTINGS values are bound to the inbound QPACK limits. Peer SETTINGS bind
the outbound encoder after the control stream validates them. Peer allowances larger
than local storage are safely used at the local configured ceiling. Peer field-size
and blocked-stream allowances smaller than local maxima narrow the outbound encoder.

## Scheduling and cost

Every per-event path costs O(streams with news), not O(stream capacity).

- Stream lookup by id is an open-addressed hash of the id into the borrowed index
  with linear probing. Removal leaves a tombstone, found in
  O(1) through the position each stream records. The index is rebuilt in place once
  tombstones pass a quarter of its capacity, so removal stays amortized O(1).
  `stream_for` and every call that names a stream id are O(1).
- Free records form an intrusive list, extended whenever the table grows, so
  allocation and release are O(1) apart from a growth step. Growth rebuilds the index
  once per doubling. Generations advance on every allocation.
- Streams with engine-side work sit on an intrusive FIFO. A stream is queued when it
  holds an event to re-emit, has buffered unparsed input, has request output or a
  FIN to submit that is not parked on a blocked write, owes a retry after GOAWAY,
  has a completed frame to finish, has a FIN to handle, or needs a read that has not
  returned EMPTY since the last `readable` report. Reports from `Transport.ready`
  and application calls (`send_headers`, `offer_data`, `consume_data`,
  `release_event`) queue a stream when they give it work.
- A QPACK-blocked stream waits on a list ordered by Required Insert Count. An
  encoder-stream insert queues exactly the prefix of that list the new insert count
  satisfies.
- `process` accepts at most one peer stream, drains at most 64 readiness reports,
  and services at most 64 queued streams, each at most once. A stream that still
  has work after its turn goes back to the tail, so work is shared round-robin and
  a call returns the first event it produces. With no news, one `process` call makes
  one `accept` and one `ready` call and visits no stream.
- `tick` walks only the request streams bound to an exchange.

`process` returns one of four kinds of result, and the host loop follows them:

- An event: handle it and call `process` again.
- `EVENT_PENDING`: progress was made and work remains that this call's budgets did
  not reach. Call `process` again at once. This covers a queue still holding
  streams, a readiness backlog the 64-report budget did not drain, and a peer
  stream just accepted when another may be waiting.
- `EVENT_MEMORY_BLOCKED`: a parked peer stream waits for a record. Wait for the
  account's wake-up, a released stream, or transport news.
- `EVENT_BLOCKED`: nothing remains but output the transport refused. Wait for
  transport news.
- `EVENT_NONE`: the last `ready` returned EMPTY, `accept` had nothing, and the
  queue is empty. Wait for transport or application news.

PENDING takes precedence over MEMORY_BLOCKED, and MEMORY_BLOCKED over BLOCKED. A queued stream always
makes progress when serviced (its codecs consume at least one byte per call, and a
blocked write or an EMPTY read parks it), so PENDING cannot repeat forever without
new input.

A host that cancels an exchange scope must call `cancel_stream` for that request.
That is O(1) and resets the stream immediately. `tick` is the fallback for scopes
cancelled elsewhere, such as a parent scope, and costs O(bound requests), so it
belongs on a timer rather than on every event.

GOAWAY handling, connection failure, and `destroy` still walk the stream table.
Each runs at most once per connection.

## Critical streams and frames

The engine opens one local control, QPACK encoder, and QPACK decoder stream and writes
their type prefixes incrementally. SETTINGS is the first control frame. Peer
unidirectional streams are classified incrementally, including split QUIC variable
integers. Duplicate critical streams, client push streams, and closure or reset of a
critical stream fail the connection.

Unknown unidirectional stream types are drained through the engine's discard buffer
and count against `max_peer_unidirectional` until their FIN. Push is not negotiated by this engine. A received push stream, PUSH_PROMISE,
CANCEL_PUSH, or MAX_PUSH_ID therefore fails with the applicable ID or creation error.

Request streams enforce HEADERS before DATA, informational responses before the final
response, a configured informational count, at most one trailer section, and no DATA
after trailers. Unknown extension frames are drained wherever request stream framing
permits them. Pseudo-fields,
CONNECT shapes, forbidden connection fields, TE, authority conflicts, content
length, bodyless responses, and trailer names use the same validation rules as the
HTTP/2 connection boundary, through the shared `http.core.section` validator. A
received field name must be lowercase. A caller's name
may use any case and is written lowercase by the QPACK encoder.

## QPACK and receive credit

HEADERS payload is copied into the stream's bounded QPACK field decoder. Frame header
bytes are credited immediately. Field-section bytes accumulate as uncredited bytes
until decode completes. If Required Insert Count is unavailable, the section keeps
its `Sections` slot and all of its QUIC credit while other streams continue.

Encoder-stream insertions wake exactly the blocked streams whose Required Insert
Count they satisfy. Successful decode queues Section
Acknowledgment, releases the held credit, and publishes the decoded header event.
Reset or local cancellation of a blocked stream releases its QPACK slot and queues
Stream Cancellation. Insert Count Increment feedback is aggregated when the decoder
queue is temporarily full.

DATA events borrow the stream read buffer. `consume_data` may release a prefix and
returns matching QUIC credit. No new read can overwrite that buffer until the event
is fully consumed. Header events borrow decoded field storage until `release_event`.
A server request-header event cannot be released until its stream is bound to one
generation-matched `http.core.exchange.Exchange`.

## Output and shutdown

`send_headers` validates and QPACK-encodes one request, informational response, final
response, or trailer section into the stream output buffer. `offer_data` copies a
bounded DATA prefix. FIN is submitted only after all frame bytes are accepted.
Dynamic table capacity and literal insertion instructions use the local encoder
stream and retain references until decoder feedback.

Peer GOAWAY values are monotonic. A client marks local requests at or above the
server's boundary for retry and permits their exchange to be detached. Server
graceful shutdown first sends the maximum request-stream ID, then the first request
ID not admitted. New requests at or above the final boundary are rejected. The QUIC
application close begins only after final GOAWAY, every admitted request, all stream
output, and all critical queues settle. Remote FIN produces one terminal event even
while the local response side remains open.

Connection cancellation and protocol failure cancel every bound exchange, reset
live request streams, map the exact HTTP/3 or QPACK application error to QUIC, and
close once.
