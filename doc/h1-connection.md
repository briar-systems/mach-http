# HTTP/1 connection engine

`http.h1.connection.Engine` is an allocation-free HTTP/1 client and server state
machine. It composes strict incremental parsing and serialization with the common
ordered transport.

## Time

Every `now` the engine takes is `std.chrono.time.monotonic()` time. The header,
request, write, idle and total deadlines are absolute instants computed from it, and
an expired one times out the engine's cancellation scope. Pass the same clock on
every call. A wall-clock value (`time.now()`) moves with clock adjustments.

## Slots and identity

Every pipeline slot and all parser, field, trailer, and serializer storage are
caller-owned. An admitted message receives a nonzero sequence. The pair
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
