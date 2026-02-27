// tdlib/botapi.v
// Bot-only TDLib API implementations.
//
// These functions are only meaningful for bot accounts:
//   - Bot command registration
//   - Bot profile management (name, description, photo)
//   - Inline query answering
//   - Callback query answering
//
// All functions follow the same pattern as common.v:
// module-level implementation that BotAccount delegates to.
module tdlib

import x.json2

// --- BotCommand type ---

// BotCommand represents one entry in the bot's command list.
// command must contain only lowercase letters, digits, and underscores,
// and must be 1-32 characters long.
// description must be 3-256 characters long.
pub struct BotCommand {
pub:
	command     string
	description string
}

// to_json converts a BotCommand to its TDLib JSON representation.
fn (c BotCommand) to_json() json2.Any {
	return typed_obj('botCommand', {
		'command':     json2.Any(c.command)
		'description': json2.Any(c.description)
	})
}

// --- Implementation ---

// bot_set_commands registers the list of commands shown in the Telegram UI.
// Pass an empty slice to remove all commands.
fn bot_set_commands(s Session, mut td TDLib, commands []BotCommand) !json2.Any {
	mut cmds := []json2.Any{cap: commands.len}
	for c in commands {
		cmds << c.to_json()
	}
	// BUG FIX: The previous implementation omitted the required scope and language_code
	// parameters.  TDLib's setCommands signature is:
	//   setCommands scope:BotCommandScope language_code:string commands:vector<botCommand>
	// scope must be a typed BotCommandScope object; pass botCommandScopeDefault for the
	// global default.  language_code '' means "applies to all languages".
	req := new_request('setCommands').with_obj('scope', {
		'@type': json2.Any('botCommandScopeDefault')
	}).with_str('language_code', '').with_arr('commands', cmds).build()!
	return s.send_sync(mut td, req)
}

// bot_get_commands returns the bot's currently registered commands.
fn bot_get_commands(s Session, mut td TDLib) ![]BotCommand {
	// BUG FIX: The previous implementation called 'getMyCommands', which does not exist
	// in TDLib.  The correct method is 'getCommands', and it requires scope and
	// language_code just like setCommands.
	req := new_request('getCommands').with_obj('scope', {
		'@type': json2.Any('botCommandScopeDefault')
	}).with_str('language_code', '').build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'commands')
	mut out := []BotCommand{cap: raw_arr.len}
	for item in raw_arr {
		m := item.as_map()
		out << BotCommand{
			command:     map_str(m, 'command')
			description: map_str(m, 'description')
		}
	}
	return out
}

// bot_set_name changes the bot's display name.
//
// BUG FIX: The previous implementation called 'setName', which is the method for
// changing a user account's first/last name and accepts first_name + last_name.
// The correct method for bots is 'setBotName', which requires:
//   bot_user_id: pass 0 to edit the current bot's own name.
//   name:        the new display name string.
//   language_code: '' to set the default name for all languages.
fn bot_set_name(s Session, mut td TDLib, name string) !json2.Any {
	req := new_request('setBotName').with_i64('bot_user_id', 0).with_str('name', name).with_str('language_code',
		'').build()!
	return s.send_sync(mut td, req)
}

// bot_set_description sets the bot's description (shown to users who have
// never started a chat with it).
//
// BUG FIX: The previous implementation omitted the required bot_user_id and
// language_code parameters. TDLib requires both even if they are zero/empty.
//   bot_user_id:   0 to edit the current bot's description.
//   language_code: '' to set the default description for all languages.
fn bot_set_description(s Session, mut td TDLib, description string) !json2.Any {
	req := new_request('setBotInfoDescription').with_i64('bot_user_id', 0).with_str('language_code',
		'').with_str('description', description).build()!
	return s.send_sync(mut td, req)
}

// bot_set_short_description sets the bot's short description (shown on the
// profile page and in share dialogs).
//
// BUG FIX: Same as bot_set_description - bot_user_id and language_code were
// missing from the previous implementation.
fn bot_set_short_description(s Session, mut td TDLib, short_description string) !json2.Any {
	req := new_request('setBotInfoShortDescription').with_i64('bot_user_id', 0).with_str('language_code',
		'').with_str('short_description', short_description).build()!
	return s.send_sync(mut td, req)
}

// bot_set_profile_photo uploads a new profile photo for the bot from a local file.
//
// BUG FIX: The previous implementation used '@type': 'inputChatPhotoLocal', which
// does not exist in TDLib. The correct type is 'inputChatPhotoStatic', which
// accepts a photo field of any InputFile type (inputFileLocal, inputFileId, etc.).
fn bot_set_profile_photo(s Session, mut td TDLib, local_path string) !json2.Any {
	req := new_request('setProfilePhoto').with_obj('photo', {
		'@type': json2.Any('inputChatPhotoStatic')
		'photo': input_local(local_path)
	}).build()!
	return s.send_sync(mut td, req)
}

