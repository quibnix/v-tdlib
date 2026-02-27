// tdlib/schedule.v
// Scheduled message support.
//
// Scheduled messages are stored in TDLib and delivered to the recipient at a
// specified Unix timestamp.  They appear in a separate "Scheduled Messages"
// list inside the chat until they are sent or deleted.
//
// --- Sending a scheduled message ---
//
//   // Schedule a plain-text message to go out in one hour.
//   send_date := tdlib.unix_now() + 3600
//   user.send_scheduled_text(chat_id, 'See you in an hour!', send_date, tdlib.SendOptions{})!
//
//   // Schedule HTML-formatted text.
//   user.send_scheduled_html(chat_id, '<b>Reminder</b>', send_date, tdlib.SendOptions{})!
//
// --- Listing and managing scheduled messages ---
//
//   msgs := user.get_scheduled_messages(chat_id)!
//   for m in msgs {
//       println('Scheduled: ${m.text()}')
//   }
//
//   // Deliver the first scheduled message immediately.
//   user.send_scheduled_message_now(chat_id, msgs[0].id())!
//
//   // Cancel / delete a scheduled message without sending it.
//   user.delete_scheduled_messages(chat_id, [msgs[0].id()])!
//
// Scheduled messages are fully supported on both UserAccount and BotAccount.
module tdlib

import x.json2

// --- Internal helpers ---

// scheduled_send_options builds a messageSendOptions object that includes a
// messageSchedulingStateSendAtDate so the message is held until send_date.
fn scheduled_send_options(send_date i64, silent bool, protect_content bool) json2.Any {
	return typed_obj('messageSendOptions', {
		'disable_notification': json2.Any(silent)
		'protect_content':      json2.Any(protect_content)
		'scheduling_state':     typed_obj('messageSchedulingStateSendAtDate', {
			'send_date': json2.Any(send_date)
		})
	})
}

// dispatch_send_scheduled is the internal helper shared by all scheduled send
// functions.  It works exactly like dispatch_send_message but always injects
// the scheduling_state.
fn dispatch_send_scheduled(s Session, mut td TDLib, chat_id i64, content json2.Any, send_date i64, opts SendOptions, markup json2.Any) !json2.Any {
	mut req := new_request('sendMessage').with_i64('chat_id', chat_id).with('input_message_content',
		content).with('options', scheduled_send_options(send_date, opts.silent, opts.protect_content))
	if opts.message_thread_id != 0 {
		req = req.with_i64('message_thread_id', opts.message_thread_id)
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

// --- Scheduled send functions ---

// send_scheduled_text schedules a plain-text message for delivery at send_date.
// send_date is a Unix timestamp (seconds since epoch).
fn send_scheduled_text(s Session, mut td TDLib, chat_id i64, text string, send_date i64, opts SendOptions) !json2.Any {
	content := typed_obj('inputMessageText', {
		'text': plain_text(text)
	})
	return dispatch_send_scheduled(s, mut td, chat_id, content, send_date, opts, json2.Any(map[string]json2.Any{}))
}

// send_scheduled_html schedules an HTML-formatted message for delivery at send_date.
fn send_scheduled_html(s Session, mut td TDLib, chat_id i64, html string, send_date i64, opts SendOptions) !json2.Any {
	formatted := html_text(html)!
	content := typed_obj('inputMessageText', {
		'text': formatted
	})
	return dispatch_send_scheduled(s, mut td, chat_id, content, send_date, opts, json2.Any(map[string]json2.Any{}))
}

// send_scheduled_markdown schedules a MarkdownV2-formatted message for delivery at send_date.
fn send_scheduled_markdown(s Session, mut td TDLib, chat_id i64, md string, send_date i64, opts SendOptions) !json2.Any {
	formatted := markdown_text(md)!
	content := typed_obj('inputMessageText', {
		'text': formatted
	})
	return dispatch_send_scheduled(s, mut td, chat_id, content, send_date, opts, json2.Any(map[string]json2.Any{}))
}

// send_scheduled_photo schedules a photo message for delivery at send_date.
fn send_scheduled_photo(s Session, mut td TDLib, chat_id i64, input_file json2.Any, caption string, send_date i64, opts SendOptions) !json2.Any {
	content := obj({
		'@type':   json2.Any('inputMessagePhoto')
		'photo':   input_file
		'caption': plain_text(caption)
	})
	return dispatch_send_scheduled(s, mut td, chat_id, content, send_date, opts, json2.Any(map[string]json2.Any{}))
}

// send_scheduled_document schedules a document message for delivery at send_date.
fn send_scheduled_document(s Session, mut td TDLib, chat_id i64, input_file json2.Any, caption string, send_date i64, opts SendOptions) !json2.Any {
	content := obj({
		'@type':    json2.Any('inputMessageDocument')
		'document': input_file
		'caption':  plain_text(caption)
	})
	return dispatch_send_scheduled(s, mut td, chat_id, content, send_date, opts, json2.Any(map[string]json2.Any{}))
}

// --- Retrieval and control ---

// get_scheduled_messages returns all pending scheduled messages for a chat,
// ordered by scheduled send time (earliest first).
fn get_scheduled_messages(s Session, mut td TDLib, chat_id i64) ![]Message {
	req := new_request('getChatScheduledMessages').with_i64('chat_id', chat_id).build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'messages')
	mut out := []Message{cap: raw_arr.len}
	for rm in raw_arr {
		out << Message.from(rm.as_map())
	}
	return out
}

// send_scheduled_message_now delivers a single scheduled message immediately
// regardless of its send_date.
// message_id must be an ID from get_scheduled_messages().
fn send_scheduled_message_now(s Session, mut td TDLib, chat_id i64, message_id i64) !json2.Any {
	req := new_request('sendScheduledMessages').with_i64('chat_id', chat_id).with('message_ids',
		arr_of_i64([message_id])).build()!
	return s.send_sync(mut td, req)
}

// send_all_scheduled_now delivers every pending scheduled message in a chat
// immediately.  Returns after all messages have been dispatched.
fn send_all_scheduled_now(s Session, mut td TDLib, chat_id i64) ! {
	msgs := get_scheduled_messages(s, mut td, chat_id)!
	if msgs.len == 0 {
		return
	}
	mut ids := []i64{cap: msgs.len}
	for m in msgs {
		ids << m.id()
	}
	req := new_request('sendScheduledMessages').with_i64('chat_id', chat_id).with('message_ids',
		arr_of_i64(ids)).build()!
	s.send_sync(mut td, req)!
}

// delete_scheduled_messages cancels and deletes one or more scheduled messages
// without sending them.
// message_ids must come from get_scheduled_messages().
fn delete_scheduled_messages(s Session, mut td TDLib, chat_id i64, message_ids []i64) !json2.Any {
	req := new_request('deleteMessages').with_i64('chat_id', chat_id).with('message_ids',
		arr_of_i64(message_ids)).with_bool('revoke', false).build()!
	return s.send_sync(mut td, req)
}
