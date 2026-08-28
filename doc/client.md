# HTTP client orchestration

`http.client.client` is a bounded single-owner request state machine. It composes the
shared message contract, asynchronous DNS cache, origin-isolated connection pool,
protocol policy, retries, redirects, cancellation, and graceful shutdown without
allocating or hiding transport work.

## Memory and lifetime

The caller provides fixed arrays for request slots and per-request resolved
endpoints. The DNS cache and connection pool have their own caller-provided arrays.
`client.init` rejects overlap among all nine objects and backing regions before it
writes any storage.

The client owns the cache and pool lifecycle after initialization. Drain and destroy
them through the client, then destroy the empty dependencies. A `Request` and all of
its borrowed method, target, field, trailer, and body storage remain fixed until the
matching request token is released or a replay or redirect explicitly replaces that
generation. Routes are copied into the request slot and no longer borrow the
submission views.

The client is single-owner by design. DNS and pool internals synchronize their own
shared state, but calls that mutate one request token must be serialized by its event
loop. Stable generation tokens reject stale callbacks after slot reuse.

## Driving requests

Call `submit`, then call `next` until it publishes an external action or completion:

- `ACTION_RESOLVE` owns one cache query. Submit its resolver query and scope, then
  call `resolution_submitted` with the exact resolver token. If submission fails,
  call `resolution_submit_failed`. Resolver completions enter through
  `complete_resolution` and are matched by both context and token.
- `ACTION_CONNECT` owns one pool reservation. The connector derives its TLS or QUIC
  ALPN offers with `policy.offers`. Report success through `connected`, or report a
  failed endpoint through `connect_failed`. `Connected.close_driver` tells the
  connector whether it still owns and must close a late driver.
- `ACTION_EXCHANGE` transfers one exact lease and request generation to the selected
  HTTP/1, HTTP/2, or HTTP/3 engine. Complete it with `exchange_complete` or
  `exchange_failed`. The completion supplies the body reuse decision that controls
  pool retention.
- `ACTION_WAIT_DNS`, `ACTION_WAIT_POOL`, and `ACTION_WAIT_TIMER` retain no new caller
  buffer. Drive `next` again after the corresponding state changes or absolute time
  arrives.
- `ACTION_REPLAY` requires the caller to produce a fresh request generation. The
  client never rewinds, copies, or buffers a request body. `replay_ready` verifies the
  method, target, deadline, memory ownership, and new generation before retrying.
- `ACTION_COMPLETE` remains stable until `release_request` destroys its cancellation
  child and returns the slot to the client.

The protocol policy selects cleartext prior knowledge, secure ALPN, or HTTP/1.1
fallback when explicitly allowed. TCP carries HTTP/1 and HTTP/2. QUIC carries HTTP/3.
An HTTP/3-only or HTTP/3 prior-knowledge policy selects QUIC directly. A mixed policy
starts on TCP until the caller applies an HTTP/3 discovery policy such as a cached
alternative service.

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
reported peer and configured stream limits.

Total connections, connections per route, leases, idle connections, idle connections
per route, idle lifetime, and streams per connection are independently bounded. Idle
and drained drivers are published exactly once as maintenance close actions. The
caller closes the driver, then calls `pool.retire` with that exact close token.

## Retry and redirect safety

Retry permission is application data. `Replay.explicit` must be true and the body
must be empty or externally rewindable. Streaming bodies are never retried. Transport
retries additionally require proof that the request was not processed. Response
retries require a complete response and an enabled status class. Retry-After delays
and DNS negative-cache delays are absolute wait actions.

Redirect evaluation distinguishes method rewriting, body removal, downgrade policy,
origin credentials, and proxy credentials. `follow_redirect` accepts only a fresh,
fully validated request generation. Cross-origin replacements must omit sensitive
fields, Authorization, and Cookie. Cross-proxy replacements must omit
Proxy-Authorization. A maximum of zero disables redirects and yields the normal
redirect-limit result.

## Cancellation and shutdown

Every request owns a child of the supplied cancellation scope. The effective
deadline must exactly match the request metadata. Call `cancel_request` or
`expire_request`, or drive the same child scope directly. Cancellation wins a late
connect or exchange callback. Late connect drivers return to the connector for
closure. Late exchange responses release their connection but do not replace the
cancelled outcome.

`drain` stops admission while existing tokens finish. After every completion is
released, `drain_dependencies` stops DNS and pool admission. Repeatedly consume
`maintenance` actions to cancel resolver work, cancel pending connects, and close
drivers. `destroy` succeeds only after both dependencies report no live work.
