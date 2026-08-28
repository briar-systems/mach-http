# WebSocket

The WebSocket implementation is split into negotiation and framing. Both layers are
bounded and allocation-free.

## Negotiation

`http.websocket.negotiation.server` accepts a common `http.core.exchange.Exchange`.
For HTTP/1.1 it validates GET, `Connection: Upgrade`, `Upgrade: websocket`, version
13, a unique canonical key, and an offered subprotocol before committing status 101.
For HTTP/2 and HTTP/3 it validates CONNECT, the external `websocket` protocol value,
version 13, and the absence of connection-specific HTTP/1 fields before committing
status 200. The response therefore follows the same cancellation, commit, and
completion lifecycle as every other service exchange.

The caller owns the 29-byte HTTP/1 accept scratch until its response fields are no
longer needed. A selected subprotocol must be one of the request tokens and matching
is case-sensitive. `validate_h1_response` performs the client-side accept and
subprotocol checks. `client_key` needs 25 output bytes and takes exactly 16 random
bytes supplied by the caller.

## Framing

`Decoder` accepts arbitrarily fragmented input, including one byte at a time. It
validates reserved bits, known opcodes, role-specific masking, minimal 7, 16, and
64-bit lengths, control-frame constraints, continuation order, independent frame and
message limits, fragment counts, streaming UTF-8, close codes, and close reasons.
Ping and pong may interleave a fragmented data message.

Data event bytes borrow the supplied input and are unmasked in place. The next feed
is rejected until `release` is called. Ping, pong, and close bytes borrow the
caller-provided 125-byte control scratch under the same rule. Protocol failures
report the close code the application should send when the connection still permits
a reply:

- 1002 for malformed framing or close codes
- 1007 for invalid or incomplete UTF-8
- 1009 for a frame, message, or fragment limit
- 1006 as a local-only outcome for truncated or abnormal transport EOF

Code 1006 is never placed on the wire.

`Encoder` writes a complete frame header to caller storage, then copies payload into
caller output slices. It never retains an application payload pointer across a call.
Client encoders require a mask key. The caller must provide a fresh unpredictable
four-byte key for every frame. Partial payload calls maintain the exact mask offset
and streaming UTF-8 state.

## Completion-driven connection

`Connection` combines the codecs with `http.core.transport.Transport`:

1. `submit_read` transfers the read buffer to the transport until one terminal
   completion.
2. `complete_io` returns a data or control event. The input remains borrowed until
   `release_event`.
3. `begin_frame` and `offer` copy a frame into the connection write buffer.
4. `submit_write` transfers only that buffer. Partial completion advances its exact
   offset and the remaining bytes may be submitted again.
5. After the close handshake, `submit_close` starts physical transport close and its
   completion produces `EVENT_CLOSED`.

`adopt_input` transfers unread bytes from an HTTP/1 upgrade or extended CONNECT
tunnel without copying. The prior protocol engine must retain that buffer until
`borrowed_input_released` becomes true. A borrowed event prevents another read, so a
slow application naturally applies transport backpressure.
