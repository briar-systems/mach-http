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
- the heap holds no more after the sustained run than after the warmup, measured at
  the same quiet point, with every connection idle between requests
- the buffer pool reached its backing allocator only for the buffers the warm
  connections hold at once, a number that does not grow with the request count

Throughput is printed, not asserted. A slow machine moves the number and not the
verdict.
