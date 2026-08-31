# HTTP/3 connection ownership

`http.h3.connection.Engine[T]` binds the HTTP/3 frame and QPACK codecs to a
bounded QUIC stream adapter. It allocates nothing and owns no packet, recovery,
TLS, socket, or QUIC connection state.

## QUIC boundary

`Transport[T]` carries `context: *T`, and every adapter callback accepts that same
typed pointer. The type is part of `Engine[T]` and every engine operation. This
lets a production adapter retain a QUIC driver that reaches secret-welded packet
keys, which cannot be erased to an untyped `ptr`. The engine only passes the
context to callbacks. It never inspects its bytes or claims its ownership, so the
transport contract needs no context range.

The adapter exposes local stream creation, peer stream acceptance, receive,
explicit receive credit, copied writes, FIN, RESET_STREAM, STOP_SENDING, release,
and application close. Stream handles carry source, slot, generation, and QUIC
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

`release` means the stream is settled, not merely finished with. A stream this side
has just reset still owes the peer's acknowledgment of that reset, so `release`
reports `TRANSPORT_BLOCKED` until the transport can free the handle. The engine
retries every blocked release on each `process` and only a stale or failing release
closes the connection.

`test/h3-quic` binds this adapter to the `mach-quic` connection driver and drives
two real drivers against each other. Stream handle identity, delivery, and receive
credit map one to one, and the driver's own uncredited total proves that `read`
returns no window. Two statuses need translating: the QUIC write status answers
whether the entire write was accepted rather than whether the call made progress,
and QUIC names an unsettled release a stream state error rather than a blocked one.
No packet, TLS, or recovery API crosses this boundary.

The engine does not advertise HTTP Datagrams because the adapter intentionally has
no datagram surface. A peer may advertise datagram support without changing request
stream operation. A future datagram extension can add a separate bounded adapter
without changing stream delivery or credit ownership.

## Memory and limits

The caller provides the stream slots, one `StreamMemory` per slot, and the
pending-release array that holds handles whose release the transport has not yet
completed. Each memory
record independently bounds read fragments, SETTINGS entries, encoded field
sections, decoded fields, decoded string storage, QPACK scratch, output bytes, and
field references. Connection storage separately owns both QPACK tables, table
arenas, table scratch, outstanding section and reference arrays, the pending-release
array, and the three local critical-stream queues.

`destroy` returns the engine to the state `init` accepts, so one set of caller-owned
storage can carry a succession of connections. It refuses while a request is live or
while the transport still owes a release, because both are references into storage
the caller is about to reuse; the peer's control and QPACK streams stay live for the
whole connection and are reclaimed by the transport close, so they do not block
teardown. It clears every initialization guard the engine holds by value, including
both QPACK tables, the inbound and outbound section sets, and the critical-stream
record, and both tables come back empty. The stream slots are reset by the next
`init`. The QUIC connection is not pooled, only the storage.

The caller zero-initializes `Engine`, `Stream`, and codec records before their first
initialization. `init` validates every configured table, section, queue, stream, and
memory capacity before the engine becomes live. Closed stream slots retain their
generation until `release_stream` succeeds, then reuse advances the generation.

`max_requests` and `max_peer_unidirectional` are enforced independently. A request
beyond the request budget is rejected with `H3_REQUEST_REJECTED`, and a QPACK Stream
Cancellation is queued without admitting the request. Rejecting a request never
consumes a stream slot, so its handle is held in the pending-release array until the
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

## Critical streams and frames

The engine opens one local control, QPACK encoder, and QPACK decoder stream and writes
their type prefixes incrementally. SETTINGS is the first control frame. Peer
unidirectional streams are classified incrementally, including split QUIC variable
integers. Duplicate critical streams, client push streams, and closure or reset of a
critical stream fail the connection.

Unknown unidirectional stream types are drained within their configured stream-slot
budget. Push is not negotiated by this engine. A received push stream, PUSH_PROMISE,
CANCEL_PUSH, or MAX_PUSH_ID therefore fails with the applicable ID or creation error.

Request streams enforce HEADERS before DATA, informational responses before the final
response, a configured informational count, at most one trailer section, and no DATA
after trailers. Unknown extension frames are drained wherever request stream framing
permits them. Pseudo-fields,
CONNECT shapes, forbidden connection fields, TE, authority conflicts, content
length, bodyless responses, and trailer names use the same validation rules as the
HTTP/2 connection boundary.

## QPACK and receive credit

HEADERS payload is copied into the stream's bounded QPACK field decoder. Frame header
bytes are credited immediately. Field-section bytes accumulate as uncredited bytes
until decode completes. If Required Insert Count is unavailable, the section keeps
its `Sections` slot and all of its QUIC credit while other streams continue.

Encoder-stream insertions retry blocked streams. Successful decode queues Section
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
