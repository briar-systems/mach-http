# Changelog

## [Unreleased]

### Changed
- `http.core.section` holds the field-section validator that the HTTP/2 and HTTP/3 engines used to carry as separate copies, with its own tests for both directions. `h2.connection.HeaderBlock` and `h3.connection.HeaderBlock` are the same type as `section.Block` (#119).
- The HTTP/2 connection doc no longer says to call `tick` until it returns `EVENT_NONE`, which a failed engine never does. It returns its failure event on every call.

## [0.13.1] - 2026-09-17

### Fixed
- HTTP/2 and HTTP/3 `send_headers` and `send_push_promise` accept caller field names in any case, as HTTP field names are case-insensitive (RFC 9110). `Content-Type` used to be refused with `OFFER_ERROR`, so a version-neutral caller worked over HTTP/1 and failed over HTTP/2 and HTTP/3 (#112).
  - The HPACK and QPACK encoders write every literal name lowercase, raw or Huffman, and never modify the caller's view.
  - The encoders match static and dynamic table names in any case, so `Content-Type` still indexes.
  - An inserted name is stored lowercase in the encoder's table.
  - Outbound validation compares pseudo-field names and the connection-specific, `te`, `host` and `content-length` names without case.
  - Received names stay strict, and an uppercase name is still a malformed message.
- `h2.hpack` gains `huffman_encode_lower` and `huffman_encoded_size_lower`, and `core.field` gains `lower` (#112).

## [0.13.0] - 2026-09-17

### Added
- HTTP/2 connection and stream timeouts (#110). `h2.connection.Config` gains `header_timeout_ns`, `request_timeout_ns`, `idle_timeout_ns`, `write_timeout_ns` and `total_timeout_ns`, with the HTTP/1 defaults. `next_deadline` reports the earliest deadline in O(1), and `tick(engine, now)` enforces them:
  - A server that has no request within the header timeout of `init` fails with `ERROR_HEADER_TIMEOUT`. This covers a peer that is silent after the handshake, or sends only the preface and SETTINGS. Pings never extend it.
  - A connection with no live stream fails at the idle timeout with `ERROR_IDLE_TIMEOUT`. For a client it runs from `init`, and for both roles from `release_stream` of the last stream.
  - A header block that does not end within the header timeout of its first frame fails with `ERROR_HEADER_TIMEOUT`. This covers a truncated HEADERS frame and one without END_HEADERS.
  - A transport write, or a connection send window that stays closed, fails at the write timeout with `ERROR_WRITE_TIMEOUT`. The connection closes at once, with no GOAWAY.
  - Every connection fails at the total timeout with `ERROR_TOTAL_TIMEOUT`.
  - A stream whose peer has not finished its half within the request timeout, or whose send window stays closed past the write timeout, is reset alone with RST_STREAM(CANCEL). Its exchange is timed out, and `EVENT_STREAM_RESET` carries the timeout in `error`.
  - A connection timeout returns the new `EVENT_TIMED_OUT`, queues GOAWAY(NO_ERROR) except after a write timeout, and times out the connection scope when the close is submitted. The close reports `lifecycle.DEADLINE`. The GOAWAY drain is bounded by the write deadline, which `tick` still enforces after the failure.
- `http.core.deadline` holds the absolute `Deadline` type and its helpers. `h1.connection.Deadline` is the same type.

### Changed
- **Breaking.** `h2.connection` `init`, `process`, `complete_io`, `tick`, `submit_write`, `set_writable`, `offer_data` and `release_stream` take a `time.Instant`. An invalid instant is refused, and an earlier one counts as the latest seen. `process` on a failed engine returns the same event `tick` does, `EVENT_TIMED_OUT` or `EVENT_CANCELLED` where they apply, and no longer always `EVENT_ERROR` (#110).
- **Behaviour change.** An HTTP/1 server connection with no live slot now closes at `header_timeout_ns` with `ERROR_HEADER_TIMEOUT` (`EVENT_TIMED_OUT`), where it used to wait for `idle_timeout_ns` (#110). This covers two states:
  - A client that completes the handshake, for example TLS, and then sends nothing.
  - A memory-blocked connection, whose read buffer or slot set was refused while its request waits unread. `memory_blocked` stays set when the deadline fires, so a host can count memory timeouts separately.

  The wait starts at `init`, or when a quiet keep-alive connection becomes readable. Memory refusals never restart it, and a started slot takes it over. An idle keep-alive connection with nothing to read is still bounded by `idle_timeout_ns`.

### Fixed
- A failed HTTP/2 or HTTP/3 connection can always be destroyed. Before, `destroy` refused forever in three cases, and a failed h2 engine kept its stream records and buffers on the account (#110):
  - streams the host never saw, such as one still decoding a header block
  - releases the peer never acknowledged
  - a header event held without an exchange

  Now, once the close completes:
  - live streams and owed releases no longer block `destroy`, and h2 releases their memory
  - a closed stream's header event can be released without an exchange
  - held HTTP/3 data can be consumed without granting the transport more credit
- A failed HTTP/2 connection no longer waits forever for output it can never write. A server that fails before the client preface, and a connection whose scope was cancelled, used to keep a queued frame that `progress_close` waited on. That output is now dropped at the failure (#110).

## [0.12.0] - 2026-09-17

### Added
- `http.core.records` holds address-stable record chunks borrowed from a `std.memory.buffers.Source`. Each chunk doubles the capacity, and a record never moves once handed out (#104).
- `transport.readable` waits for readability without lending a buffer. Its completion has kind `READABLE` and count 0 (#104).

### Changed
- The license is attributed to Briar Systems LLC (#108).
- **Breaking.** Dependencies: mach-std v5.3.0 (was v4.0.1), and `mach.toml` now requires mach `^5.3`. A consumer must be on std 5.x as well. Error completions from std 5.3 carry the bytes transferred before a cancellation or timeout. Every engine treats such a completion as fatal to its connection, never as an empty success (#104).
- **Breaking, and stops compilation.** Every transport adapter must implement the new `submit_readable`: `transport.Adapter` and `transport.RuntimeStream` have the callback. It maps to a runtime readiness wait such as `net.async.submit_readable`. A read and a readable wait are never pending together (#104).
- Dependencies (tests only): the h3-quic tests use mach-quic v0.12.1, and their adapter reports readiness through `transport.ready_stream` (#104).
- **Breaking.** Every caller-supplied `now` and every deadline is a `std.chrono.time.Instant`, read with `time.instant()`, instead of a `time.Time`. This covers:
  - `h1.connection`: `init`, `tick`, `process`, `complete_io`, `enqueue_request`, `prepare_informational`, `prepare_response`, `release`, `Deadline.at` and `next_deadline`.
  - The client: `next`, maintenance, `expire_request`, retry and readiness instants, and their timer actions.
  - The DNS cache: lookups, TTL and retry instants, and resolver scope deadlines.
  - The connection pool: `take_close`, idle deadlines and last-use ordering.

  A wall-clock value no longer compiles where a deadline is expected. This replaces the 0.11.0 note that such a value was accepted but never fired.
- **Breaking.** `message.Metadata` replaces `has_deadline` and `deadline` with one `deadline: opt[time.Instant]`. `received_at` stays a wall-clock `time.Time`, since it is a timestamp for records and nothing orders requests by it.
- **Breaking.** The engines borrow their memory from a `std.memory.buffers` account, and an idle connection holds only per-connection state (#104). Each `init` takes the source and the connection's open account, and both must outlive the engine. `destroy` returns everything to the account. A refusal never fails the connection. It refuses the step or the stream that needed the memory, and an exhausted or memory refusal registers the account for one wake-up. Sizes below are at each `config_default`, measured on x86_64.
  - HTTP/1: `init` no longer takes slot memory or read and write buffers. `Config` gains `read_bytes`, `write_bytes`, `slot_storage_bytes`, `slot_scratch_bytes`, `slot_lane` and `connection_lane`. An idle engine holds no buffer: it waits with `transport.readable`, and the 8,192-byte read buffer is held from readability until its input is consumed. A slot borrows its 70,816-byte set while it is live, and the 8,192-byte write buffer is held while output is staged. A refused slot leaves the request unread and returns `EVENT_MEMORY_BLOCKED`. A refused client slot fails `enqueue_request`, and a refused write buffer returns `OFFER_BLOCKED` with `ERROR_MEMORY`.
  - HTTP/2: `init` takes the source, the account, the read buffer and the connection tables, plus one caller `StreamMemory` that decodes a refused header block. The stream array, per-stream memory, the index, and the write, frame-payload, header-output and encoder-pending buffers are no longer parameters. `Config` gains `write_bytes`, `frame_payload_bytes`, `initial_streams`, `stream_lane` and `connection_lane`. An idle engine holds 2,880 bytes: its first four 656-byte stream records and their index. Records grow in place up to `max_streams`. A stream that decodes headers borrows a 139,872-byte set until `release_stream`. Transient buffers are held only while in use. A refused stream set is refused with `REFUSED_STREAM`, and the block is still decoded so HPACK stays in step. A refused local stream fails `open_local`. A refused transient buffer returns `EVENT_MEMORY_BLOCKED` or `OFFER_BLOCKED` with `ERROR_MEMORY`.
  - HTTP/3: `Storage` loses `streams`, `memories`, `stream_capacity`, `stream_index` and `stream_index_capacity`. It gains `source`, `account`, and a `CriticalMemory` that the peer's control, QPACK encoder and QPACK decoder streams read through. Each of those uses only the buffers its kind needs. `Config` gains `read_bytes`, `output_bytes`, `initial_streams`, `stream_lane` and `connection_lane`. An idle engine holds 12,544 bytes: its first eight 1,536-byte stream records and their index. A request stream borrows a 217,808-byte set until `release_stream`, or until `destroy` if it was never released. An unclassified peer stream reads its type one byte at a time into its own record, and an ignored one is drained through a 64-byte buffer inside the engine.
  - HTTP/3 refusals: a refused request set rejects the request with `H3_REQUEST_REJECTED`. A refused client request fails `open_request` before any transport stream is opened. A refused record for a peer unidirectional stream, which may be critical, parks that stream unread in the transport. `process` then returns the new `EVENT_MEMORY_BLOCKED` until the account wakes or a stream is released. A live request holds its set until it is released, so `open_request` and request admission also stop at `max_requests` held sets.
- **Breaking.** `h3.connection.Transport[T]` has a new `ready` callback that returns a `TransportReady` for the next stream whose readable, writable or reset state changed, or `TRANSPORT_EMPTY`. The engine only reads and writes streams it has work for, so every adapter must report each such change. Duplicate and spurious reports are harmless, and dropped ones are not. `process` also returns the new `EVENT_PENDING` when progress was made but work remains, and the host must call it again rather than wait. `EVENT_NONE` now means the transport, the accept queue and the engine have nothing left. See doc/h3-connection.md (#103).
- HTTP/3 `process` now costs O(streams with news) instead of three passes over the stream capacity. Stream lookup, allocation and release are O(1), and `tick` walks only the requests bound to an exchange. A host that cancels an exchange scope should call `cancel_stream`, with `tick` as the fallback. Queued streams are serviced round-robin, so events come out in readiness order rather than slot order (#103).
- **Breaking.** `h2.connection.process` (and `complete_io` for reads) can return the new `EVENT_PENDING`. It means the call used up its per-call budget of 64 units and work remains, so the host should call `process` again. It takes precedence over `EVENT_NEED_READ` (#103).
- **Breaking.** `h2.connection.Stream` no longer has `dependency` or `exclusive`, and PRIORITY dependencies are ignored (RFC 9113). Only the weight is kept. `refused_pending` is replaced by `pending_reset`, which holds the code of a reset deferred until a header block is decoded (#103).
- **Breaking.** A self-dependent PRIORITY frame or HEADERS priority block is now a stream error of type PROTOCOL_ERROR, as RFC 9113 requires. It was a connection error. `h2.frame` parses such a frame and leaves the error to the engine. The writer still refuses to encode one (#103).
- Performance: HTTP/2 routine paths no longer scan the stream table, so their cost is O(changed streams) (#103).
  - Stream lookup, allocation and release are O(1).
  - GOAWAY retries, owed WINDOW_UPDATEs, writable streams and exchange-bound streams each have their own set.
  - `tick` costs O(open exchange-bound streams). A host that cancels an exchange scope should call `cancel_stream`.
  - Weighted scheduling keeps the same order over the writable set only.
  - A PRIORITY signal costs O(1), exclusive or not.

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
