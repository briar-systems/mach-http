# HTTP/3 over the real QUIC driver

This subproject qualifies `http.h3.connection` against the `mach-quic` connection
driver. It is not part of the `http` library: mach-http depends only on `mach-std`,
and the QUIC dependency lives here so no consumer of the library has to build it.

## Shape

- `src/adapter.mach` binds `http.h3.connection.Transport` to `quic.transport`.
  Handles carry across unchanged; statuses are mapped explicitly.
- `src/loopback.mach` implements the driver's pluggable `Protocol`. It pulls the
  driver's prepared stream and flow-control work, frames it with RFC 9000
  variable-length integers, and moves datagrams between two real drivers. The
  harness can drop a datagram (the sender retransmits) or park one stream's
  datagrams for later delivery (the peer reorders).
- `src/session.mach` holds one HTTP/3 engine plus its adapter, and the two-endpoint
  fabric that drives both engines and the link.
- `src/tests.mach` drives a small application over the pair.

`mach-quic`'s own `src/transport/simulated.mach` is the model for the protocol core.
Its toy encoding uses single bytes for stream id, offset, and fin, which cannot
carry HTTP/3.

## What the tests drive

Settings and critical streams, request and response bodies in both directions,
sustained multiplexing across more requests than the initial stream and connection
windows allow, QPACK-blocked field sections holding QUIC credit while unrelated
requests complete, stream reset and application cancellation settling exactly once,
GOAWAY with two-stage graceful close, datagram loss with retransmission, and
partial writes with short reads under a small flow-control window.

## What it does not cover

There is no QUIC handshake: the drivers are driven through the `Protocol` seam, so
no TLS, packet protection, or transport-parameter negotiation is exercised. There
is no real UDP socket and no interoperability with another QUIC implementation.
Congestion control, path validation, and recovery timers are not involved. HTTP
Datagrams are not negotiated, and the datagram queue is deliberately empty.
