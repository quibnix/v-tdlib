// tdlib/builder.v
// Fluent RequestBuilder and value-constructor helpers.
//
// --- Building a request ---
//
//   req := tdlib.new_request('sendMessage')
//       .with_i64('chat_id', chat_id)
//       .with_obj('input_message_content', {
//           '@type': json2.Any('inputMessageText')
//           'text':  tdlib.plain_text('Hello!')
//       })
//       .build()!
//
// --- InputFile helpers ---
//
//   tdlib.input_local('/path/to/file.jpg')   -> inputFileLocal
//   tdlib.input_id(file_id)                  -> inputFileId
//   tdlib.input_remote(remote_id)            -> inputFileRemote
//
// --- FormattedText helpers ---
//
//   tdlib.plain_text('Hello')                -> formattedText (no entities)
//   tdlib.html_text('<b>Bold</b>')!          -> formattedText (parsed HTML)
//   tdlib.markdown_text('*Bold*')!           -> formattedText (parsed Markdown)
//
// --- Inline query result constructors ---
//
//   See inline.v for inputInlineQueryResult* builders used with
//   BotAccount.answer_inline_query().
module tdlib

import x.json2

// --- RequestBuilder ---

// RequestBuilder assembles a TDLib JSON request with a fluent API.
// All with*() methods return a new copy - chains are safe to split and reuse.
pub struct RequestBuilder {
pub mut:
	typ    string
	params map[string]json2.Any
}

// new_request starts a new builder for the given TDLib method name.
pub fn new_request(typ string) RequestBuilder {
	return RequestBuilder{
		typ:    typ
		params: map[string]json2.Any{}
	}
}

// with sets key to any json2.Any value.
pub fn (r RequestBuilder) with(key string, value json2.Any) RequestBuilder {
	mut r2 := r
	r2.params[key] = value
	return r2
}

// with_str sets key to a string value.
pub fn (r RequestBuilder) with_str(key string, value string) RequestBuilder {
	return r.with(key, json2.Any(value))
}

// with_bool sets key to a bool value.
pub fn (r RequestBuilder) with_bool(key string, value bool) RequestBuilder {
	return r.with(key, json2.Any(value))
}

// with_int sets key to an int value.
pub fn (r RequestBuilder) with_int(key string, value int) RequestBuilder {
	return r.with(key, json2.Any(value))
}

// with_i64 sets key to an i64 value.  Use for Telegram IDs and timestamps.
pub fn (r RequestBuilder) with_i64(key string, value i64) RequestBuilder {
	return r.with(key, json2.Any(value))
}

// with_f64 sets key to an f64 value.
pub fn (r RequestBuilder) with_f64(key string, value f64) RequestBuilder {
	return r.with(key, json2.Any(value))
}

// with_obj sets key to a nested object.
pub fn (r RequestBuilder) with_obj(key string, m map[string]json2.Any) RequestBuilder {
	return r.with(key, json2.Any(m))
}

// with_arr sets key to a JSON array.
pub fn (r RequestBuilder) with_arr(key string, items []json2.Any) RequestBuilder {
	return r.with(key, json2.Any(items))
}

// with_builder embeds another RequestBuilder as a nested object.
pub fn (r RequestBuilder) with_builder(key string, inner RequestBuilder) !RequestBuilder {
	return r.with(key, inner.build()!)
}

// build assembles the request into a json2.Any map ready for send_sync().
// Returns an error if the @type is empty (indicates a programming error).
pub fn (r RequestBuilder) build() !json2.Any {
	if r.typ == '' {
		return error('RequestBuilder.build(): @type must not be empty')
	}
	return build_map(r.typ, r.params)
}

// build_map is the internal function that assembles the final TDLib request map.
// It merges @type and all params into a single json2.Any map object.
fn build_map(typ string, params map[string]json2.Any) json2.Any {
	mut m := map[string]json2.Any{}
	m['@type'] = json2.Any(typ)
	for k, v in params {
		m[k] = v
	}
	return json2.Any(m)
}

// --- Value constructors ---

