## Lossless ClickHouse wire types. Nullable is a required field whose value
## may be JSON null; it is distinct from Roc's optional (missing) fields.
Types :: [].{
	Nullable(a) : Try(a, [Null])

	UInt64 := { value : U64 }.{
		from_value = |value| UInt64.{ value }
		parser_for = |encoding| |state| {
			parsed = match Json.parse_u64(encoding, state) {
				Ok(number) => number
				Err(_) => {
					quoted = Json.parse_str(encoding, state)?
					value = U64.from_str(quoted.value) ? |_| Json.invalid_json({})
					{ value, rest: quoted.rest }
				}
			}
			Ok({ value: UInt64.{ value: parsed.value }, rest: parsed.rest })
		}
		encoder_for = |encoding| |number, state| Json.encode_u64(encoding, number.value, state)
	}

	Int64 := { value : I64 }.{
		from_value = |value| Int64.{ value }
		parser_for = |encoding| |state| {
			parsed = match Json.parse_i64(encoding, state) {
				Ok(number) => number
				Err(_) => {
					quoted = Json.parse_str(encoding, state)?
					value = I64.from_str(quoted.value) ? |_| Json.invalid_json({})
					{ value, rest: quoted.rest }
				}
			}
			Ok({ value: Int64.{ value: parsed.value }, rest: parsed.rest })
		}
		encoder_for = |encoding| |number, state| Json.encode_i64(encoding, number.value, state)
	}

	Decimal := { text : Str }.{
		from_str : Str -> Try(Decimal, [InvalidDecimal])
		from_str = |text| if valid_decimal(text) {
			Ok(Decimal.{ text })
		} else {
			Err(InvalidDecimal)
		}
		parser_for = |encoding| |state| {
			parsed = Json.parse_str(encoding, state)?
			value = from_str(parsed.value) ? |_| Json.invalid_json({})
			Ok({ value, rest: parsed.rest })
		}
		encoder_for = |encoding| |value, state| {
			_ = from_str(value.text) ? |_| Json.invalid_json({})
			Json.encode_str(encoding, value.text, state)
		}
	}

	Date := { text : Str }.{
		from_str : Str -> Try(Date, [InvalidDate])
		from_str = |text| if valid_date(text) {
			Ok(Date.{ text })
		} else {
			Err(InvalidDate)
		}
		parser_for = |encoding| |state| {
			parsed = Json.parse_str(encoding, state)?
			value = from_str(parsed.value) ? |_| Json.invalid_json({})
			Ok({ value, rest: parsed.rest })
		}
		encoder_for = |encoding| |value, state| {
			_ = from_str(value.text) ? |_| Json.invalid_json({})
			Json.encode_str(encoding, value.text, state)
		}
	}

	DateTime64 := { text : Str }.{
		from_str : Str -> Try(DateTime64, [InvalidDateTime64])
		from_str = |text| if valid_timestamp(text) {
			Ok(DateTime64.{ text })
		} else {
			Err(InvalidDateTime64)
		}
		parser_for = |encoding| |state| {
			parsed = Json.parse_str(encoding, state)?
			value = from_str(parsed.value) ? |_| Json.invalid_json({})
			Ok({ value, rest: parsed.rest })
		}
		encoder_for = |encoding| |value, state| {
			_ = from_str(value.text) ? |_| Json.invalid_json({})
			Json.encode_str(encoding, value.text, state)
		}
	}

	Uuid := { text : Str }.{
		from_str : Str -> Try(Uuid, [InvalidUuid])
		from_str = |text| if valid_uuid(text) {
			Ok(Uuid.{ text })
		} else {
			Err(InvalidUuid)
		}
		parser_for = |encoding| |state| {
			parsed = Json.parse_str(encoding, state)?
			value = from_str(parsed.value) ? |_| Json.invalid_json({})
			Ok({ value, rest: parsed.rest })
		}
		encoder_for = |encoding| |value, state| {
			_ = from_str(value.text) ? |_| Json.invalid_json({})
			Json.encode_str(encoding, value.text, state)
		}
	}

}

digits = |bytes| bytes.is_empty() == False and bytes.all(|byte| byte >= 48 and byte <= 57)

valid_decimal = |text| {
	unsigned = if text.starts_with("-") {
		text.to_utf8().drop_first(1)
	} else {
		text.to_utf8()
	}
	pieces = (Str.from_utf8(unsigned) ?? "").split_on(".")
	match pieces {
		[whole] => digits(whole.to_utf8()) and significant_digits(whole.to_utf8()) <= 76
		[whole, fraction] => digits(whole.to_utf8()) and digits(fraction.to_utf8()) and significant_digits(whole.to_utf8()) + fraction.to_utf8().len() <= 76
		_ => False
	}
}

valid_date = |text| {
	parts = text.split_on("-")
	match parts {
		[y, m, d] => {
			if y.to_utf8().len() != 4 or m.to_utf8().len() != 2 or d.to_utf8().len() != 2 or digits(y.to_utf8()) == False or digits(m.to_utf8()) == False or digits(d.to_utf8()) == False {
				return False
			}
			year = U64.from_str(y) ?? 0
			month = U64.from_str(m) ?? 0
			day = U64.from_str(d) ?? 0
			leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
			days = [
				31.U64,
				if leap {
					29
				} else {
					28
				},
				31,
				30,
				31,
				30,
				31,
				31,
				30,
				31,
				30,
				31,
			]
			year > 0 and month > 0 and month <= 12 and day > 0 and day <= (days.get(month.minus_saturated(1)) ?? 0)
		}
		_ => False
	}
}

valid_timestamp = |text| {
	match text.split_on(" ") {
		[day, time] => {
			if valid_date(day) == False {
				return False
			}
			match time.split_on(":") {
				[h, m, seconds] => {
					if h.to_utf8().len() != 2 or m.to_utf8().len() != 2 or digits(h.to_utf8()) == False or digits(m.to_utf8()) == False or (U64.from_str(h) ?? 99) > 23 or (U64.from_str(m) ?? 99) > 59 {
						return False
					}
					match seconds.split_on(".") {
						[s] => s.to_utf8().len() == 2 and digits(s.to_utf8()) and (U64.from_str(s) ?? 99) <= 59
						[s, fraction] => s.to_utf8().len() == 2 and digits(s.to_utf8()) and (U64.from_str(s) ?? 99) <= 59 and digits(fraction.to_utf8()) and fraction.to_utf8().len() <= 9
						_ => False
					}
				}
				_ => False
			}
		}
		_ => False
	}
}

valid_uuid = |text| {
	bytes = text.to_utf8()
	bytes.len() == 36 and bytes.map_with_index(
		|byte, index| if index == 8 or index == 13 or index == 18 or index == 23 {
			byte == 45
		} else {
			(byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 70) or (byte >= 97 and byte <= 102)
		},
	).all(|valid| valid)
}

significant_digits = |bytes| {
	var $start = 0.U64
	while bytes.get($start) == Ok(48) {
		$start = $start + 1
	}
	bytes.len() - $start
}
