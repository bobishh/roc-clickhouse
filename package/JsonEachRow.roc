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
	decode : List(U8) -> Try(List(_), [InvalidUtf8, InvalidRow({ line : U64, problem : _ })])
	decode = |bytes| {
		text = Str.from_utf8(bytes) ? |_| InvalidUtf8
		text.split_on("\n").map_with_index(|line, index| { line, index }).keep_if(|entry| entry.line.trim().is_empty() == False).map_try(
			|entry| {
				value = Json.parse(entry.line) ? |problem| InvalidRow({ line: entry.index + 1, problem })
				Ok(value)
			},
		)
	}
}
