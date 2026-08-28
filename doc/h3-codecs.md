# HTTP/3 frame and QPACK codecs

The HTTP/3 codecs allocate nothing. The caller provides every frame setting array,
QPACK entry array, byte arena, instruction buffer, encoded section buffer, decoded
field array, reference array, and blocked-section slot.

## Frames and stream types

Initialize `http.h3.frame.Parser` for a request, push, or control stream. `feed`
incrementally reconstructs the QUIC variable-length type and length, then returns an
`EVENT_HEADER`. Payload events borrow the supplied input until `release`. An
`EVENT_FRAME_END` confirms payload-dependent constraints.

Control streams require SETTINGS as their first frame and reject later SETTINGS.
Every setting identifier, including unknown extensions, is retained in the caller's
bounded `Setting` array so duplicates cannot bypass validation. HTTP/2-reserved
setting and frame types fail closed. Unknown HTTP/3 extensions remain visible to the
caller and are bounded by `max_frame_payload`.

CANCEL_PUSH, GOAWAY, and MAX_PUSH_ID must contain exactly one QUIC variable-length
integer. PUSH_PROMISE exposes its initial Push ID while leaving its QPACK field
section in the borrowed payload. Truncated headers and payloads remain distinct from
state, placement, settings, and excessive-load failures.

`StreamParser` consumes a unidirectional stream type and a Push ID where required.
A shared `CriticalStreams` record claims at most one control, QPACK encoder, and
QPACK decoder stream. A client-originated push stream and a duplicate critical stream
fail before their contents are admitted. The connection engine remains responsible
for treating a closed critical stream as a connection error.

`Writer` emits a complete at-most-sixteen-byte frame header when its output slice can
hold it, then copies partial payload slices. It retains no application payload pointer
between calls.

## QPACK table ownership

`DynamicTable` stores newest entries first in a caller entry array. Names and values
are copied into the table arena. A separate caller scratch arena, at least as large as
the advertised maximum table capacity, makes insertions safe even when their dynamic
name or value reference is itself evicted by the insertion.

Capacity reduction and insertion first prove that every required eviction is
unreferenced. Failure leaves the table unchanged. Each entry carries its RFC absolute
index and an outstanding reference count. The first inserted entry is index zero.

The table starts with capacity zero. `table_set_capacity` cannot exceed the maximum
advertised in SETTINGS. Entry size is name bytes plus value bytes plus 32. Byte
capacity, physical entry capacity, arena capacity, and the 62-bit insertion space are
all enforced.

## Instruction streams

`EncoderStreamDecoder` accepts arbitrary fragments of Set Dynamic Table Capacity,
Insert With Name Reference, Insert With Literal Name, and Duplicate instructions.
It buffers at most one bounded instruction and mutates the table only when that
instruction is complete. Invalid indices, Huffman input, capacity changes, eviction,
and truncated input map to the QPACK encoder-stream failure surface.

`DecoderStreamDecoder` incrementally processes Section Acknowledgment, Stream
Cancellation, and Insert Count Increment. An acknowledgment releases the earliest
unacknowledged dynamic field section on that stream. Cancellation releases all
sections for the stream. An increment must be nonzero and cannot advance beyond the
table's actual Insert Count.

The matching `encode_*` functions construct instructions without retaining output
storage. Table-mutating encoder instructions update local state only after their
complete wire representation fits.

## Field-section decode

`field_decoder_feed` copies fragmented HEADERS payload bytes into the caller's
bounded encoded-section buffer. On the final fragment it reconstructs Required Insert
Count modulo the maximum table entry count and validates Delta Base. Every static,
relative, and post-Base index must resolve below Required Insert Count and above the
drop point.

When Required Insert Count is ahead of the table, the result is `DECODE_BLOCKED`.
The decoder retains its encoded buffer and one `Sections` slot. The HTTP/3 connection
must not return those bytes to QUIC flow control. After encoder-stream insertions,
call `field_decoder_retry`. Call `field_decoder_cancel` when the request stream is
abandoned and emit `encode_stream_cancel` on the decoder stream.

Successful decode copies every name and value into caller field storage, including
static and dynamic indexed fields. Those views remain valid until the decoder storage
is reused and do not depend on later table movement. A nonzero
`required_insert_count` requires a Section Acknowledgment after the field section is
processed.

Independent limits cover encoded section bytes, field count, each decoded name or
value, decompressed field-list bytes including 32 bytes per field, blocked streams,
outstanding sections, and tracked references. A failure clears partial decoded output
and releases its blocked slot.

## Field-section encode

`FieldEncoder` accepts one field at a time. It chooses an exact static or dynamic
index, a static or safe dynamic name reference, or a literal representation. Sensitive
fields always use the never-indexed form. Huffman coding is caller-selected per field.

The encoder reserves prefix space until `field_encoder_finish` knows the largest
dynamic reference. Finish writes Required Insert Count and Delta Base, then registers
the section and each unique entry reference. A reference that could block is used only
when the peer's blocked-stream limit permits it. Referenced entries remain ineligible
for eviction until decoder feedback releases the section.

Output storage may be larger than `max_encoded_section_bytes`. Initialization caps the
encoder's usable view to that configured limit. Invalid non-empty views with a null
data pointer and arithmetic-overflowing limit configurations are rejected before any
input byte is read.

Do not transmit output unless finish succeeds. `field_encoder_abort` discards an
unfinished section without registering references.
