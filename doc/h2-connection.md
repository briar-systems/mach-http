# HTTP/2 connection engine

`http.h2.connection.Engine` is an HTTP/2 client and server state machine. It
composes the strict frame codec, transactional HPACK codec, common ordered
transport, and version-neutral service exchange. It never allocates. Stream records
and per-stream and transient buffers are borrowed from a `std.memory.buffers`
account.

## Memory and initialization

`init` receives caller storage for per-connection state:

- the connection read buffer
- bounded inbound and outbound dynamic-table entry arrays and byte arenas
- a control-frame queue
- one `StreamMemory` that decodes a refused header block
- a `std.memory.buffers.Source` and the connection's open account on it, both of
  which must outlive the engine

Everything else is borrowed from the account. `Config` sizes it:

| Memory | Size | Held | Lane |
| --- | --- | --- | --- |
| stream records and the index | `initial_streams` records at first, then doubling | from `init` until `destroy`, growing up to `max_streams` | `connection_lane` |
| stream decoder set | encoded block, fields, strings, and pending entries from `Config.hpack` | from stream allocation until `release_stream` | `stream_lane` |
| write buffer | `write_bytes` | while a frame is staged or in flight | `connection_lane` |
| frame payload | `frame_payload_bytes` | while a frame's payload is copied, and until a DATA event it backs is consumed | `connection_lane` |
| encoder output and pending entries | from `Config.hpack` | from `send_headers` or `send_push_promise` until the block's last frame is written | `connection_lane` |

`init` takes the first record chunk and its index. A refusal there fails `init`. At
`config_default` an idle engine holds 2,880 bytes on x86_64: four 656-byte records
and a 16-entry index. Records live in `http.core.records` chunks, so a record never
moves once handed out. When the table grows, the index is rebuilt at the new size.
The table never shrinks while the connection lives.

A refusal never fails the connection:

- A refused decoder set or record for a peer stream refuses that stream with
  `REFUSED_STREAM`. The reserve stream still decodes the block, so the HPACK context
  stays in step. The refusal registers nothing, since the peer retries a refused
  stream on its own.
- A refused set or record for a local stream makes `open_local` or `reserve_push`
  return 0.
- A refused write buffer makes `submit_write` return false and `offer_data` return
  `OFFER_BLOCKED` with `ERROR_MEMORY`. A refused encoder buffer makes `send_headers`
  or `send_push_promise` return the same, and the dynamic table is left untouched.
- A refused payload buffer makes `process` return `EVENT_MEMORY_BLOCKED`. The frame
  header is already consumed, so the next `process` retries the buffer first.

A transient refusal (write, payload, or encoder buffer) sets `memory_blocked`. If the
pool was exhausted, or its backing refused, the account is also registered for one
wake-up. After the source reports it ready, drive the connection again.

The reserve is one inline stream. When the admitted-stream budget is full, or memory
refuses a peer stream, the engine still decodes one refused header block
transactionally before sending `REFUSED_STREAM`. This keeps the connection HPACK
context synchronized under saturation. If the reserve is busy because its
generation was not released, the connection fails with `ENHANCE_YOUR_CALM` instead
of continuing with a corrupt compression context.

`destroy` returns every borrowed record and buffer to the account and the engine to
the state `init` accepts, so one set of caller-owned storage can carry a succession
of connections. It refuses while the transport still
owns a read, write, or close operation, while the application still borrows an
event, and while any stream is live before the connection has closed, because each
of those is a reference into storage the caller is about to reuse. Once the close
completes, streams the host never released no longer block it, including those it
never heard of, and `destroy` releases their memory. A closed stream's header event
can be released without binding an exchange, so a failed engine can always be
destroyed. It clears every initialization guard the
engine holds by value, including both HPACK dynamic tables, the frame parser, and
the frame writer, so no consumer has to reach in and clear one. Both dynamic tables
come back empty: a surviving table would decode the next connection against entries
its peer never inserted. The connection itself is not pooled, only the storage, so
the next `init` takes a fresh transport.

HPACK storage must cover the protocol's 4096-byte initial table size even when the
advertised table size is lower. A lower local size takes effect only after its
SETTINGS bytes complete on the transport. The next peer field block must then carry
the required table-size update.

## Stream table

Every per-event path costs O(changed streams), not O(capacity).

- **Index.** The index is open-addressed with linear probing on a `fmix64` hash of
  the stream ID. Each stream records its index position, so removal is O(1) and
  leaves a tombstone. When tombstones pass `index_capacity / 4`, the index is
  rebuilt in place from the live slots. A rebuild needs more than
  `index_capacity / 4` removals since the last one, so its cost is amortized O(1)
  per removal. Live entries fill at most half the index and tombstones at most a
  quarter, so every probe sequence reaches an empty entry.
- **Free list.** Free slots form an intrusive list, extended whenever the table
  grows. Allocation and `release_stream` are O(1), apart from a growth step. A
  released slot is reused first. Every allocation takes a fresh generation.
- **Stream memory.** A stream that decodes header blocks takes its decoder set when
  it is allocated and returns it at `release_stream`. A pushed stream reserved
  locally decodes nothing and takes none.

