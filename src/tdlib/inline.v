// tdlib/inline.v
// Inline query result constructors for BotAccount.answer_inline_query().
//
// These helpers build inputInlineQueryResult* objects that are passed as the
// results slice to BotAccount.answer_inline_query().  They are client-side
// value constructors only — no TDLib API call is made here.
//
// --- Usage ---
//
//   bot.answer_inline_query(query_id, [
//       tdlib.inline_result_article('1', 'Hello', 'Sends a greeting',
//           tdlib.plain_text('Hello!'), json2.Any({})),
//       tdlib.inline_result_photo_simple('2', 'Cat', 'A fluffy cat',
//           'https://example.com/cat.jpg',
//           'https://example.com/cat_thumb.jpg'),
//       tdlib.inline_result_gif_simple('3', 'Wave',
//           'https://example.com/wave.gif',
//           'https://example.com/wave_thumb.jpg',
//           'image/jpeg'),
//   ], 10, true, '')!
//
// --- See also ---
//
//   builder.v  — plain_text / html_text / markdown_text for message content
//   botapi.v   — bot_answer_inline_query implementation
//   botaccount.v — BotAccount.answer_inline_query() public method
module tdlib

import x.json2

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
