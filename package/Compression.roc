import http.Request
import http.Response

## HTTP gzip content coding. Compression is a platform capability; callbacks
## handle bytes, never credentials or SQL. This adapter composes with Client.
Compression :: [].{
	send! = |gzip!, gunzip!, send_http!, request, max_response_bytes| {
		body = Request.body(request)
		compressed = if body.is_empty() {
			body
		} else {
			gzip!(body) ? CompressionError
		}
		headers = Request.headers(request).keep_if(
			|header| {
				name = header.name.with_ascii_lowercased()
				name != "content-length" and name != "content-encoding" and name != "accept-encoding"
			},
		).concat([{ name: "Accept-Encoding", value: "gzip" }, { name: "Content-Length", value: compressed.len().to_str() }])
		encoded_headers = if body.is_empty() {
			headers
		} else {
			headers.append({ name: "Content-Encoding", value: "gzip" })
		}
		response = send_http!(request.with_uri("${Request.uri(request)}&enable_http_compression=1").with_headers(encoded_headers).with_body(compressed), max_response_bytes)?
		encoding = Response.headers(response).keep_if(|header| header.name.with_ascii_lowercased() == "content-encoding").map(|header| header.value.with_ascii_lowercased())
		decoded = match encoding {
			[] | ["identity"] => Response.body(response)
			["gzip"] => gunzip!(Response.body(response), max_response_bytes) ? CompressionError
			_ => {
				return Err(UnsupportedContentEncoding)
			}
		}
		if decoded.len() > max_response_bytes {
			return Err(ResponseTooLarge)
		}
		Ok(response.with_body(decoded).with_headers(Response.headers(response).keep_if(|header| header.name.with_ascii_lowercased() != "content-encoding" and header.name.with_ascii_lowercased() != "content-length")))
	}
}
