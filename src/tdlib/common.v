// tdlib/common.v
// Internal module-level functions shared by UserAccount and BotAccount.
//
// All public surface area lives on the account structs.  This file holds the
// actual implementations; the structs delegate to these functions.
//
// --- Adding a new feature ---
//
// 1. Write the implementation here (or in a new .v file in this module).
// 2. Expose it on UserAccount and/or BotAccount as a one-liner delegation.
// 3. Nothing else needs changing - tdlib.v, builder.v, and types.v are stable.
//
// --- Keyboard markup ---
//
// Inline keyboards and reply keyboards both use the same send_*_with_keyboard
// dispatch path.  The markup object distinguishes them:
//   - inline_keyboard_markup(...)    -> replyMarkupInlineKeyboard
//   - reply_keyboard_markup(...)     -> replyMarkupShowKeyboard
//   - remove_keyboard(...)           -> replyMarkupRemoveKeyboard
//   - force_reply(...)               -> replyMarkupForceReply
//
// Reply keyboard code is included in this file (not a separate reply_keyboard.v).
module tdlib

import x.json2
import encoding.base64

// --- TDLib parameters ---

fn setup_parameters(s Session, mut td TDLib, api_id int, api_hash string, data_dir string) !json2.Any {
	req := new_request('setTdlibParameters').with_str('database_directory', data_dir).with_bool('use_message_database',
		true).with_bool('use_file_database', true).with_bool('use_chat_info_database',
		true).with_int('api_id', api_id).with_str('api_hash', api_hash).with_str('system_language_code',
		'en').with_str('device_model', 'Server').with_str('application_version', '1.0').build()!
	return s.send_sync(mut td, req)
}

// --- Identity ---

fn get_me(s Session, mut td TDLib) !User {
	req := new_request('getMe').build()!
	resp := s.send_sync(mut td, req)!
	return User.from(resp.as_map())
}

fn get_user(s Session, mut td TDLib, user_id i64) !User {
	req := new_request('getUser').with_i64('user_id', user_id).build()!
	resp := s.send_sync(mut td, req)!
	return User.from(resp.as_map())
}

fn get_chat(s Session, mut td TDLib, chat_id i64) !Chat {
	req := new_request('getChat').with_i64('chat_id', chat_id).build()!
	resp := s.send_sync(mut td, req)!
	return Chat.from(resp.as_map())
}

fn get_message(s Session, mut td TDLib, chat_id i64, message_id i64) !Message {
	req := new_request('getMessage').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).build()!
	resp := s.send_sync(mut td, req)!
	return Message.from(resp.as_map())
}

fn get_chat_history(s Session, mut td TDLib, chat_id i64, from_message_id i64, limit int) ![]Message {
	req := new_request('getChatHistory').with_i64('chat_id', chat_id).with_i64('from_message_id',
		from_message_id).with_int('offset', 0).with_int('limit', limit).with_bool('only_local',
		false).build()!
	resp := s.send_sync(mut td, req)!
	raw_msgs := map_arr(resp.as_map(), 'messages')
	mut msgs := []Message{cap: raw_msgs.len}
	for rm in raw_msgs {
		msgs << Message.from(rm.as_map())
	}
	return msgs
}

// get_chats returns the first `limit` chat IDs from the main chat list.
// The list is sorted by last activity (most recent first).
// Tip: call get_chat() on each ID to get full chat details.
fn get_chats(s Session, mut td TDLib, limit int) ![]i64 {
	req := new_request('getChats').with_obj('chat_list', {
		'@type': json2.Any('chatListMain')
	}).with_int('limit', limit).build()!
	resp := s.send_sync(mut td, req)!
	raw_ids := map_arr(resp.as_map(), 'chat_ids')
	mut ids := []i64{cap: raw_ids.len}
	for v in raw_ids {
		ids << any_to_i64(v)
	}
	return ids
}

// --- Sending messages ---

// SendOptions groups optional parameters common to most send calls.
pub struct SendOptions {
pub:
	reply_to_message_id i64  // 0 = no reply
	silent              bool // suppress notification for recipient
	protect_content     bool // disable forwarding and saving
}

fn send_text_message(s Session, mut td TDLib, chat_id i64, text string, opts SendOptions) !json2.Any {
	return send_message_with_content(s, mut td, chat_id, plain_text(text), opts)
}

fn send_html_message(s Session, mut td TDLib, chat_id i64, html string, opts SendOptions) !json2.Any {
	formatted := html_text(html)!
	return send_message_with_content(s, mut td, chat_id, formatted, opts)
}

fn send_markdown_message(s Session, mut td TDLib, chat_id i64, md string, opts SendOptions) !json2.Any {
	formatted := markdown_text(md)!
	return send_message_with_content(s, mut td, chat_id, formatted, opts)
}