// bot_answer_inline_query sends the answer to an inline query.
// inline_query_id: the id field from the updateNewInlineQuery update.
// results: slice of inputInlineQueryResult objects.
// cache_time: seconds TDLib may cache the response (0 = TDLib default of 300).
// is_personal: cache per-user rather than globally.
// next_offset: pass to client for the next page ('' = last page).
//
// BUG FIX: The previous implementation declared inline_query_id as string and used
// with_str().  TDLib defines inline_query_id as int64 in answerInlineQuery.
// Sending it as a JSON string caused TDLib to reject the call with a type error.
fn bot_answer_inline_query(s Session, mut td TDLib, inline_query_id i64, results []json2.Any, cache_time int, is_personal bool, next_offset string) !json2.Any {
	effective_cache := if cache_time < 0 { 0 } else { cache_time }
	req := new_request('answerInlineQuery').with_i64('inline_query_id', inline_query_id).with_bool('is_personal',
		is_personal).with_arr('results', results).with_int('cache_time', effective_cache).with_str('next_offset',
		next_offset).build()!
	return s.send_sync(mut td, req)
}

// bot_answer_callback_query sends a response to a callback query from an inline
// keyboard button press (updateNewCallbackQuery).
//
// callback_query_id: the id field from the updateNewCallbackQuery update.
// text:             notification text shown to the user; '' for a silent answer.
// show_alert:       if true, shows an alert dialog instead of a notification.
// url:              URL to open in the user's browser; '' for none.
// cache_time:       seconds to cache the answer on Telegram's servers (0 = default 0).
//
// Bots MUST answer every callback query within a few seconds or the button
// will show a "loading" spinner indefinitely on the client side.
fn bot_answer_callback_query(s Session, mut td TDLib, callback_query_id i64, text string, show_alert bool, url string, cache_time int) !json2.Any {
	req := new_request('answerCallbackQuery').with_i64('callback_query_id', callback_query_id).with_str('text',
		text).with_bool('show_alert', show_alert).with_str('url', url).with_int('cache_time',
		cache_time).build()!
	return s.send_sync(mut td, req)
}

// --- BotInfo ---

// BotInfo wraps the TDLib botInfo object returned by getBotInfo.
pub struct BotInfo {
pub:
	raw map[string]json2.Any
}

pub fn BotInfo.from(m map[string]json2.Any) BotInfo {
	return BotInfo{
		raw: m
	}
}

// name returns the bot's current display name.
pub fn (bi BotInfo) name() string {
	return map_str(bi.raw, 'name')
}

// description returns the long description shown to users who have never
// started a chat with the bot.
pub fn (bi BotInfo) description() string {
	return map_str(bi.raw, 'description')
}

// short_description returns the short description shown on the bot's
// profile page and in share dialogs.
pub fn (bi BotInfo) short_description() string {
	return map_str(bi.raw, 'short_description')
}

// bot_get_info returns the bot's current name, description, and short
// description.  Useful for verifying what Telegram has on record before
// deciding whether a set_* call is needed.
fn bot_get_info(s Session, mut td TDLib) !BotInfo {
	req := new_request('getBotInfo').with_i64('bot_user_id', 0).with_str('language_code',
		'').build()!
	resp := s.send_sync(mut td, req)!
	return BotInfo.from(resp.as_map())
}

// --- Bot menu button ---

// bot_set_menu_button sets a Web App button in the chat input area for a
// specific user (user_id) or for all users (user_id = 0).
//
// The button appears next to the attachment icon in private chats and opens
// the given URL in Telegram's in-app browser when tapped.
//
// text: button label (shown on the button, e.g. "Open App").
// url:  full HTTPS URL of the Web App to open.
fn bot_set_menu_button(s Session, mut td TDLib, user_id i64, text string, url string) !json2.Any {
	req := new_request('setBotMenuButton').with_i64('user_id', user_id).with_obj('menu_button',
		{
		'@type': json2.Any('botMenuButtonWebApp')
		'text':  json2.Any(text)
		'url':   json2.Any(url)
	}).build()!
	return s.send_sync(mut td, req)
}

// bot_reset_menu_button resets the menu button for a specific user (or all
// users if user_id = 0) back to the default keyboard commands button.
// Use this to remove a previously set Web App button.
fn bot_reset_menu_button(s Session, mut td TDLib, user_id i64) !json2.Any {
	req := new_request('setBotMenuButton').with_i64('user_id', user_id).with_obj('menu_button',
		{
		'@type': json2.Any('botMenuButtonDefault')
	}).build()!
	return s.send_sync(mut td, req)
}
