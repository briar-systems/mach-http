# Sustained load against the server runner

This subproject drives `http.server.server` with sustained keep-alive load over
real loopback sockets. It is kept out of the library's own tests because `mach
test` runs cases as parallel processes, and a case that loads the machine would
change what every other case measures.

```sh
mach dep pull test/load
mach test test/load -vv
```

Eight client threads each hold one keep-alive connection. They warm up with 500
requests each, and then send 4000 more, each answered before the next is sent. The
case prints the sustained throughput, and it asserts:

- every request was served, and every connection closed and was released
- no buffer is still borrowed when the server stops
- the buffer pool reached its backing allocator only for the buffers the warm
  connections hold at once, a number that does not grow with the request count
- nothing the server allocated outlives `destroy`: the heap returns to exactly the
  bytes it held before `make`

The heap is not compared mid-run. A client holding its last response does not mean
the server has released that exchange's buffers, and the pool keeps released chunks
up to its high water, so a mid-run reading measures timing, not leaks.

Throughput is printed, not asserted. A slow machine moves the number and not the
verdict.