fn send_message_with_content(s Session, mut td TDLib, chat_id i64, formatted json2.Any, opts SendOptions) !json2.Any {
	content := typed_obj('inputMessageText', {
		'text': formatted
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts, json2.Any(map[string]json2.Any{}))
}

// --- Sending media ---

pub struct PhotoSendOptions {
pub:
	send    SendOptions
	caption string
	ttl     int // self-destruct timer in seconds (0 = permanent)
}

fn send_photo(s Session, mut td TDLib, chat_id i64, input_file json2.Any, opts PhotoSendOptions) !json2.Any {
	mut fields := map[string]json2.Any{}
	fields['@type'] = json2.Any('inputMessagePhoto')
	fields['photo'] = input_file
	fields['caption'] = plain_text(opts.caption)
	if opts.ttl > 0 {
		// BUG FIX: inputMessagePhoto requires self_destruct_type:MessageSelfDestructType,
		// which must be a typed object with @type 'messageSelfDestructTypeTimer'.
		// Sending a plain integer for self_destruct_time was rejected by TDLib.
		fields['self_destruct_type'] = typed_obj('messageSelfDestructTypeTimer', {
			'self_destruct_time': json2.Any(opts.ttl)
		})
	}
	return dispatch_send_message(s, mut td, chat_id, obj(fields), opts.send, json2.Any(map[string]json2.Any{}))
}

pub struct VideoSendOptions {
pub:
	send               SendOptions
	caption            string
	duration           int
	width              int
	height             int
	supports_streaming bool
	ttl                int
}

fn send_video(s Session, mut td TDLib, chat_id i64, input_file json2.Any, opts VideoSendOptions) !json2.Any {
	mut fields := map[string]json2.Any{}
	fields['@type'] = json2.Any('inputMessageVideo')
	fields['video'] = input_file
	fields['duration'] = json2.Any(opts.duration)
	fields['width'] = json2.Any(opts.width)
	fields['height'] = json2.Any(opts.height)
	fields['supports_streaming'] = json2.Any(opts.supports_streaming)
	fields['caption'] = plain_text(opts.caption)
	if opts.ttl > 0 {
		// BUG FIX: Same as send_photo - inputMessageVideo requires self_destruct_type
		// as a typed MessageSelfDestructType object, not a bare integer.
		fields['self_destruct_type'] = typed_obj('messageSelfDestructTypeTimer', {
			'self_destruct_time': json2.Any(opts.ttl)
		})
	}
	return dispatch_send_message(s, mut td, chat_id, obj(fields), opts.send, json2.Any(map[string]json2.Any{}))
}

pub struct AudioSendOptions {
pub:
	send      SendOptions
	caption   string
	duration  int
	title     string
	performer string
}

fn send_audio(s Session, mut td TDLib, chat_id i64, input_file json2.Any, opts AudioSendOptions) !json2.Any {
	content := obj({
		'@type':     json2.Any('inputMessageAudio')
		'audio':     input_file
		'duration':  json2.Any(opts.duration)
		'title':     json2.Any(opts.title)
		'performer': json2.Any(opts.performer)
		'caption':   plain_text(opts.caption)
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts.send, json2.Any(map[string]json2.Any{}))
}

pub struct VoiceSendOptions {
pub:
	send     SendOptions
	duration int
	// waveform is the raw PCM waveform data for the voice note visualiser.
	// It will be base64-encoded before being sent to TDLib.
	// Leave empty to omit the waveform (clients will show a flat bar instead).
	waveform []u8
	caption  string
}

fn send_voice_note(s Session, mut td TDLib, chat_id i64, input_file json2.Any, opts VoiceSendOptions) !json2.Any {
	mut fields := map[string]json2.Any{}
	fields['@type'] = json2.Any('inputMessageVoiceNote')
	fields['voice_note'] = input_file
	fields['duration'] = json2.Any(opts.duration)
	fields['caption'] = plain_text(opts.caption)
	if opts.waveform.len > 0 {
		// TDLib's inputMessageVoiceNote.waveform is a bytes field; the JSON API
		// encodes all bytes fields as base64 strings.
		fields['waveform'] = json2.Any(base64.encode(opts.waveform))
	}
	return dispatch_send_message(s, mut td, chat_id, obj(fields), opts.send, json2.Any(map[string]json2.Any{}))
}

pub struct VideoNoteSendOptions {
pub:
	send     SendOptions
	duration int
	length   int // circle diameter in pixels
}

fn send_video_note(s Session, mut td TDLib, chat_id i64, input_file json2.Any, opts VideoNoteSendOptions) !json2.Any {
	content := obj({
		'@type':      json2.Any('inputMessageVideoNote')
		'video_note': input_file
		'duration':   json2.Any(opts.duration)
		'length':     json2.Any(opts.length)
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts.send, json2.Any(map[string]json2.Any{}))
}

pub struct DocumentSendOptions {
pub:
	send    SendOptions
	caption string
}

fn send_document(s Session, mut td TDLib, chat_id i64, input_file json2.Any, opts DocumentSendOptions) !json2.Any {
	content := obj({
		'@type':    json2.Any('inputMessageDocument')
		'document': input_file
		'caption':  plain_text(opts.caption)
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts.send, json2.Any(map[string]json2.Any{}))
}

// AnimationSendOptions groups optional parameters for sending an animation (GIF or MP4).
pub struct AnimationSendOptions {
pub:
	send    SendOptions
	caption string
	// duration of the animation in seconds (0 = unspecified).
	duration int
	// width and height in pixels (0 = unspecified).
	width  int
	height int
}

// send_animation sends an animation file (GIF or H.264/MPEG-4 AVC without sound).
// input_file: use input_local(), input_id(), or input_remote().
//
// TDLib schema: inputMessageAnimation animation:InputFile duration:int32
//   width:int32 height:int32 caption:formattedText
fn send_animation(s Session, mut td TDLib, chat_id i64, input_file json2.Any, opts AnimationSendOptions) !json2.Any {
	content := obj({
		'@type':     json2.Any('inputMessageAnimation')
		'animation': input_file
		'duration':  json2.Any(opts.duration)
		'width':     json2.Any(opts.width)
		'height':    json2.Any(opts.height)
		'caption':   plain_text(opts.caption)
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts.send, json2.Any(map[string]json2.Any{}))
}

// StickerSendOptions groups optional parameters for sending a sticker.
//
// TDLib schema: inputMessageSticker sticker:InputFile
//   thumbnail:InputThumbnail? width:int32 height:int32 emoji:string
//
// width and height (in pixels) help TDLib render the sticker correctly in the
// chat list; pass 0 to let TDLib determine them from the file.
// emoji is the primary emoji associated with this sticker; '' is fine for
// stickers from a set (TDLib reads it from the set metadata).
// The send_sticker implementation lives in extras.v alongside the other
// "extra content" send functions; StickerSendOptions is defined here so that
// account method signatures can reference it without importing extras.v explicitly.
pub struct StickerSendOptions {
pub:
	send   SendOptions
	width  int    // 0 = auto
	height int    // 0 = auto
	emoji  string // '' = none
}

fn send_location(s Session, mut td TDLib, chat_id i64, latitude f64, longitude f64, opts SendOptions) !json2.Any {
	content := typed_obj('inputMessageLocation', {
		'location': typed_obj('location', {
			'latitude':  json2.Any(latitude)
			'longitude': json2.Any(longitude)
		})
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts, json2.Any(map[string]json2.Any{}))
}

// LiveLocationOptions holds optional parameters for a live location message.
// After sending, call edit_live_location() to push position updates and
// stop_live_location() to end the live share early.
pub struct LiveLocationOptions {
pub:
	send SendOptions
	// live_period: seconds the live location remains active (60..86400).
	// Telegram enforces a minimum of 60 s and a maximum of 86400 (24 h).
	// Use 0x7FFFFFFF (2147483647) for "indefinite" (stays live until manually stopped).
	live_period int = 900 // default: 15 minutes
	// heading: direction of travel in degrees (1..360). 0 = not set.
	heading int
	// proximity_alert_radius: alert when another user comes within this radius
	// in metres. Supported: 0 (disabled) or 1..100000.
	proximity_alert_radius int
}

// send_live_location sends a live location message that Telegram clients update
// in real time as new positions are pushed via edit_message_live_location().
//
// After sending, push position updates with edit_message_live_location().
// To stop the live share early, call stop_message_live_location().
fn send_live_location(s Session, mut td TDLib, chat_id i64, latitude f64, longitude f64, opts LiveLocationOptions) !json2.Any {
	mut fields := map[string]json2.Any{}
	fields['@type'] = json2.Any('inputMessageLocation')
	fields['location'] = typed_obj('location', {
		'latitude':  json2.Any(latitude)
		'longitude': json2.Any(longitude)
	})
	fields['live_period'] = json2.Any(opts.live_period)
	if opts.heading > 0 {
		fields['heading'] = json2.Any(opts.heading)
	}
	if opts.proximity_alert_radius > 0 {
		fields['proximity_alert_radius'] = json2.Any(opts.proximity_alert_radius)
	}
	return dispatch_send_message(s, mut td, chat_id, json2.Any(fields), opts.send, json2.Any(map[string]json2.Any{}))
}

// VenueOptions groups optional send parameters for send_venue.
pub struct VenueOptions {
pub:
	send SendOptions
}

// send_venue sends a venue (named location with address) message.
//
// provider / provider_id: pass '' / '' for a plain venue with no third-party
// link.  Use 'foursquare' + a Foursquare place ID for richer venue cards.
fn send_venue(s Session, mut td TDLib, chat_id i64, latitude f64, longitude f64,
	title string, address string, provider string, provider_id string, opts VenueOptions) !json2.Any {
	mut venue_m := map[string]json2.Any{}
	venue_m['@type'] = json2.Any('venue')
	venue_m['location'] = typed_obj('location', {
		'latitude':  json2.Any(latitude)
		'longitude': json2.Any(longitude)
	})
	venue_m['title'] = json2.Any(title)
	venue_m['address'] = json2.Any(address)
	venue_m['provider'] = json2.Any(provider)
	venue_m['id'] = json2.Any(provider_id)
	venue_m['type'] = json2.Any('')
	content := typed_obj('inputMessageVenue', {
		'venue': json2.Any(venue_m)
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts.send, json2.Any(map[string]json2.Any{}))
}

// --- Sending with inline keyboard ---

// send_text_with_keyboard sends a plain-text message with an inline or reply keyboard.
// Build the keyboard with inline_keyboard_markup(), reply_keyboard_markup(), etc.
fn send_text_with_keyboard(s Session, mut td TDLib, chat_id i64, text string, markup json2.Any, opts SendOptions) !json2.Any {
	content := typed_obj('inputMessageText', {
		'text': plain_text(text)
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts, markup)
}

// send_html_with_keyboard sends an HTML-formatted message with an inline or reply keyboard.
fn send_html_with_keyboard(s Session, mut td TDLib, chat_id i64, html string, markup json2.Any, opts SendOptions) !json2.Any {
	formatted := html_text(html)!
	content := typed_obj('inputMessageText', {
		'text': formatted
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts, markup)
}

// send_markdown_with_keyboard sends a MarkdownV2-formatted message with an inline or reply keyboard.
fn send_markdown_with_keyboard(s Session, mut td TDLib, chat_id i64, md string, markup json2.Any, opts SendOptions) !json2.Any {
	formatted := markdown_text(md)!
	content := typed_obj('inputMessageText', {
		'text': formatted
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts, markup)
}

// --- Keyboard helpers ---

// InlineButton represents one button in an inline keyboard row.
//
// Type priority (first non-empty wins):
//   1. url                       -> URL button
//   2. switch_inline_query       -> switch inline mode in any chosen chat
//   3. switch_inline_current     -> switch inline mode in the current chat
//   4. callback_data             -> callback button (data is base64-encoded internally)
//
// For switch_inline buttons, use a single space ' ' to send an empty query (since ''
// means "field not set").  The space is automatically trimmed before sending.
pub struct InlineButton {
pub:
	text          string
	callback_data string // callback button; data is base64-encoded when sent to TDLib
	url           string // URL button - opens this URL when tapped
	// Switch-inline buttons open inline mode in a chat.
	// Set exactly one of these to make a switch_inline button.
	switch_inline_query   string // open inline mode in ANY chosen chat with this query
	switch_inline_current string // open inline mode in the CURRENT chat with this query
}

// inline_keyboard_markup builds a replyMarkupInlineKeyboard from a 2-D slice
// of InlineButton values.
//
//   markup := tdlib.inline_keyboard_markup([
//       [tdlib.InlineButton{ text: 'Yes', callback_data: 'yes' },
//        tdlib.InlineButton{ text: 'No',  callback_data: 'no'  }],
//       [tdlib.InlineButton{ text: 'Search', switch_inline_query: ' ' }],
//   ])
pub fn inline_keyboard_markup(rows [][]InlineButton) json2.Any {
	mut json_rows := []json2.Any{cap: rows.len}
	for row in rows {
		mut json_row := []json2.Any{cap: row.len}
		for btn in row {
			btn_type := if btn.url != '' {
				// Priority 1: URL button
				typed_obj('inlineKeyboardButtonTypeUrl', {
					'url': json2.Any(btn.url)
				})
			} else if btn.switch_inline_query != '' {
				// Priority 2: switch inline in any chosen chat.
				// Use ' ' (single space) as the query to trigger inline mode with an
				// empty query string; the space is trimmed before sending.
				//
				// BUG FIX: passing an empty map for targetChatChosen leaves all
				// allow_*_chats fields as false, so TDLib has no valid target chats
				// to show and the button silently does nothing.  Default to all-true.
				typed_obj('inlineKeyboardButtonTypeSwitchInline', {
					'query':       json2.Any(btn.switch_inline_query.trim(' '))
					'target_chat': typed_obj('targetChatChosen', {
						'allow_user_chats':    json2.Any(true)
						'allow_bot_chats':     json2.Any(true)
						'allow_group_chats':   json2.Any(true)
						'allow_channel_chats': json2.Any(true)
					})
				})
			} else if btn.switch_inline_current != '' {
				// Priority 3: switch inline in the CURRENT chat.
				typed_obj('inlineKeyboardButtonTypeSwitchInline', {
					'query':       json2.Any(btn.switch_inline_current.trim(' '))
					'target_chat': typed_obj('targetChatCurrent', map[string]json2.Any{})
				})
			} else {
				// Priority 4 (default): callback button.
				// BUG FIX: inlineKeyboardButtonTypeCallback.data is declared as `bytes`
				// in the TDLib schema.  The TDLib JSON API encodes all bytes fields as
				// base64 strings.  Sending the raw UTF-8 string caused TDLib to
				// base64-decode the literal text, so the payload received in
				// updateNewCallbackQuery.payload.data never matched the original string
				// after round-tripping through TDLib.
				typed_obj('inlineKeyboardButtonTypeCallback', {
					'data': json2.Any(base64.encode(btn.callback_data.bytes()))
				})
			}
			json_row << typed_obj('inlineKeyboardButton', {
				'text': json2.Any(btn.text)
				'type': btn_type
			})
		}
		json_rows << json2.Any(json_row)
	}
	return typed_obj('replyMarkupInlineKeyboard', {
		'rows': json2.Any(json_rows)
	})
}

// inline_keyboard_layout arranges a flat slice of InlineButton values into rows
// according to an explicit layout pattern.
//
// layout[i] is the number of buttons to place in row i.
// The sum of all layout values must equal buttons.len; returns an error otherwise.
//
//   btns := [btn_yes, btn_no, btn_cancel, btn_a, btn_b, btn_c]
//   markup := tdlib.inline_keyboard_layout(btns, [2, 1, 3])!
pub fn inline_keyboard_layout(buttons []InlineButton, layout []int) !json2.Any {
	mut total := 0
	for n in layout {
		if n <= 0 {
			return error('inline_keyboard_layout: each row count must be > 0, got ${n}')
		}
		total += n
	}
	if total != buttons.len {
		return error('inline_keyboard_layout: layout sum (${total}) != buttons.len (${buttons.len})')
	}
	mut rows := [][]InlineButton{cap: layout.len}
	mut idx := 0
	for n in layout {
		rows << buttons[idx..idx + n]
		idx += n
	}
	return inline_keyboard_markup(rows)
}

// inline_keyboard_auto arranges buttons into rows of exactly per_row each.
// The last row may have fewer buttons when buttons.len is not evenly divisible.
pub fn inline_keyboard_auto(buttons []InlineButton, per_row int) json2.Any {
	if per_row <= 0 || buttons.len == 0 {
		return inline_keyboard_markup([])
	}
	mut rows := [][]InlineButton{}
	mut i := 0
	for i < buttons.len {
		end := if i + per_row < buttons.len { i + per_row } else { buttons.len }
		rows << buttons[i..end]
		i = end
	}
	return inline_keyboard_markup(rows)
}

// --- Reply keyboards ---
//
// Reply keyboards show persistent buttons below the text input box.  Pressing a
// button sends its text as a regular message.  They differ from inline keyboards:
//
//   Inline keyboard  - buttons attached to a specific message; pressing one
//                      fires updateNewCallbackQuery, does NOT send a message.
//
//   Reply keyboard   - buttons shown below the text input box; pressing one
//                      SENDS the button's text as a normal user message.
//                      The bot/account receives it as a normal updateNewMessage.
//
// --- Usage ---
//
//   markup := tdlib.reply_keyboard_markup([
//       [tdlib.KeyboardButton{ text: 'Red'   },
//        tdlib.KeyboardButton{ text: 'Green' }],
//       [tdlib.KeyboardButton{ text: 'Location', request_location: true }],
//   ], tdlib.ReplyKeyboardOptions{ resize: true, one_time: true })
//   bot.send_text_reply_keyboard(chat_id, 'Pick a colour:', markup, tdlib.SendOptions{})!
//
//   // Remove the keyboard:
//   bot.send_text_reply_keyboard(chat_id, 'Done!', tdlib.remove_keyboard(false), tdlib.SendOptions{})!

// KeyboardButton is one cell in a reply keyboard row.
//
// Set exactly ONE of the boolean flags for special buttons; if all flags are
// false the button sends its text as a plain message when pressed.
pub struct KeyboardButton {
pub:
	// text is the label shown on the button and the text sent when pressed
	// (for plain buttons).
	text string

	// request_phone shows the native "Share phone number" system dialog.
	// The shared number is delivered as a contact message.
	request_phone bool

	// request_location shows the native location picker.
	// The chosen location is delivered as a location message.
	request_location bool
}

// ReplyKeyboardOptions controls the display behaviour of a reply keyboard.
pub struct ReplyKeyboardOptions {
pub:
	// resize shrinks the keyboard to its content height instead of always
	// occupying the same vertical space as the standard keyboard.
	// Recommended: true for most keyboards.
	resize bool

	// one_time hides the keyboard automatically after the user presses any
	// button.  The user can re-open it via the keyboard icon in the input bar.
	one_time bool

	// is_personal shows the keyboard only to the user who triggered the
	// message, rather than to everyone in the chat.
	is_personal bool

	// placeholder is the hint text shown in the text input field while the
	// keyboard is visible (max 64 characters).
	placeholder string
}

// reply_keyboard_markup builds a replyMarkupShowKeyboard object that can be
// passed to any send_*_keyboard or send_*_reply_keyboard method.
//
//   markup := tdlib.reply_keyboard_markup([
//       [tdlib.KeyboardButton{ text: 'Yes' }, tdlib.KeyboardButton{ text: 'No' }],
//       [tdlib.KeyboardButton{ text: 'Location', request_location: true }],
//   ], tdlib.ReplyKeyboardOptions{ resize: true, one_time: true })
pub fn reply_keyboard_markup(rows [][]KeyboardButton, opts ReplyKeyboardOptions) json2.Any {
	mut json_rows := []json2.Any{cap: rows.len}
	for row in rows {
		mut json_row := []json2.Any{cap: row.len}
		for btn in row {
			btn_type := if btn.request_phone {
				typed_obj('keyboardButtonTypeRequestPhoneNumber', map[string]json2.Any{})
			} else if btn.request_location {
				typed_obj('keyboardButtonTypeRequestLocation', map[string]json2.Any{})
			} else {
				// Plain text button: sends btn.text as a message when pressed.
				typed_obj('keyboardButtonTypeText', map[string]json2.Any{})
			}
			json_row << typed_obj('keyboardButton', {
				'text': json2.Any(btn.text)
				'type': btn_type
			})
		}
		json_rows << json2.Any(json_row)
	}
	mut fields := map[string]json2.Any{}
	fields['rows'] = json2.Any(json_rows)
	fields['resize_keyboard'] = json2.Any(opts.resize)
	fields['one_time_keyboard'] = json2.Any(opts.one_time)
	fields['is_personal'] = json2.Any(opts.is_personal)
	if opts.placeholder != '' {
		fields['input_field_placeholder'] = json2.Any(opts.placeholder)
	}
	return typed_obj('replyMarkupShowKeyboard', fields)
}

// reply_keyboard_layout arranges a flat list of KeyboardButton values into rows
// according to an explicit layout pattern, then builds the markup.
//
//   btns := [yes_btn, no_btn, maybe_btn, loc_btn]
//   markup := tdlib.reply_keyboard_layout(btns, [2, 1, 1],
//       tdlib.ReplyKeyboardOptions{ resize: true })!
pub fn reply_keyboard_layout(buttons []KeyboardButton, layout []int, opts ReplyKeyboardOptions) !json2.Any {
	mut total := 0
	for n in layout {
		if n <= 0 {
			return error('reply_keyboard_layout: each row count must be > 0, got ${n}')
		}
		total += n
	}
	if total != buttons.len {
		return error('reply_keyboard_layout: layout sum (${total}) != buttons.len (${buttons.len})')
	}
	mut rows := [][]KeyboardButton{cap: layout.len}
	mut idx := 0
	for n in layout {
		rows << buttons[idx..idx + n]
		idx += n
	}
	return reply_keyboard_markup(rows, opts)
}

// reply_keyboard_auto arranges a flat list of KeyboardButton values into rows
// of per_row buttons each (the last row may be shorter).
//
//   markup := tdlib.reply_keyboard_auto(buttons, 2, tdlib.ReplyKeyboardOptions{ resize: true })
pub fn reply_keyboard_auto(buttons []KeyboardButton, per_row int, opts ReplyKeyboardOptions) json2.Any {
	if per_row <= 0 || buttons.len == 0 {
		return reply_keyboard_markup([], opts)
	}
	mut rows := [][]KeyboardButton{}
	mut i := 0
	for i < buttons.len {
		end := if i + per_row < buttons.len { i + per_row } else { buttons.len }
		rows << buttons[i..end]
		i = end
	}
	return reply_keyboard_markup(rows, opts)
}

// remove_keyboard builds a replyMarkupRemoveKeyboard that hides the active
// reply keyboard for the chat.  Send it as the markup argument of any
// send_*_keyboard or send_*_reply_keyboard call alongside a normal message.
//
// is_personal: true removes the keyboard only for the current user (only
// meaningful inside groups).
pub fn remove_keyboard(is_personal bool) json2.Any {
	return typed_obj('replyMarkupRemoveKeyboard', {
		'is_personal': json2.Any(is_personal)
	})
}

// force_reply builds a replyMarkupForceReply that instructs supporting clients
// to enter reply mode immediately, as if the user had tapped "Reply" on the
// message.  Useful for step-by-step wizards.
//
// is_personal: show to only the target user when used in a group.
// placeholder: hint text in the input box ('' for none).
pub fn force_reply(is_personal bool, placeholder string) json2.Any {
	mut fields := map[string]json2.Any{}
	fields['is_personal'] = json2.Any(is_personal)
	if placeholder != '' {
		fields['input_field_placeholder'] = json2.Any(placeholder)
	}
	return typed_obj('replyMarkupForceReply', fields)
}

// --- Albums ---

// AlbumItem represents one photo or video in an album.
pub struct AlbumItem {
pub:
	content json2.Any
}

// album_photo creates an album item for a photo file.
pub fn album_photo(input_file json2.Any, caption string) AlbumItem {
	return AlbumItem{
		content: obj({
			'@type':   json2.Any('inputMessagePhoto')
			'photo':   input_file
			'caption': plain_text(caption)
		})
	}
}

// album_video creates an album item for a video file.
pub fn album_video(input_file json2.Any, caption string, duration int, width int, height int) AlbumItem {
	return AlbumItem{
		content: obj({
			'@type':    json2.Any('inputMessageVideo')
			'video':    input_file
			'caption':  plain_text(caption)
			'duration': json2.Any(duration)
			'width':    json2.Any(width)
			'height':   json2.Any(height)
		})
	}
}

fn send_album(s Session, mut td TDLib, chat_id i64, items []AlbumItem, opts SendOptions) !json2.Any {
	if items.len < 2 || items.len > 10 {
		return error('album must contain 2-10 items')
	}
	mut contents := []json2.Any{cap: items.len}
	for item in items {
		contents << item.content
	}
	mut req := new_request('sendMessageAlbum').with_i64('chat_id', chat_id).with('input_message_contents',
		json2.Any(contents))
	if opts.silent || opts.protect_content {
		req = req.with_obj('options', {
			'@type':                json2.Any('messageSendOptions')
			'disable_notification': json2.Any(opts.silent)
			'protect_content':      json2.Any(opts.protect_content)
		})
	}
	if opts.reply_to_message_id != 0 {
		req = req.with_obj('reply_to', {
			'@type':      json2.Any('inputMessageReplyToMessage')
			'chat_id':    json2.Any(chat_id)
			'message_id': json2.Any(opts.reply_to_message_id)
		})
	}
	return s.send_sync(mut td, req.build()!)
}

// --- Forwarding ---

fn forward_messages(s Session, mut td TDLib, to_chat_id i64, from_chat_id i64, message_ids []i64) !json2.Any {
	req := new_request('forwardMessages').with_i64('chat_id', to_chat_id).with_i64('from_chat_id',
		from_chat_id).with('message_ids', arr_of_i64(message_ids)).build()!
	return s.send_sync(mut td, req)
}

// --- Editing messages ---

fn edit_message_text(s Session, mut td TDLib, chat_id i64, message_id i64, text string) !json2.Any {
	req := new_request('editMessageText').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).with_obj('input_message_content', {
		'@type': json2.Any('inputMessageText')
		'text':  plain_text(text)
	}).build()!
	return s.send_sync(mut td, req)
}

// edit_message_html edits the text of an existing message using HTML formatting.
fn edit_message_html(s Session, mut td TDLib, chat_id i64, message_id i64, html string) !json2.Any {
	formatted := html_text(html)!
	req := new_request('editMessageText').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).with_obj('input_message_content', {
		'@type': json2.Any('inputMessageText')
		'text':  formatted
	}).build()!
	return s.send_sync(mut td, req)
}

// edit_message_markdown edits the text of an existing message using MarkdownV2 formatting.
fn edit_message_markdown(s Session, mut td TDLib, chat_id i64, message_id i64, md string) !json2.Any {
	formatted := markdown_text(md)!
	req := new_request('editMessageText').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).with_obj('input_message_content', {
		'@type': json2.Any('inputMessageText')
		'text':  formatted
	}).build()!
	return s.send_sync(mut td, req)
}

fn edit_message_caption(s Session, mut td TDLib, chat_id i64, message_id i64, caption string) !json2.Any {
	req := new_request('editMessageCaption').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).with('caption', plain_text(caption)).build()!
	return s.send_sync(mut td, req)
}

fn edit_message_reply_markup(s Session, mut td TDLib, chat_id i64, message_id i64, markup json2.Any) !json2.Any {
	req := new_request('editMessageReplyMarkup').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).with('reply_markup', markup).build()!
	return s.send_sync(mut td, req)
}

// --- Editing inline messages (sent via inline query) ---
//
// Messages created through inline queries are identified by a string
// inline_message_id instead of (chat_id, message_id).  Callbacks from
// these messages arrive in updateNewInlineCallbackQuery (not
// updateNewCallbackQuery), and they must be edited with the dedicated
// editInlineMessage* methods below.

// edit_inline_message_reply_markup replaces the inline keyboard on a message
// that was originally sent via an inline query.
// inline_message_id: the string from updateNewInlineCallbackQuery.inline_message_id.
fn edit_inline_message_reply_markup(s Session, mut td TDLib, inline_message_id string, markup json2.Any) !json2.Any {
	req := new_request('editInlineMessageReplyMarkup').with_str('inline_message_id', inline_message_id).with('reply_markup',
		markup).build()!
	return s.send_sync(mut td, req)
}

// edit_inline_message_text replaces the text content of a message that was
// originally sent via an inline query.
// inline_message_id: the string from updateNewInlineCallbackQuery.inline_message_id.
fn edit_inline_message_text(s Session, mut td TDLib, inline_message_id string, formatted json2.Any, markup json2.Any) !json2.Any {
	mut req := new_request('editInlineMessageText').with_str('inline_message_id', inline_message_id).with_obj('input_message_content',
		{
		'@type': json2.Any('inputMessageText')
		'text':  formatted
	})
	markup_m := markup.as_map()
	if markup_m.len > 0 {
		req = req.with('reply_markup', markup)
	}
	return s.send_sync(mut td, req.build()!)
}

// --- Live location editing ---

// edit_message_live_location pushes a new GPS position to an active live-location
// message.  Call repeatedly to keep the pin moving.
//
// heading:                direction of travel in degrees (1..360); 0 = not set.
// proximity_alert_radius: alert another user within this radius in metres
//                         (1..100000; 0 = disabled).
//
// BUG FIX: The location sub-object must carry @type:'location' like all
// TDLib sub-objects.  Using a plain map without @type caused TDLib to reject
// the request with a parameter error.
fn edit_message_live_location(s Session, mut td TDLib, chat_id i64, message_id i64, latitude f64, longitude f64, heading int, proximity_alert_radius int) !json2.Any {
	mut req := new_request('editMessageLiveLocation').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).with('location', typed_obj('location', {
		'latitude':  json2.Any(latitude)
		'longitude': json2.Any(longitude)
	}))
	if heading > 0 {
		req = req.with_int('heading', heading)
	}
	if proximity_alert_radius > 0 {
		req = req.with_int('proximity_alert_radius', proximity_alert_radius)
	}
	return s.send_sync(mut td, req.build()!)
}

// stop_message_live_location stops an active live-location message so that the
// pin is frozen at its last reported position.
//
// Per TDLib docs, live location is stopped by calling editMessageLiveLocation
// without a location field.
fn stop_message_live_location(s Session, mut td TDLib, chat_id i64, message_id i64) !json2.Any {
	req := new_request('editMessageLiveLocation').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).build()!
	return s.send_sync(mut td, req)
}

// --- Callback data helpers ---

// decode_callback_data decodes the base64-encoded callback data payload
// received in updateNewCallbackQuery.payload.data.
//
// Background: inline_keyboard_markup() base64-encodes the callback_data bytes
// before sending to TDLib because inlineKeyboardButtonTypeCallback.data is
// typed as `bytes` in the TDLib JSON schema.  Call this function inside a
// updateNewCallbackQuery handler to get back the original string:
//
//   bot.on('updateNewCallbackQuery', fn [mut bot] (upd json2.Any) {
//       m       := upd.as_map()
//       qid     := tdlib.map_i64(m, 'id')
//       payload := tdlib.map_obj(m, 'payload')
//       data    := tdlib.decode_callback_data(tdlib.map_str(payload, 'data'))
//       bot.answer_callback_query(qid, data, false, '', 0) or {}
//   })
pub fn decode_callback_data(data string) string {
	if data == '' {
		return ''
	}
	return base64.decode_str(data)
}

// --- Deleting messages ---

fn delete_messages(s Session, mut td TDLib, chat_id i64, message_ids []i64, revoke bool) !json2.Any {
	req := new_request('deleteMessages').with_i64('chat_id', chat_id).with('message_ids',
		arr_of_i64(message_ids)).with_bool('revoke', revoke).build()!
	return s.send_sync(mut td, req)
}

fn delete_album(s Session, mut td TDLib, chat_id i64, any_album_message_id i64, revoke bool) !json2.Any {
	req := new_request('getMessageAlbum').with_i64('chat_id', chat_id).with_i64('message_id',
		any_album_message_id).build()!
	resp := s.send_sync(mut td, req)!
	raw_msgs := map_arr(resp.as_map(), 'messages')
	mut ids := []i64{cap: raw_msgs.len}
	for rm in raw_msgs {
		ids << map_i64(rm.as_map(), 'id')
	}
	return delete_messages(s, mut td, chat_id, ids, revoke)
}

// --- Pinning ---

fn pin_message(s Session, mut td TDLib, chat_id i64, message_id i64, disable_notification bool) !json2.Any {
	req := new_request('pinChatMessage').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).with_bool('disable_notification', disable_notification).build()!
	return s.send_sync(mut td, req)
}

fn unpin_message(s Session, mut td TDLib, chat_id i64, message_id i64) !json2.Any {
	req := new_request('unpinChatMessage').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).build()!
	return s.send_sync(mut td, req)
}

// --- Chat actions (typing / upload indicators) ---

// send_chat_action broadcasts a chat action to show a status indicator to
// other participants.  Actions expire automatically after ~5 seconds; call
// repeatedly to keep the indicator alive while a long operation runs.
//
// Common action_type values (pass the @type string):
//   "chatActionTyping"              - typing a message
//   "chatActionRecordingVideo"      - recording a video
//   "chatActionUploadingVideo"      - uploading a video
//   "chatActionRecordingVoiceNote"  - recording a voice note
//   "chatActionUploadingVoiceNote"  - uploading a voice note
//   "chatActionUploadingPhoto"      - uploading a photo
//   "chatActionUploadingDocument"   - uploading a document
//   "chatActionChoosingSticker"     - choosing a sticker
//   "chatActionChoosingLocation"    - choosing a location
//   "chatActionChoosingContact"     - choosing a contact
//   "chatActionCancel"              - stop / cancel current action
fn send_chat_action(s Session, mut td TDLib, chat_id i64, action_type string) !json2.Any {
	req := new_request('sendChatAction').with_i64('chat_id', chat_id).with_obj('action',
		{
		'@type': json2.Any(action_type)
	}).build()!
	return s.send_sync(mut td, req)
}

// --- Message reactions ---

// add_message_reaction adds an emoji reaction to a message.
// emoji: reaction emoji string.
// is_big: true sends a "big" animated reaction with a notification.
// update_recent: true adds this emoji to the recent reactions list.
fn add_message_reaction(s Session, mut td TDLib, chat_id i64, message_id i64, emoji string, is_big bool, update_recent bool) !json2.Any {
	req := new_request('addMessageReaction').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).with('reaction_type', typed_obj('reactionTypeEmoji', {
		'emoji': json2.Any(emoji)
	})).with_bool('is_big', is_big).with_bool('update_recent_reactions', update_recent).build()!
	return s.send_sync(mut td, req)
}

