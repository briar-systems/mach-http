# HTTP/2 frame and HPACK codecs

The HTTP/2 codecs are allocation-free. All parser state, tables, encoded blocks,
decoded fields, strings, and output bytes live in caller-provided storage.

## Frames

Initialize `http.h2.frame.Parser` with a receiver frame-size limit. `feed` first
returns `EVENT_HEADER` after exactly nine header bytes. Subsequent calls return
borrowed `EVENT_PAYLOAD` views until the declared payload ends. Call `release` before
feeding more input. A final `EVENT_FRAME_END` confirms payload-dependent constraints.

The parser enforces:

- the configured frame-size limit and every type-specific fixed or minimum size
- connection-only and stream-only frame placement
- uninterrupted HEADERS, PUSH_PROMISE, and CONTINUATION sequences
- SETTINGS ACK length, six-byte records, known value domains, and duplicate values
- valid padding, promised streams, and window increments
- distinct frame-size, protocol, flow-control, and truncated-input outcomes

A PRIORITY frame or HEADERS priority block whose stream depends on itself is
passed through, because RFC 9113 makes that a stream error, which the connection
engine raises. The writer refuses to encode one.

Unknown frame types are surfaced without interpreting their payload, as HTTP/2
requires. Unknown flags are ignored. The reserved stream bit is ignored on input and
always clear on output.

`Writer` emits the nine-byte header, then copies partial payload slices. It never
retains an application payload pointer. `encode_setting` and
`encode_window_update` construct the bounded typed payload members used most often by
the connection engine.

## HPACK tables

`DynamicTable` uses a caller-owned entry array and byte arena. New entries are stored
newest first. Insertion evicts the oldest entries until both the negotiated byte size
and physical entry count fit. Values are copied into the table, so decoded block
storage can be released independently.

`table_set_allowed_max` records a peer SETTINGS change. A reduction requires the
next field block to begin with the smallest pending table-size update. If the limit
was subsequently raised, a second update may raise the table to the final value.
Missing, late, or out-of-order updates fail without changing the table.

## HPACK decode

`decoder_feed` accepts arbitrary chunks into the configured encoded-block buffer.
The final call parses the block into caller field and string storage. The decoder
simulates table updates and incremental-index insertions in caller-provided pending
entry storage. It commits them only after the entire block succeeds, so malformed
integers, indices, strings, Huffman input, or later fields never desynchronize the
compression context.

Limits are independent:

- encoded field-block bytes
- decoded field count
- decoded field-list bytes, including HPACK's 32-byte per-field accounting
- decoded bytes for each name or value
- negotiated dynamic-table bytes
- physical table entries and storage

Decoded fields borrow the decoder string arena until that arena is reused. Dynamic
entries own copies in the table arena.

## HPACK encode

`encoder_field` supports automatic indexed representation, incremental indexing,
literal without indexing, and literal never indexed. Sensitive fields always use
never indexed. Callers choose raw or RFC Huffman strings per field. All output and
shadow table changes remain pending until `encoder_finish`. `encoder_abort` discards
the block without changing compression state.

The connection engine must not transmit a field block until `encoder_finish`
succeeds. After success, the encoder and peer decoder advance to the same committed
dynamic-table generation.
