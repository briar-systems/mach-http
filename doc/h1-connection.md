# HTTP/1 connection engine

`http.h1.connection.Engine` is an HTTP/1 client and server state machine. It
composes strict incremental parsing and serialization with the common ordered
transport. It never allocates. Every buffer it uses is borrowed from a
`std.memory.buffers` account.

## Memory

`init` takes the pipeline slot records, a `std.memory.buffers.Source`, and the
connection's open account on that source. The source and the account must outlive
the engine. An initialized engine holds no buffer. `Config` sizes what it borrows:

| Buffer | Size | Held |
| --- | --- | --- |
| read buffer | `read_bytes` | from readability until its input is consumed |
| write buffer | `write_bytes` | while output is staged or in flight |
| slot set | line, `slot_storage_bytes`, header and trailer fields, `slot_scratch_bytes` | while the slot is live |

Slot sets are charged to `slot_lane` and the read and write buffers to
`connection_lane`. A slot set is taken all or nothing.

An idle connection waits with `transport.readable`, which lends the transport no
buffer. The read buffer is taken only when that wait completes, and `submit_read`
then reads into it. Once every byte has been consumed, the next `submit_read` gives
the buffer back and waits for readability again.

A refusal never fails the connection:

- A refused read buffer or server slot set returns `EVENT_MEMORY_BLOCKED`. The input
  stays unread, `submit_read` refuses, and `process` retries the same step.
- A refused client slot set makes `enqueue_request` return `NO_SLOT`.
- A refused write buffer makes `offer` return `OFFER_BLOCKED` with `ERROR_MEMORY`.

A refusal because the pool was exhausted, or because its backing refused, registers
the account for one wake-up. After the source reports the account ready, call
`process`. A refusal against the account's own lane budget is not registered. It ends
when this connection releases memory, for example through `release`.

`destroy` returns every buffer to the account.

## Time

Every `now` the engine takes is a `std.chrono.time.Instant`, read with
`time.instant()`. The header, request, write, idle and total deadlines are
`Instant`s computed from it, and an expired one times out the engine's cancellation
scope. The type is distinct from the wall-clock `time.Time`, so a calendar reading
cannot be passed where a deadline is expected.

`next_deadline` returns the earliest deadline `tick` would enforce, with `active` false
when none applies: an uninitialized engine, or a tunnel, closing, closed or failed
one. The idle deadline counts only while no slot is live, as in `tick`. A host with a
timer wheel arms one timer at that instant, calls `tick` when it fires, and queries
again after every call that takes `now` or changes a slot. The engine scope's own
std deadline is the host's and is not included. The HTTP/2 and HTTP/3 engines keep no
timers. Their `tick` only settles cancelled scopes, so call it after cancelling one.

## Slots and identity

The pipeline slot records are caller-owned. Their parser, field, trailer, and
serializer storage is the slot set borrowed while the slot is live. An admitted message receives a nonzero sequence. The pair
`(Event.slot, Event.sequence)` is its identity for that connection. A physical slot
may be reused after release, so a saved slot index alone is never an ownership
token.

Server slots are allocated in wire order. Parsed message views remain stable until
their slot is released or abandoned. A body event borrows the current input until
`consume_body`, a disposition change, or teardown abandonment.

## Normal release

`release` is the normal completion path. It succeeds only after both inbound and
outbound HTTP/1 work are terminal. Released slots are reclaimed from the pipeline
head so later responses cannot overtake earlier responses.

The HTTP/1 engine does not bind `http.core.exchange.Exchange` into a slot. The
owner maps an event identity to its application exchange and retains ownership of
that exchange and its body operations.

## Teardown abandonment

After connection failure or physical close begins teardown, an application exchange
may still have a pending body cancellation even though no more HTTP/1 progress is
possible. `abandon(engine, slot, sequence)` retires that exact protocol slot without
waiting for normal inbound or outbound completion.

Abandonment has these preconditions and effects:

- the connection state must be `FAILED` or `CLOSED`
- the slot must still be live and its sequence must match exactly
- the same slot identity can be abandoned only once
- any borrowed HTTP/1 input for that slot ends at the call
- stale sequences cannot retire a physically reused slot
- application exchange and body state are not accessed

The caller continues to own every pending application body token and its stable
buffer. It must deliver the matching body completion and settle the exchange before
reusing that application storage.

Transport ownership is independent. A pending read, write, shutdown, or abortive
close completion must still be passed to `complete_io`. `destroy` continues to
refuse while any transport operation is pending or any protocol slot has not been
released or abandoned. This ordering lets the owner retire dead protocol state
without losing either application body ownership or transport completion ownership.

## Close ordering

Graceful shutdown uses `begin_graceful` and `progress_close` after admitted messages
finish. Failure shutdown uses `cancel_connection`, drains exact transport
completions, abandons any nonterminal slot identities, then calls `destroy` only
after all independent owners have settled.