// remove_message_reaction removes an emoji reaction previously added by the
// current user.
fn remove_message_reaction(s Session, mut td TDLib, chat_id i64, message_id i64, emoji string) !json2.Any {
	req := new_request('removeMessageReaction').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).with('reaction_type', typed_obj('reactionTypeEmoji', {
		'emoji': json2.Any(emoji)
	})).build()!
	return s.send_sync(mut td, req)
}

// --- File download ---

// download_file requests TDLib to download a file.
// priority: 1 (lowest) .. 32 (highest).
// Returns the initial TDFile state; register an 'updateFile' handler for progress.
fn download_file(s Session, mut td TDLib, file_id i64, priority int) !TDFile {
	clamped := if priority < 1 {
		1
	} else if priority > 32 {
		32
	} else {
		priority
	}
	req := new_request('downloadFile').with_i64('file_id', file_id).with_int('priority',
		clamped).with_int('offset', 0).with_int('limit', 0).with_bool('synchronous', false).build()!
	resp := s.send_sync(mut td, req)!
	return TDFile.from(resp.as_map())
}

fn cancel_download(s Session, mut td TDLib, file_id i64) !json2.Any {
	req := new_request('cancelDownloadFile').with_i64('file_id', file_id).with_bool('only_if_pending',
		false).build()!
	return s.send_sync(mut td, req)
}

