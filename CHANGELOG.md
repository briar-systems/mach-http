# Changelog

## [Unreleased]

### Changed
- **Breaking.** `h3.connection.Transport[T]` has a new `ready` callback that returns a `TransportReady` for the next stream whose readable, writable or reset state changed, or `TRANSPORT_EMPTY`. The engine only reads and writes streams it has work for, so every adapter must report each such change. Duplicate and spurious reports are harmless, and dropped ones are not. `process` also returns the new `EVENT_PENDING` when progress was made but work remains, and the host must call it again rather than wait. `EVENT_NONE` now means the transport, the accept queue and the engine have nothing left. See doc/h3-connection.md (#103).
- **Breaking.** `h3.connection.Storage` has new `stream_index` and `stream_index_capacity` fields. The index holds `StreamIndexEntry` records, and its capacity must be a power of two and at least twice `stream_capacity` (#103).
- HTTP/3 `process` now costs O(streams with news) instead of three passes over the stream capacity. Stream lookup, allocation and release are O(1), and `tick` walks only the requests bound to an exchange. A host that cancels an exchange scope should call `cancel_stream`, with `tick` as the fallback. Queued streams are serviced round-robin, so events come out in readiness order rather than slot order (#103).

## [0.11.0] - 2026-09-17

### Added
- `h1.connection.next_deadline` returns the earliest deadline `tick` would enforce, so a host can arm one timer per connection instead of polling `tick` (#101).

### Changed
- Documented that every `now` and deadline the client, DNS cache, pool and HTTP/1 engine take is `std.chrono.time.monotonic()` time. A wall-clock value is accepted but yields deadlines that never fire (#99).
- Dependencies (tests only): the h3-quic tests use mach-quic v0.10.1, which brings mach-crypto v0.12.0 and mach-tls v0.5.1.

## [0.10.0] - 2026-09-17

### Changed
- **Breaking.** Dependencies: mach-std v4.0.1 (was v3.2.0), which requires mach 5.2 or later (#93). A consumer must be on std 4.x as well.
- **Breaking.** `transport` builds its own errors with `io.error.make` and an explicit kind, so their `code` is now 0 (#93). An adapter that breaks its contract (reports more bytes than it was given, or completes with a retryable error) is reported as `IO` instead of `OTHER`. Refused and closed work is still `INVALID`, `BUSY` or `CLOSED`, and a cancel reason is still `TIMEOUT`, `CANCELLED` or `CLOSED`.
- Dependencies (tests only): the h3-quic tests use mach-quic v0.10.0, which brings mach-crypto v0.11.0 and mach-tls v0.5.0 (#93).

## [0.9.0] - 2026-09-16

### Changed
- Dependencies: mach-std v3.2.0 (was v2.0.0). No source changes were needed (#89).
- Dependencies (tests only): the h3-quic tests use mach-quic v0.9.0, which brings mach-crypto v0.10.1 and mach-tls v0.4.1 (#89).

## [0.8.2] - 2026-09-15

### Fixed
- mach-quic, mach-tls and mach-crypto are no longer dependencies of mach-http. The h3-quic tests are back in their own `test/h3-quic` project, so a consumer of mach-http no longer has to realize them (#82). v0.8.1 should not be used.

## [0.8.1] - 2026-09-15

### Changed
- Dependencies (tests only): mach-quic v0.6.1, which brings mach-crypto v0.9.1 and mach-tls v0.3.1.
- The h3-quic tests are part of the root test set (#79).

## [0.8.0] - 2026-09-13

### Changed
- Migrated to mach 5.0 and mach-std 2.0.0.
- Cancel reasons are tested as tag cases, and deadline queries read the std 2.0 `DeadlineQuery`. The `router.Handler` result type stays `res[u8, str]` for now.
- Dependencies (test/h3-quic only): mach-quic v0.6.0.

## [0.7.6] - 2026-09-05

### Added

- GitHub Actions CI: every pull request builds the library, runs the suite in both profiles and the HTTP/3 reference against the real QUIC driver, checks the release version constant, and verifies IR across all six targets.
- The HTTP/3 transport qualification project drives the QUIC driver close
  contract. Its protocol core releases the stream manager and the datagram
  queue as its half of `finish_close`, which the driver requires and the core
  never did, and it records the close mode and application error the driver
  hands it. Every test now ends its connection through `begin_close` and
  `finish_close` on both drivers instead of abandoning them, and two tests
  assert the post-conditions directly: a graceful close ends the six critical
  streams the connection carries for its whole life, and an abortive close
  settles with a request still live on both ends. `close_endpoint`, which
  nothing called, is replaced by the driven close path.

### Removed

- `tools/check-version.sh`. The manifest-against-constant comparison it did now
  runs inline in CI, which is the only place it was ever run.

### Fixed

- A drained request body no longer fails the declared-length check. The
  adapter consumes the remainder without delivering it through `read`, so
  `transferred` was compared against the declared length and every drained
  body with a Content-Length or HTTP/2 or HTTP/3 declared length ended with
  `body ended at a different declared length`. The check still applies to a
  body whose bytes all passed through the reader.

### Changed

- Dependencies: mach-quic v0.5.8.

## [0.7.5] - 2026-09-02

### Fixed

- HTTP/3 DATA frames are no longer bounded by their declared length: the
  frame parser exempts them from `max_frame_payload` and the request stream no
  longer fails a frame longer than `max_chunk_bytes`, since the payload streams
  through reads the body reader bounds itself. The frame count policy and the
  cap on frames buffered whole are unchanged.

## [0.7.4] - 2026-09-02

### Fixed

- `h3.progress_close` treats a transport that reports CLOSED as having
  satisfied the close, so an engine cancelled by the peer's connection close
  reaches CLOSED instead of failing on every call and leaving its session
  pending forever.

## [0.7.3] - 2026-09-01

### Changed

- Pinned `mach-std` to `v0.34.0` so HTTP composes with the typed secret-storage
  dependency graph used by QUIC and Hedge.
- The HTTP/3 transport qualification project pins `mach-quic` `v0.5.1`, whose
  split connection storage and released `mach-crypto` `v0.8.1` and `mach-tls`
  `v0.2.2` graph form one coherent dependency stack.

## [0.7.2] - 2026-09-01

### Added

- `http.h1.connection.abandon` retires an exact nonterminal slot identity after
  connection failure or close while application body completions remain owned by
  the caller.

## [0.7.1] - 2026-08-31

### Added

- `http.h2.connection.abandon_exchange` detaches an exact closed stream
  generation during teardown while caller-owned body completions remain live.

### Fixed

- The manifest and exported library version now agree after the v0.7.1 release.

## [0.7.0] - 2026-08-31

### Changed

- **Breaking.** `http.h3.connection.Transport[T]` now carries a typed `*T`
  context, and every callback, `Engine[T]`, and engine operation carries the same
  type argument. Real QUIC adapters can retain secret-welded connection state
  without erasing it to `ptr`.

## [0.6.0] - 2026-08-28

### Added

- `destroy` on the HTTP/1, HTTP/2, and HTTP/3 connection engines. Each returns its engine to the state `init` accepts, so one set of caller-owned storage can carry a succession of connections, and each refuses while the transport, the application, or a live stream still references that storage.

### Fixed

- A connection engine was usable exactly once. `init` and the guards on the HPACK and QPACK tables, the frame parser and writer, the QPACK section sets, and the critical-stream record all refuse to run twice, so pooled storage could not be re-initialised and consumers cleared those flags from outside. Both dynamic tables now come back empty, because a surviving table would decode the next connection against entries its peer never inserted.
- `src/lib.mach` reported version `0.4.0` while the manifest had moved to `0.5.0`, so `tools/check-version.sh` failed on `main` and `dev`.

## [0.5.0] - 2026-08-28

### Changed

- **Breaking.** `http.h3.connection.Storage` requires a caller-owned pending-release array and `Config` requires its `max_pending_release` bound. Every caller of `http.h3.connection.init` must supply both.

### Fixed

- A rejected HTTP/3 request no longer fails the connection. `release` means the stream is settled on the wire, which a stream this side has just reset cannot be until the peer acknowledges it, so blocked releases are now retried from `process` instead of being treated as transport failures. Exhausting the pending-release bound is a defined excessive-load failure.
- A QPACK Stream Cancellation naming a stream with no outstanding section is a no-op rather than a decoder-stream connection error, matching RFC 9204, which defines that error only for Section Acknowledgment. A peer rejecting a request always cancels, whether or not the field section used the dynamic table.
- The in-file HTTP/3 transport fake models the real release precondition instead of accepting any live stream, so its results cannot disagree with the driver again.

## [0.4.0] - 2026-08-28

### Added

- Strict incremental HTTP/2 frame parsing and serialization with continuation sequencing and typed payload validation.
- Transactional HPACK decoding and encoding with the complete static table, dynamic table eviction, canonical integers, and RFC Huffman coding.
- Allocation-free HTTP/2 client and server connection engines with preface and settings negotiation, stream state, push, ping, reset, GOAWAY, and two-phase graceful drain.
- Completion-driven HTTP/2 reads and writes with partial I/O, copied outbound DATA, borrowed inbound events, generation-safe exchange binding, and retry handoff.
- Independent connection and stream flow control with consumption-driven window replenishment and bounded weighted DATA scheduling.
- HTTP/1 WebSocket upgrade and HTTP/2 or HTTP/3 extended CONNECT negotiation through the common service exchange.
- Allocation-free incremental WebSocket decoding and encoding with masking, fragmentation, streaming UTF-8, control frames, and close validation.
- Completion-driven WebSocket connections with exact borrowed-input release, copied-output ownership, partial I/O, backpressure, cancellation, timeout, and close outcomes.
- Incremental HTTP/3 frame, SETTINGS, control-stream, and unidirectional stream codecs with exact borrowed payload ownership.
- Complete QPACK static and dynamic tables, encoder and decoder instruction streams, all field-line representations, Huffman strings, blocked-section retry, and protected reference lifetimes.
- Bounded client protocol selection, DNS resolution, connection pooling, retry classification, cancellation scopes, and complete exchange lifecycle management.
- Allocation-free HTTP/3 client and server engines with critical streams, request multiplexing, common exchange binding, cancellation, GOAWAY, and two-stage graceful close.
- Split-delivery QUIC stream adapter contract with copied partial writes, explicit receive credit, generation-safe handles, and exact final-size validation.
- Qualification of the HTTP/3 engine against the real `mach-quic` connection driver over a loopback protocol, covering bodies in both directions, sustained multiplexing, QPACK-blocked credit retention, reset, cancellation, GOAWAY, datagram loss, and partial I/O.

### Security

- Bounded HPACK encoded input, Huffman expansion, strings, field count, decompressed field-list size, dynamic memory, entries, indices, and table updates independently.
- Rejected oversized, truncated, mis-scoped, self-dependent, invalidly padded, duplicate-setting, and zero-window HTTP/2 frames.
- Preserved HPACK state while refusing saturated streams and rejected invalid pseudo-fields, uppercase or connection-specific fields, hostile authorities, priority cycles, content-length mismatches, and DATA on bodyless responses.
- Enforced mask direction, reserved bits and opcodes, minimally encoded lengths, independent frame and message limits, fragment limits, valid close codes, and protocol-correct 1002, 1007, 1009, and 1006 outcomes.
- Rejected misplaced and reserved HTTP/3 frames, duplicate or reserved settings, duplicate critical streams, client push streams, malformed typed payloads, and truncated variable-length integers.
- Bounded QPACK table bytes, physical entries, wire instructions, encoded sections, blocked streams, outstanding sections, references, field count, decompressed field-list size, individual strings, and Huffman expansion independently.
- Required terminal request and response bodies before exchange completion, forbade reuse after upgrades and tunnels, and rejected overlapping ownership descriptors before dereference.
- Enforced independent HTTP/3 request, response, informational, trailer, target, body byte, DATA frame, and stream admission limits.
- Rejected duplicate or closed critical streams, invalid frame sequences, hostile final sizes, blocked-stream saturation, QPACK cancellation abuse, nonmonotonic GOAWAY, and stale transport outcomes.

## [0.3.0] - 2026-08-28

### Added

- Bounded compile-once routing with caller-owned route and segment storage.
- Exact, wildcard, port-specific, and host-independent authority matching.
- Literal, parameter, terminal catch-all, root, trailing-slash, asterisk-form, and authority-form routing.
- Deterministic host, path, and method precedence independent of registration order.
- Generation-bound captures, handler invocation, and caller-buffer percent decoding.
- Actionable conflict and capacity diagnostics with zero dispatch allocation.

### Security

- Rejected malformed encodings, encoded separators, backslashes, controls, dot segments, hostile authorities, duplicate Host fields, invalid methods, and invalid target forms before dispatch.

## [0.2.1] - 2026-08-28

### Fixed

- Synchronized the exported library version with the package release version.

### Added

- Added a release check that rejects manifest and exported version drift.

## [0.2.0] - 2026-08-28

### Added

- Version-neutral bounded request, response, informational, trailer, and streaming body exchange.
- Completion-driven plaintext and secured ordered-byte transport adapters.
- Strict incremental HTTP/1.0 and HTTP/1.1 request and response parsing.
- Bounded HTTP/1 serialization, framing, trailers, and close-delimited bodies.
- Bounded HTTP/1 client and server pipeline engines with backpressure and exact slot ownership.
- Upgrade and CONNECT tunnel handoff with exact unread-byte preservation.
- Absolute connection deadlines, cancellation, graceful drain, and close sequencing.

### Changed

- Pinned `mach-std` to `v0.29.0` for hierarchical cancellation and completion-based I/O.

## [0.1.0] - 2026-08-27

### Added

- Initial HTTP protocol, transport, routing, client, server, and WebSocket contracts.