// val wraps any supported primitive as json2.Any without a lossy JSON round-trip.
// Supported: string, bool, int, i8, i16, i64, u8, u16, u32, u64, f32, f64.
pub fn val[T](v T) !json2.Any {
	$if T is string {
		return json2.Any(v)
	} $else $if T is bool {
		return json2.Any(v)
	} $else $if T is int {
		return json2.Any(v)
	} $else $if T is i8 {
		return json2.Any(v)
	} $else $if T is i16 {
		return json2.Any(v)
	} $else $if T is i64 {
		return json2.Any(v)
	} $else $if T is u8 {
		return json2.Any(v)
	} $else $if T is u16 {
		return json2.Any(v)
	} $else $if T is u32 {
		return json2.Any(v)
	} $else $if T is u64 {
		return json2.Any(v)
	} $else $if T is f32 {
		return json2.Any(v)
	} $else $if T is f64 {
		return json2.Any(v)
	} $else {
		encoded := json2.encode(v)
		return json2.decode[json2.Any](encoded)!
	}
}

// obj wraps a map[string]json2.Any as json2.Any.
pub fn obj(m map[string]json2.Any) json2.Any {
	return json2.Any(m)
}

// arr wraps a []json2.Any as json2.Any.
pub fn arr(items []json2.Any) json2.Any {
	return json2.Any(items)
}

// typed_obj creates a json2.Any object with @type set and extra fields merged in.
// Shortcut for building TDLib sub-objects:
//
//   tdlib.typed_obj('proxyTypeSocks5', { 'username': json2.Any('user') })
pub fn typed_obj(typ string, fields map[string]json2.Any) json2.Any {
	mut m := map[string]json2.Any{}
	m['@type'] = json2.Any(typ)
	for k, v in fields {
		m[k] = v
	}
	return json2.Any(m)
}

// arr_of_i64 builds a json2.Any array from a []i64 slice.
// Handy for message_ids, user_ids, chat_ids, etc.
pub fn arr_of_i64(ids []i64) json2.Any {
	mut items := []json2.Any{cap: ids.len}
	for id in ids {
		items << json2.Any(id)
	}
	return json2.Any(items)
}

// arr_of_str builds a json2.Any array from a []string slice.
pub fn arr_of_str(strs []string) json2.Any {
	mut items := []json2.Any{cap: strs.len}
	for s in strs {
		items << json2.Any(s)
	}
	return json2.Any(items)
}

// --- InputFile constructors ---

// input_local returns an inputFileLocal object for a file on disk.
pub fn input_local(path string) json2.Any {
	return typed_obj('inputFileLocal', {
		'path': json2.Any(path)
	})
}

// input_id returns an inputFileId object for a file already known to TDLib.
pub fn input_id(file_id i64) json2.Any {
	return typed_obj('inputFileId', {
		'id': json2.Any(file_id)
	})
}

// input_remote returns an inputFileRemote object using a Telegram remote_id string.
pub fn input_remote(remote_id string) json2.Any {
	return typed_obj('inputFileRemote', {
		'id': json2.Any(remote_id)
	})
}

// --- FormattedText constructors ---

// plain_text returns a formattedText json2.Any with no entities.
//
// BUG FIX: The previous implementation omitted the required 'entities' field.
// TDLib schema: formattedText text:string entities:vector<textEntity>
// Passing a formattedText without 'entities' causes TDLib to reject requests
// that include it (e.g. sendMessage, inputMessagePoll question/options, poll
// explanation) with a parameter validation error.  An empty array is correct
// for plain (unformatted) text.
pub fn plain_text(text string) json2.Any {
	return typed_obj('formattedText', {
		'text':     json2.Any(text)
		'entities': json2.Any([]json2.Any{})
	})
}

// html_text parses an HTML string via TDLib's synchronous parseTextEntities.
// Supported tags: <b>, <i>, <u>, <s>, <code>, <pre>, <a href="">.
pub fn html_text(text string) !json2.Any {
	req := typed_obj('parseTextEntities', {
		'text':       json2.Any(text)
		'parse_mode': typed_obj('textParseModeHTML', map[string]json2.Any{})
	})
	return execute(req)!
}

// markdown_text parses a MarkdownV2 string via TDLib.
// Syntax: *bold*, _italic_, `code`, ```pre```, [text](url).
pub fn markdown_text(text string) !json2.Any {
	req := typed_obj('parseTextEntities', {
		'text':       json2.Any(text)
		'parse_mode': typed_obj('textParseModeMarkdown', {
			'version': json2.Any(2)
		})
	})
	return execute(req)!
}