// --- Proxy ---

fn add_socks5_proxy(s Session, mut td TDLib, server string, port int, username string, password string) !json2.Any {
	req := new_request('addProxy').with_str('server', server).with_int('port', port).with_bool('enable',
		true).with_obj('type', {
		'@type':    json2.Any('proxyTypeSocks5')
		'username': json2.Any(username)
		'password': json2.Any(password)
	}).build()!
	return s.send_sync(mut td, req)
}

fn add_http_proxy(s Session, mut td TDLib, server string, port int, username string, password string) !json2.Any {
	req := new_request('addProxy').with_str('server', server).with_int('port', port).with_bool('enable',
		true).with_obj('type', {
		'@type':    json2.Any('proxyTypeHttp')
		'username': json2.Any(username)
		'password': json2.Any(password)
	}).build()!
	return s.send_sync(mut td, req)
}

// --- Forwarding with markup ---

// forward_message_with_markup forwards a message AND re-attaches its inline
// keyboard to the forwarded copy in the destination chat.
//
// Background: TDLib's forwardMessages strips the reply_markup from the
// forwarded copy.  This function works around that by:
//   1. Fetching the original message to read its reply_markup.
//   2. Forwarding the message normally.
//   3. If the original had a reply_markup, patching the newly-created
//      forwarded message with editMessageReplyMarkup.
//
// Returns the final forwarded Message (with markup attached if applicable).
fn forward_message_with_markup(s Session, mut td TDLib, to_chat_id i64, from_chat_id i64, message_id i64) !Message {
	original := get_message(s, mut td, from_chat_id, message_id)!
	raw_markup := original.reply_markup_raw()

	// Forward the message; TDLib returns messages{ messages: [...] }.
	fwd_req := new_request('forwardMessages').with_i64('chat_id', to_chat_id).with_i64('from_chat_id',
		from_chat_id).with('message_ids', arr_of_i64([message_id])).build()!
	fwd_resp := s.send_sync(mut td, fwd_req)!
	raw_msgs := map_arr(fwd_resp.as_map(), 'messages')
	if raw_msgs.len == 0 {
		return error('forwardMessages returned no messages')
	}
	forwarded := Message.from(raw_msgs[0].as_map())

	// Re-attach the markup when the original had one.
	if raw_markup.as_map().len > 0 {
		edit_message_reply_markup(s, mut td, to_chat_id, forwarded.id(), raw_markup) or {}
	}
	return forwarded
}

