# the fuzz lane

`corpus/<boundary>/` holds the retained inputs for every untrusted-input entry
point of the library. Each directory pairs with a row of the registry in
`src/boundaries.mach`, which names the harness that answers it:

| boundary | entry point |
|---|---|
| `h1-request`, `h1-response` | `h1.parser.feed` and `finish_eof`, a request, and a response to GET, HEAD and CONNECT |
| `h2-frame` | `h2.frame.feed` |
| `hpack` | `h2.hpack.decoder_feed` against one dynamic table, after an optional lower `table_set_allowed_max` |
| `hpack-huffman` | `h2.hpack.huffman_decode` |
| `hpack-integer` | `h2.hpack.decode_integer` at every prefix |
| `h3-varint` | `h3.frame.varint_feed` |
| `h3-frame` | `h3.frame.feed` on a request, a control and a push stream |
| `h3-stream` | `h3.frame.stream_feed`, the preface of each unidirectional stream a server or a client opens |
| `qpack-encoder-stream` | `h3.qpack.encoder_stream_feed` |
| `qpack-decoder-stream` | `h3.qpack.decoder_stream_feed` against an encoder with sections outstanding |
| `qpack-field-section` | `h3.qpack.field_decoder_feed` after the encoder stream at the front of the input |
| `field-section` | `core.section.validate` for every kind of section, inbound and outbound |
| `websocket-frame` | `websocket.feed`, as a server and as a client |
| `websocket-upgrade` | `websocket.negotiation.server` and `accept_key`, over http/1.1 and extended CONNECT |
| `websocket-response` | `websocket.negotiation.validate_h1_response` and `validate_extended_response` |
| `router` | `router.router.dispatch` and `decode_capture` against a fixed route table |
| `url` | `client.url.parse`, which reads a redirect's Location |

Most boundaries read the input as the bytes of their wire. A few read it as a
small script: `hpack` is a table-setting byte and then header blocks, each a
two-byte length and that many bytes; `qpack-field-section` is a two-byte length,
that many bytes of encoder stream, and one field section; `field-section` is
`name: value` lines. `websocket-upgrade`, `websocket-response` and `router`
read a message head, parsed by the http/1.1 parser as the connection engine
would hand it over.

## Answers

An input is answered when its entry point parses it or refuses it with a typed
error, and every view the parse publishes lies inside the input or the storage
it was copied into. A harness also checks what its parser promises: a stream
parser answers the same whether the input arrives whole or a byte at a time, a
frame header is the one on the wire and its payload is exactly its length, an
http/3 frame refused from the wire is never refused as a misused parser and one
that carries a single integer fails with exactly the error its payload calls
for, a huffman string or an integer is exactly the encoding of what it decoded to, a
refused header block leaves the dynamic table as it was, an encoder instruction
answers the entry it made, a decoder-stream instruction is taken exactly when
RFC 9204 allows it, a stream preface is refused exactly when it duplicates a
critical stream or pushes from a client, a completed text message is utf-8, a
negotiated handshake carries what RFC 6455 or RFC 8441 requires, a route
capture never decodes to a separator or a dot segment, and an accepted url is
its parts laid end to end. Breaking any of these is a finding.

Each input is copied so that it ends on the last byte before an unreadable page
(`std.allocator.testing`), so a parser that reads one byte past its input
faults on the spot. The websocket decoder unmasks in place, so its harness
places a copy per parse. Storage the library is handed but must initialize, a
qpack encoder's sections, is filled with live-looking garbage first. A crash is
a finding. So is a hang: every walk a harness drives is bounded by its input's
length, and the replay runs under a timeout.

## Running it

From the repository root:

```sh
mach dep pull test/fuzz
mach build test/fuzz
test/fuzz/out/linux-x86_64/debug/bin/fuzz replay
test/fuzz/out/linux-x86_64/debug/bin/fuzz one <boundary> <file>
test/fuzz/out/linux-x86_64/debug/bin/fuzz mutate <boundary|all> <runs> <seed> [--retain]
```

`replay` answers every retained input and fails on a finding, on an empty
boundary directory, or on a directory no boundary answers. CI replays it in both
profiles on the heavy tier: a pull request into `main`, or a dispatch with
`heavy: fuzz` or `heavy: all`. `mach build test/fuzz` runs on every pull request
so the lane cannot rot.

`mutate` is the on-demand search. It draws from a boundary's corpus, applies one
to three structural mutations (flip a bit, set a byte, truncate, extend, swap,
zero a run) from one seeded generator, and answers the result, so a seed and a
run count replay exactly. A finding is written to
`test/fuzz/out/findings/<boundary>/`. With `--retain`, an input whose outcome
the corpus does not hold yet is minimized, by cutting ever smaller chunks while
the outcome holds, and written to its boundary's directory as `m-<outcome>.bin`.

An outcome is what the parse answered: its status or error, and for an
accepted input the shape it took (which frame types, instructions or events a
run held, how many fields, bucketed). This is not code coverage. There is no
coverage instrumentation for Mach, so two inputs that reach different code with
the same answer count as one.

## The corpus

The named files are seeds: valid inputs for each entry point, most of them the
examples of RFC 7541, RFC 9000, RFC 9204 and RFC 6455, beside a few named
refusals the parsers must keep refusing, such as a request that smuggles a body
past `Content-Length`. The `m-*` files were retained by
`fuzz mutate all 20000 1 --retain`.

To retain a new input by hand, put the file in its boundary's directory. When a
finding is fixed, retain the input that found it, so the replay keeps it fixed.