Each stream also carries links for the engine's work sets. A stream is a member of
a set exactly when its state says it has that kind of work. Every mutation that
can change membership ends in one refresh of all three predicates.

| Set | Member when | Consumed by |
| --- | --- | --- |
| ready queue (FIFO) | `retry_pending` is set by GOAWAY | `process` |
| window list (FIFO) | the stream is open and owes a WINDOW_UPDATE | output preparation and write completion |
| writable set | writable, headers sent, positive send window, sendable state | `writable_stream` |
| exchange list | open with a bound exchange | `tick` |

`Engine.slot_visits` counts the stream records the engine inspects. It is a
diagnostic for tests and does not count O(1) link fixes on neighbouring slots.
`Engine.index_rebuilds` counts index rebuilds.

## Processing and the host loop

`process` returns one event per call. Each call services at most 64 units of
work. A unit is one ready-queue entry, or one inbound frame that produced no
event. When the budget runs out and work remains, `process` returns
`EVENT_PENDING`: progress was made and the host should call `process` again.
`EVENT_PENDING` takes precedence over `EVENT_NEED_READ`. A ready-queue entry that
still has work after its unit is serviced goes back to the tail of the queue, so
streams take turns.

`EVENT_NEED_READ` means that nothing remains without new input. The engine never
returns `EVENT_NONE` from `process` with work still queued. `complete_io` returns
the result of `process` for a read completion, so the same rules apply to it.

```text
loop:
    event = process(engine)            # or the result of complete_io
    if event.kind == EVENT_PENDING:    continue
    if event.kind == EVENT_NEED_READ:  submit_read, then wait for a completion
    otherwise:                         handle the event (release or consume it), continue
    whenever output may exist:         submit_write until it returns false
```

`submit_read` refuses while unparsed input remains, so a host that stops on
`EVENT_PENDING` without calling `process` again stalls the connection.

After a GOAWAY, `EVENT_STREAM_RETRY` events come out in the order the GOAWAY sweep
found the streams, one per `process` call.

## Cancelling exchanges

A host that cancels an exchange scope it owns must call `cancel_stream` for that
stream. The call is O(1). It queues RST_STREAM, cancels the bound exchange, and
closes the stream. The engine cannot learn about a scope change any other way.

`tick` is only the fallback for scopes cancelled elsewhere. It walks the exchange
list, which costs O(open exchange-bound streams), and it reports the first
cancelled one. Call it from a timer, not once per event.

## Complexity

| Path | Cost |
| --- | --- |
| stream lookup, allocation, release | O(1) expected, amortized for rebuilds |
| `process`, per call | O(1) ready-queue work plus O(bytes parsed), capped at 64 units |
| window flush, per output or completion | O(1) |
| `writable_stream` | O(writable set) |
| `tick` | O(open exchange-bound streams) |
| PRIORITY frame or HEADERS priority block, exclusive or not | O(1) |

These passes still cover the whole table. None of them runs on a routine path:

- `fail_connection`, once per connection
- a received GOAWAY, once per GOAWAY
- a peer SETTINGS change to `INITIAL_WINDOW_SIZE`, once per such frame
- the acknowledgement of a local SETTINGS frame, once per `send_settings`
- `init`, which also clears the index
- table growth, which rebuilds the index once per doubling of the table

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
the bound exchange. During owner teardown, `abandon_exchange` transfers a bound
exchange from an exact closed stream generation after initiating cancellation when
needed. The caller then owns any pending body completion. The engine cannot address
the detached exchange, and the stream slot can be released without waiting for that
completion.

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
smooth weighted round robin over the writable set. A stream is in the set when it
is marked writable, has sent its initial headers, has a positive send window, and
is open or half-closed (remote). The connection window gates the whole scheduler.
Streams outside the set are never visited and their credit does not change.

Each selection adds every member's weight to its credit and picks the highest
credit, taking the lowest stream ID on a tie. The winner is then charged the set's
total weight. This is the same algorithm the engine used when it scanned the whole
table, so the order is the same. While the set stays unchanged, each period of
`sum(weights)` selections gives every member exactly `weight` turns, and no
member waits more than one period.

`offer_data` accepts only the selected stream, copies no more than all negotiated
and configured frame and window limits, and reports partial consumption.

RFC 9113 deprecates the PRIORITY dependency signal and lets an endpoint ignore it.
The engine therefore keeps no dependency tree. PRIORITY frames and HEADERS priority
blocks are parsed and validated, and their dependency and exclusive bits are then
ignored. Only the weight is stored, and only weights affect scheduling. The
weighted scheduler gives bounded fairness with no starvation and allocates no idle
priority nodes. Handling a priority signal is O(1), exclusive or not.

A stream that depends on itself is a stream error of type PROTOCOL_ERROR (RFC 9113
section 5.3.1). When the signal arrives in a HEADERS frame, the engine still decodes
the rest of the header block, so the shared HPACK context stays in step. The stream
is reset after that. `set_priority` refuses a self dependency or a weight outside
1..256. `send_priority` writes the caller's dependency and exclusive bits to the
wire unchanged, as the caller's signal to the peer, and stores only the weight.

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