// --- Internal dispatch helper ---

// dispatch_send_message assembles and sends a sendMessage request.
// markup is the reply_markup object; pass json2.Any(map[string]json2.Any{}) for none.
fn dispatch_send_message(s Session, mut td TDLib, chat_id i64, content json2.Any, opts SendOptions, markup json2.Any) !json2.Any {
	mut req := new_request('sendMessage').with_i64('chat_id', chat_id).with('input_message_content',
		content)
	if opts.silent || opts.protect_content {
		req = req.with_obj('options', {
			'@type':                json2.Any('messageSendOptions')
			'disable_notification': json2.Any(opts.silent)
			'protect_content':      json2.Any(opts.protect_content)
		})
	}
	if opts.reply_to_message_id != 0 {
		req = req.with_obj('reply_to', {
			'@type':      json2.Any('inputMessageReplyToMessage')
			'chat_id':    json2.Any(chat_id)
			'message_id': json2.Any(opts.reply_to_message_id)
		})
	}
	markup_m := markup.as_map()
	if markup_m.len > 0 {
		req = req.with('reply_markup', markup)
	}
	return s.send_sync(mut td, req.build()!)
}

// --- Global utility ---

// set_log_verbosity sets TDLib's internal log verbosity level.
// 0 = fatal only, 1 = errors, 2 = warnings, 3 = info, 4 = debug, 5 = verbose.
pub fn set_log_verbosity(level int) ! {
	req := new_request('setLogVerbosityLevel').with_int('new_verbosity_level', level).build()!
	execute(req)!
}
