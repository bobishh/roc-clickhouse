JsonEachRow :: [].{

	## Encode typed records as newline-delimited JSON. Non-finite numbers and
	## other encoder failures return errors rather than crashing the application.
	encode : List(_) -> Try(List(U8), [EncodeError(_)])
	encode = |rows| {
		lines = rows.map_try(
			|row| {
				encoded = Json.to_str_try(row) ? EncodeError
				Ok(encoded)
			},
		)?
		Ok(Str.join_with(lines, "\n").to_utf8())
	}

	## The expected result type selects Roc's JSON parser. Reject the complete
	## result on the first invalid row, retaining its original one-based line.
	decode : List(U8) -> Try(List(_), [InvalidUtf8, InvalidRow({ line : U64, problem : _ }), ClickHouseException({ line : U64, code : Str, message : Str })])
	decode = |bytes| {
		text = Str.from_utf8(bytes) ? |_| InvalidUtf8
		text.split_on("\n").map_with_index(|line, index| { line, index }).keep_if(|entry| entry.line.trim().is_empty() == False).map_try(
			|entry| {
				if is_exception(entry.line) {
					return Err(exception({ line: entry.index + 1, bytes: entry.line.to_utf8() }))
				}
				value = Json.parse(entry.line) ? |problem| InvalidRow({ line: entry.index + 1, problem })
				Ok(value)
			},
		)
	}

	StreamError(transport, decode) : [InvalidUtf8, InvalidRow({ line : U64, problem : decode }), ClickHouseException({ line : U64, code : Str, message : Str }), RowTooLarge({ line : U64, limit : U64 }), ChunkTooLarge(U64), TransportError(transport)]

	StreamState(error) : [Finished, Reading({ source : Stream(Try(List(U8), error)), frame : Framer, chunk : List(U8), ended : Bool })]

	Frame : { line : U64, bytes : List(U8) }
	Framer : { line : U64, bytes : List(U8), max_row_bytes : U64 }

	framer : U64 -> Try(Framer, [InvalidConfig(Str)])
	framer = |max_row_bytes| if max_row_bytes == 0 {
		Err(InvalidConfig("max_row_bytes"))
	} else {
		Ok({ line: 1, bytes: [], max_row_bytes })
	}

	## Consume at most one line from a chunk. Framing owns the row budget
	## and retains raw bytes until a complete UTF-8 row is available.
	frame_chunk = |state, chunk| {
		parts = match chunk.split_first(10) {
			Ok(split) => { bytes: split.before, rest: split.after, complete: True }
			Err(NotFound) => { bytes: chunk, rest: [], complete: False }
		}
		if state.bytes.len() + parts.bytes.len() > state.max_row_bytes {
			return Err(RowTooLarge({ line: state.line, limit: state.max_row_bytes }))
		}
		bytes = state.bytes.concat(parts.bytes)
		if parts.complete {
			Ok({ state: { ..state, line: state.line + 1, bytes: [] }, rest: parts.rest, row: Ready({ line: state.line, bytes }) })
		} else {
			Ok({ state: { ..state, bytes }, rest: [], row: NeedMore })
		}
	}

	## One row per request. At most one transport chunk and one partial row
	## are retained. A terminal error is emitted once, then releases the source.
	stream = |chunks, options| {
		if options.max_chunk_bytes == 0 {
			return Err(InvalidConfig("max_chunk_bytes"))
		}
		initial = framer(options.max_row_bytes)?
		Ok(Stream.custom(Reading({ source: chunks, frame: initial, chunk: [], ended: False }), Unknown, |state| stream_step!(state, options.max_chunk_bytes)))
	}

	is_exception = |text| text.trim().starts_with("Code: ") or text.trim() == "__exception__"
	exception = |frame| {
		text = Str.from_utf8(frame.bytes) ?? "ClickHouse exception"
		code = if text.trim().starts_with("Code: ") {
			prefix = Str.from_utf8(text.trim().to_utf8().drop_first(6)) ?? ""
			(prefix.split_on(".").first() ?? "").trim()
		} else {
			""
		}
		ClickHouseException({ line: frame.line, code, message: Str.from_utf8(frame.bytes.take_first(4096)) ?? "ClickHouse exception (truncated UTF-8)" })
	}

	decode_frame = |frame| {
		text = Str.from_utf8(frame.bytes) ? |_| InvalidUtf8
		if text.trim().is_empty() {
			return Ok(Blank)
		}
		if is_exception(text) {
			return Err(exception(frame))
		}
		row = Json.parse(text) ? |problem| InvalidRow({ line: frame.line, problem })
		Ok(Row(row))
	}

}

stream_step! : JsonEachRow.StreamState(transport_error), U64 => Try((Try(row, JsonEachRow.StreamError(transport_error, [InvalidJson(Str), ..parse_errors])), JsonEachRow.StreamState(transport_error)), [NoMore])
	where [row.Json.Parseable([InvalidJson(Str), ..parse_errors])]
stream_step! = |state, max_chunk_bytes| match state {
	Finished => Err(NoMore)
	Reading(current) => {
		if current.chunk.is_empty() == False {
			match JsonEachRow.frame_chunk(current.frame, current.chunk) {
				Err(error) => Ok((Err(error), Finished))
				Ok(framed) => {
					rest = Reading({ ..current, frame: framed.state, chunk: framed.rest })
					match framed.row {
						NeedMore => stream_step!(rest, max_chunk_bytes)
						Ready(frame) => match JsonEachRow.decode_frame(frame) {
							Ok(Blank) => stream_step!(rest, max_chunk_bytes)
							Ok(Row(row)) => Ok((Ok(row), rest))
							Err(error) => Ok((Err(error), Finished))
						}
					}
				}
			}
		} else if current.ended {
			if current.frame.bytes.is_empty() {
				return Err(NoMore)
			}
			match JsonEachRow.decode_frame({ line: current.frame.line, bytes: current.frame.bytes }) {
				Ok(Blank) => Err(NoMore)
				Ok(Row(row)) => Ok((Ok(row), Finished))
				Err(error) => Ok((Err(error), Finished))
			}
		} else {
			match current.source.next!() {
				Done => stream_step!(Reading({ ..current, ended: True }), max_chunk_bytes)
				Skip({ rest }) => stream_step!(Reading({ ..current, source: rest }), max_chunk_bytes)
				One({ item, rest }) => match item {
					Err(error) => Ok((Err(TransportError(error)), Finished))
					Ok(bytes) => {
						if bytes.len() > max_chunk_bytes {
							return Ok((Err(ChunkTooLarge(max_chunk_bytes)), Finished))
						}
						stream_step!(Reading({ ..current, source: rest, chunk: bytes }), max_chunk_bytes)
					}
				}
			}
		}
	}
}
