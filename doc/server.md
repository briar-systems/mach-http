# HTTP/1.1 server runner

`http.server.server` serves one handler over the service exchange. It listens on one
address, accepts connections up to a cap, drives `http.h1.connection` over each
socket through std's completion runtime, and hands every request to the handler as
one `http.core.exchange.Exchange`. It plays the role hyper's server plays under axum:
a framework supplies the handler and drives its own lifecycle through the hooks,
and the server knows nothing of routing or application structure.

It is plaintext HTTP/1.1 with keep-alive and pipelining, meant to run behind a
reverse proxy that terminates TLS. TLS, HTTP/2 and HTTP/3 are hedge's job.

## Running

```mach
var server: server.Server;
if (!server.make(?server, server.config_default(address), handler, hooks, ?allocator)) { ... }
val report: server.Report = server.serve(?server);
server.destroy(?server);
```

`make` allocates every record the server will use from the allocator: one
connection record per `max_connections`, its pipeline slots and its response field
storage. Serving allocates nothing else beyond the buffers `memory_bytes` bounds.
`serve` runs on the calling thread until the server has drained and stopped, and
returns the report the stop hook also saw. `shutdown` begins the drain from any
thread, a handler or a hook. `serve` ignores SIGPIPE for the process, so a peer
that resets mid-write fails that write and nothing else.

`destroy` refuses while `serve` runs, or while a connection whose teardown never
settled still holds its record (`Report.unsettled`), and leaves everything in place
when it does.

## Handler

```mach
pub def ServeFun:   fun(ptr, *Call) exchange.ServiceStatus;
pub def AbandonFun: fun(ptr, *Call);
pub def SettleFun:  fun(ptr, *Call);
```

`serve` is entered once per exchange. The `Call` carries the exchange in HANDLING
state, `request_memory_bytes` of zeroed scratch that lives exactly as long as the
exchange, and a `Waker` for it.

- `SERVICE_COMPLETE` means the response is committed (`exchange.commit`). A response
  body is a `body.Reader`, which the server pulls into the connection's write buffer
  as the socket drains. A `body.Writer` response is refused.
- `SERVICE_PENDING` means the handler is waiting on something of its own. `serve` is
  entered again after each wake of the exchange and after request body progress,
  until it returns something else. A handler that sets `call.wake_at` to a monotonic
  instant before returning is also entered again at that instant, if nothing woke
  it first, so a framework enforces its own per-request deadline without a timer of
  its own. `wake_at` is cleared before every entry.
- `SERVICE_FAILED`, or a completion with no committed response, is answered 500 if
  no response has started, and closes the connection otherwise.

Every final response the server writes carries a `Date` in IMF-fixdate form, as an
origin server with a clock must send it (RFC 9110 section 6.6.1). The date is
formatted once per second. A `Date` the handler set is sent as it is.

A body operation that returned PENDING, the handler's response reader or its own
request body read, is completed with `body.complete_reader` only after the exchange
is woken or its request body moves. A completion may be attempted on a turn the body
did not ask for, and a body that is not ready answers PENDING again.

`abandon` is called exactly once for an exchange that goes away while `serve` last
returned `SERVICE_PENDING`: a connection failure, a timeout, or the drain deadline.
The exchange is then cancelled through `exchange.close_exchange`, which finishes its
bodies with `body.CANCEL`. A body whose cancellation is itself pending keeps the
exchange, its scratch and its connection until it completes after a wake.

`settle` is called exactly once for every exchange `serve` was entered for, when the
exchange is terminal: its response written and its request body settled, or its
cancellation settled. `call.exchange.completion` is final, and the scratch is still
valid, so this is where a framework releases what it held for the request and
records its outcome. After `settle` returns, the scratch goes back to the pool. A
request answered without the handler (400, 413, 414, 431) never reaches either. A
connection counted in `Report.unsettled` never settles its exchange. `abandon` and
`settle` may each be nil.

The request is valid for the exchange's generation. Its fields, target and trailers
borrow the connection's parser storage, and its body reader pulls bytes the engine
holds, so reading the body is what lets the connection read more of it. A body the
handler leaves unread is drained, up to `connection.max_drain_bytes`, once the
response is written.

## Wakes

```mach
pub fun wake(waker: Waker) bool;
```

`wake` may be called from any thread. It names one exchange by generation, so a
wake that arrives after its exchange settled is ignored. A waker is valid until the
exchange settles, that is until its bodies are terminal and released, and the server
must outlive every waker it handed out.

## Bounds

| Bound | What happens at it |
| --- | --- |
| `max_connections` | no further accept is submitted; connections wait in the listen backlog |
| `max_exchanges` | a parsed request waits, in arrival order across connections, for an exchange to settle |
| `connection.max_pipeline` | the engine stops reading a connection that holds this many requests |
| `memory_bytes` | a buffer the pool cannot fund leaves the request unread until memory frees |
| per connection lanes | each connection may hold at most its pipeline's slot sets, one scratch, and its read, write and staging buffers |
| parser limits | a head past them is answered 414 or 431 and the connection closes |
| `limits.request_body` | a declared body past it is answered 413 and the connection closes |

The request side of `limits` (method, target, fields and trailers) is derived from
`connection.parser`, the one authority on what a request head may hold.

## Timeouts

Every deadline is an absolute monotonic instant. Slow progress never refreshes it.

| Timeout | Runs |
| --- | --- |
| `connection.header_timeout_ns` | from a connection's accept, or its readability when idle, to a complete request head |
| `body_timeout_ns` | from the start of an exchange to the end of its request body |
| `connection.request_timeout_ns` | over a whole exchange, request and response, so a long streamed response needs it raised |
| `connection.idle_timeout_ns` | while a keep-alive connection holds no request |
| `connection.write_timeout_ns` | from a response head to the end of the response |
| `connection.total_timeout_ns` | over a connection's whole life |

A connection past any of them is closed abortively, and an exchange in flight on it
is abandoned as above. `Report.timed_out` counts them.

## Drain

`shutdown` begins the drain. The listener closes, the drain hook is called with the
deadline (`drain_timeout_ns` from now), and every connection finishes gracefully:
an idle keep-alive connection closes at once, requests the engine already read are
answered, and a response in flight, however long, keeps streaming. Each connection
closes after its last response.

At the deadline, every exchange still in flight is abandoned and every connection
still open is closed abortively (`Report.abandoned_exchanges`,
`Report.abandoned_connections`). What that leaves settling gets `stop_timeout_ns`;
a connection that has not settled by then is counted in `Report.unsettled` and keeps
its record. The stop hook is called once everything has closed, or the stop timeout
passed, with the final report.

## Lifecycle hooks

| Hook | Called | Pending |
| --- | --- | --- |
| `start` | before the listener binds | called again every `hook_poll_ns`; a failure ends serve without stop |
| `ready` | after the listener binds, with its address | the server accepts only once it is done |
| `drain` | when the drain begins, with its deadline | called again until done or the deadline |
| `stop` | after the drain, with the report | called again until done or the stop timeout |

A hook may be nil, which counts as done. A failed bind or ready hook still ends in
`stop`, so a framework that started resources in `start` always sees it.
