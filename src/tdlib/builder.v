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

// --- Inline query result constructors ---
//
// These helpers build inputInlineQueryResult* objects for use in
// BotAccount.answer_inline_query().

// inline_result_article builds an inputInlineQueryResultArticle.
// This is the most common result type: shows a title + description in the picker
// and sends a text message when selected.
//
//   bot.answer_inline_query(query_id, [
//       tdlib.inline_result_article('id1', 'Hello', 'Sends a greeting', tdlib.plain_text('Hello!'), json2.Any({})),
//   ], 10, true, '')!
pub fn inline_result_article(id string, title string, description string, message_content json2.Any, markup json2.Any) json2.Any {
	mut m := map[string]json2.Any{}
	m['@type'] = json2.Any('inputInlineQueryResultArticle')
	m['id'] = json2.Any(id)
	m['title'] = json2.Any(title)
	m['description'] = json2.Any(description)
	m['input_message_content'] = message_content
	if markup.as_map().len > 0 {
		m['reply_markup'] = markup
	}
	return json2.Any(m)
}

// inline_result_photo builds an inputInlineQueryResultPhoto for an inline photo result.
// photo_url must be a public HTTPS URL of a JPEG.
// thumbnail_url should be a smaller version of the same image.
// photo_width / photo_height: dimensions in pixels (0 = unspecified, TDLib will fetch).
// input_message_content: the message TDLib sends when the user picks this result.
//   Pass json2.Any(map[string]json2.Any{}) to send the photo itself.
//   Or pass a text inputMessageContent to send a text message alongside.
pub fn inline_result_photo(id string,
	title string,
	description string,
	photo_url string,
	thumbnail_url string,
	photo_width int,
	photo_height int,
	input_message_content json2.Any,
	markup json2.Any) json2.Any {
	mut m := map[string]json2.Any{}
	m['@type'] = json2.Any('inputInlineQueryResultPhoto')
	m['id'] = json2.Any(id)
	m['title'] = json2.Any(title)
	m['description'] = json2.Any(description)
	m['photo_url'] = json2.Any(photo_url)
	m['thumbnail_url'] = json2.Any(thumbnail_url)
	if photo_width > 0 {
		m['photo_width'] = json2.Any(photo_width)
	}
	if photo_height > 0 {
		m['photo_height'] = json2.Any(photo_height)
	}
	imc_m := input_message_content.as_map()
	if imc_m.len > 0 {
		m['input_message_content'] = input_message_content
	}
	if markup.as_map().len > 0 {
		m['reply_markup'] = markup
	}
	return json2.Any(m)
}

// inline_result_photo_simple is a convenience wrapper for the common case
// where you just want to return a photo without custom message content.
//
//   tdlib.inline_result_photo_simple('id1', 'Cat', 'A fluffy cat',
//       'https://example.com/cat.jpg',
//       'https://example.com/cat_thumb.jpg',
//   )
pub fn inline_result_photo_simple(id string,
	title string,
	description string,
	photo_url string,
	thumb_url string) json2.Any {
	return inline_result_photo(id, title, description, photo_url, thumb_url, 0, 0, json2.Any(map[string]json2.Any{}),
		json2.Any(map[string]json2.Any{}))
}

// inline_result_gif builds an inputInlineQueryResultAnimation for an animated GIF/MP4 result.
//
// animation_url: public HTTPS URL of the animation file (GIF or MP4).
// thumbnail_url: public HTTPS URL of a static preview image.
// thumbnail_mime_type: MIME type of the thumbnail (required by TDLib):
//   - "image/jpeg" or "image/gif" for GIF thumbnails
//   - "video/mp4" for MP4 thumbnails
// duration_secs: animation duration in seconds (0 = unspecified).
// width / height: animation dimensions in pixels (0 = unspecified).
// input_message_content: the message TDLib sends when the user picks this result.
//   Pass json2.Any(map[string]json2.Any{}) to send the animation itself (default).
//
// BUG FIX (original): The previous version used 'gif_url' which is the Bot API field name.
// TDLib JSON uses 'animation_url'.  Also, 'thumbnail_mime_type' is required by TDLib
// to distinguish GIF thumbnails from MP4 thumbnails.
pub fn inline_result_gif(id string,
	title string,
	animation_url string,
	thumbnail_url string,
	thumbnail_mime_type string,
	duration_secs int,
	width int,
	height int,
	input_message_content json2.Any,
	markup json2.Any) json2.Any {
	mut m := map[string]json2.Any{}
	m['@type'] = json2.Any('inputInlineQueryResultAnimation')
	m['id'] = json2.Any(id)
	m['title'] = json2.Any(title)
	m['animation_url'] = json2.Any(animation_url)
	m['thumbnail_url'] = json2.Any(thumbnail_url)
	m['thumbnail_mime_type'] = json2.Any(thumbnail_mime_type)
	if duration_secs > 0 {
		m['animation_duration'] = json2.Any(duration_secs)
	}
	if width > 0 {
		m['animation_width'] = json2.Any(width)
	}
	if height > 0 {
		m['animation_height'] = json2.Any(height)
	}
	imc_m := input_message_content.as_map()
	if imc_m.len > 0 {
		m['input_message_content'] = input_message_content
	}
	if markup.as_map().len > 0 {
		m['reply_markup'] = markup
	}
	return json2.Any(m)
}

// inline_result_gif_simple is a convenience wrapper over inline_result_gif
// for the common case of a plain GIF with no custom message content.
//
//   tdlib.inline_result_gif_simple('id', 'title',
//       'https://example.com/anim.gif',
//       'https://example.com/thumb.jpg',
//       'image/jpeg',
//   )
pub fn inline_result_gif_simple(id string,
	title string,
	animation_url string,
	thumbnail_url string,
	thumbnail_mime_type string) json2.Any {
	return inline_result_gif(id, title, animation_url, thumbnail_url, thumbnail_mime_type,
		0, 0, 0, json2.Any(map[string]json2.Any{}), json2.Any(map[string]json2.Any{}))
}
