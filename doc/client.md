# HTTP client orchestration

`http.client.client` is a bounded single-owner request state machine. It composes the
shared message contract, asynchronous DNS cache, origin-isolated connection pool,
protocol policy, retries, redirects, cancellation, and graceful shutdown without
allocating or hiding transport work.

## Memory and lifetime

The caller provides fixed arrays for request slots and per-request resolved
endpoints. The DNS cache and connection pool have their own caller-provided arrays.
`client.init` rejects overlap among all nine objects and backing regions before it
writes any storage. Submission also rejects request views, body readers, body
provider contexts, and body cancellation scopes that overlap client-owned storage.
For every field collection, ownership covers the complete physical backing capacity,
not only the populated length. It also covers the trailer collection referenced by a
body reader or writer, including that collection's descriptor, complete backing
capacity, and populated name and value views. Response callbacks reject the response
object and all of these nested regions on the same basis before ownership changes.
The exact request child scope published with an exchange is the sole permitted
client-owned overlap for a request or response body scope.

Every public borrowed pointer, view, array count, and capacity is checked for
address-space representability before the first dereference. Zero-length ranges may
use a null pointer. Non-empty ranges must not be null or wrap the address space.
The supplied parent cancellation scope is range-checked and rejected if it overlaps
client-owned storage before the client queries its cancellation reason.

The client owns the cache and pool lifecycle after initialization. Both dependencies
must still accept work when `client.init` adopts them. Initialization rejects a
drained or already-draining cache or pool. Drain and destroy adopted dependencies
through the client, then destroy the empty dependencies. A `Request` and all of its
borrowed method, target, field, trailer, and body storage remain fixed until the
matching request token is released or a replay or redirect explicitly replaces that
generation, except for the one body-scope rebind performed when the initial request
is accepted. Routes are copied into the request slot and no longer borrow the
submission views.

The client is single-owner by design. DNS and pool internals synchronize their own
shared state, but calls that mutate one request token must be serialized by its event
loop. Stable generation tokens reject stale callbacks after slot reuse.

## Driving requests

Call `submit`, then call `next` until it publishes an external action or completion:

- `ACTION_RESOLVE` owns one cache query. Submit its resolver query and scope, then
  call `resolution_submitted` with the exact resolver token. If submission fails,
  call `resolution_submit_failed`. Resolver completions enter through
  `complete_resolution` and are matched by both context and token. Cancellation does
  not retire the request token while this publication is unacknowledged. The
  submission callback first transfers or abandons the shared cache query, then the
  request publishes its cancellation outcome.
- `ACTION_CONNECT` owns one pool reservation. The connector derives its TLS or QUIC
  ALPN offers with `policy.offers`. Report success through `connected`, or report a
  failed endpoint through `connect_failed`. `Connected.close_driver` tells the
  connector whether it still owns and must close a late driver. The pool accepts a
  driver pointer exactly once. A duplicate or aliased pointer is rejected, and a
  pointer already transferred to any live connection is never returned to the
  connector for closure.
- `ACTION_EXCHANGE` transfers one exact lease and request generation to the selected
  HTTP/1, HTTP/2, or HTTP/3 engine. Complete it with `exchange_complete` or
  `exchange_failed`, returning the exact published lease value. Stale lease,
  connection, driver, and wire evidence is rejected without consuming the live
  exchange. Protocol reasons such as refused-stream and GOAWAY are accepted only
  for HTTP/2 and HTTP/3. A host that drove the exchange through an HTTP/2 or
  HTTP/3 engine derives the failure from the engine's closure with
  `policy.failure_from_closure` instead of choosing a reason: a peer refusal
  (`REFUSED_STREAM`, `H3_REQUEST_REJECTED`) or an HTTP/3 GOAWAY rejection is
  definitely unprocessed, every other engine close is an ambiguous
  `RETRY_TRANSPORT`, and a closure the caller made is not a failure at all. A complete retryable HTTP response enters through
  `exchange_response_retry`, which either schedules replay or preserves that exact
  response as the final successful HTTP outcome when policy denies or exhausts the
  retry. Every callback that consumes the exchange requires the transferred request
  body and any response body to have reached terminal states. Its outcome and reuse
  evidence must exactly match the common `http.core.exchange.Exchange` combination
  of both body results. Cancellation, timeout, limit, and body error results therefore
  cannot be published as a successful client outcome. Either body forbidding reuse
  forbids connection reuse. HTTP 101 always forbids reuse. Successful HTTP/1 CONNECT
  also forbids reuse because the lease becomes the upgraded or tunneled transport.
- `ACTION_WAIT_DNS`, `ACTION_WAIT_POOL`, and `ACTION_WAIT_TIMER` retain no new caller
  buffer. Drive `next` again after the corresponding state changes or absolute time
  arrives.
- `ACTION_REPLAY` requires the caller to produce a fresh request generation. The
  client never rewinds, copies, or buffers a request body. `replay_ready` verifies the
  method, target, deadline, memory ownership, and new generation before retrying. An
  open replacement body must already use the request's existing client child scope.
- `ACTION_COMPLETE` remains stable until `release_request` destroys its cancellation
  child and returns the slot to the client.

The protocol policy selects cleartext prior knowledge, secure ALPN, or HTTP/1.1
fallback when explicitly allowed. TCP carries HTTP/1 and HTTP/2. QUIC carries HTTP/3.
An HTTP/3-only or HTTP/3 prior-knowledge policy selects QUIC directly. A mixed policy
starts on TCP until the caller applies an HTTP/3 discovery policy such as a cached
alternative service.

The route origin is the canonical outbound authority. Origin and asterisk targets
carry it out of band. CONNECT always uses authority-form with an explicit matching
port. Other forward-proxy requests use matching absolute-form targets. If a caller
supplies a Host field, it must also match and may occur only once. Version adapters
generate their wire authority from the route when Host is absent. Target component
views must describe the exact raw target rather than an unrelated borrowed string.
Bracketed authorities contain only validated IPv6 literals. Embedded NUL bytes are
invalid in raw URLs and are rejected before any component view is published.

## DNS, pools, and proxies

DNS keys include host, port, and transport. Results are copied in resolver order,
deduplicated, and kept under independent fresh, stale, negative, and resolver
deadline limits. One refresh is shared by concurrent lookups. Temporary failures
retain stale data when available. Without stale data, client retries wait until the
cache's exact retry time instead of spinning through the request budget.

Pool keys include the origin and complete proxy metadata. A proxy identity separates
credentials and policy even when its address is the same. HTTP forwarding, HTTP
tunneling, SOCKS5, and CONNECT-UDP declare TCP and datagram capabilities explicitly.
HTTP/1 leases are exclusive. HTTP/2 and HTTP/3 leases share a connection up to the
reported peer and configured stream limits. `pool.update_max_streams` applies a
generation-bound peer SETTINGS or transport-credit change. Reducing the limit below
current use preserves existing leases and blocks only new acquisition. A live peer
limit of zero is represented exactly and blocks every new lease until peer credit
increases again.

Total connections, connections per route, leases, idle connections, idle connections
per route, idle lifetime, and streams per connection are independently bounded. Idle
and drained drivers are published exactly once as maintenance close actions. The
caller closes the driver, then calls `pool.retire` with that exact close token.
Drive `client.maintenance` during normal operation as well as shutdown. Routine calls
publish expired, non-reusable, drained, and over-budget drivers. DNS and connector
cancellation actions remain gated to dependency drain.

## Retry and redirect safety

Retry permission is application data. `Replay.explicit` must be true and the body
must be empty or externally rewindable. Streaming bodies are never retried. Transport
and protocol retries additionally require exact proof that the request was not
processed. A valid transport or protocol failure without that proof is terminalized
with forbidden connection reuse and is never replayed. Contradictory response or
processing flags remain invalid. Response retries require a complete response and an
enabled status class. The response status must match the supplied response retry
reason. A detached or contradictory reason is rejected without consuming the
exchange. Retry-After delays and DNS negative-cache delays are absolute wait actions.

Redirect evaluation distinguishes method rewriting, body removal, downgrade policy,
origin credentials, and proxy credentials. `follow_redirect` accepts only a fresh,
fully validated request generation. Cross-origin replacements must omit sensitive
fields and trailers, Authorization, and Cookie. Cross-proxy replacements must omit
Proxy-Authorization from fields and trailers. A redirect that removes a body changes
the stored replay classification to empty. Other replacements must preserve the
declared replay class. A maximum of zero disables redirects and yields the normal
redirect-limit result. A followed route must also remain usable by the original
protocol policy, including after an allowed HTTPS-to-HTTP downgrade. Release failure
is transactional and retains the exact live exchange. Once release succeeds,
cancellation wins over both following and publishing a redirect error.

## Cancellation and shutdown

Every `now` the client, DNS cache and pool take, and every request deadline, is a
`std.chrono.time.Instant` read with `time.instant()`, the clock std enforces
cancellation-scope and `io.runtime` deadlines against. The DNS cache turns `now`
plus the resolve timeout into the deadline of the scope it hands out with each
resolver query. Each request's child scope takes `request.metadata.deadline`, an
`opt[Instant]` that is `none` for a request without its own deadline, and
`expire_request` expires it at the given `now`. `request.metadata.received_at`
stays a wall-clock `time.Time`: it is a timestamp for records and logs, and nothing
orders or ages requests by it.

Every request owns a child of the supplied cancellation scope. An open request body
must initially reference that supplied parent. After the child is created, the client
rebinds the body to it so the selected engine can initialize the common
`http.core.exchange.Exchange` without mutating otherwise fixed request storage. A
replay or redirect replacement must already reference the current child. The
effective deadline must exactly match the request metadata. Call `cancel_request` or
`expire_request`, or drive the same child scope directly. Cancellation wins a late
connect or exchange callback. A late untransferred connect driver returns to the
connector for closure. A driver already owned by another connection does not. Late
exchange responses release their connection but do not replace the cancelled
outcome.

`drain` stops admission while existing tokens finish. After every completion is
released, `drain_dependencies` stops DNS and pool admission. Repeatedly consume
`maintenance` actions to cancel resolver work, cancel pending connects, and close
drivers. `destroy` succeeds only after both dependencies report no live work.
