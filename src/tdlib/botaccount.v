// tdlib/botaccount.v
// BotAccount: a Telegram bot authenticated with a bot token.
//
// Bots can only operate in chats they have been added to.  The full
// Telegram Bot API is available:
//   - Send and receive messages in chats
//   - Answer inline queries
//   - Answer callback queries from inline keyboard buttons
//   - Set bot commands, name, description, and profile photo
//   - Moderate groups (ban, kick, restrict, pin, etc.)
//   - Download files accessible to the bot
//   - Retrieve extended user info via get_user_full_info()
//   - Retrieve extended supergroup/channel info via get_supergroup_full_info()
//   - Browse chat profile photo history with get_chat_photo_history()
//
// BotAccount is fundamentally different from UserAccount: bots cannot
// access arbitrary chats, join chats via invite link, or read message
// history outside their own exchanges.
//
// Methods intentionally NOT present on BotAccount (user-client only):
//   - get_chats / get_chat_history     (bots have no "chat list" and no history access)
//   - join_chat_by_invite_link         (bots are added by admins, not invite links)
//   - set_poll_answer                  (bots cannot vote in polls; TDLib user-only)
//   - view_messages                    (read receipts are a client concept, not bot)
//   - delete_profile_photo             (bots use set_profile_photo exclusively)
//   - set_name / set_bio / set_username (personal profile; bots use setBotName etc.)
//   - chat folder management           (bots have no chat list or folder concept)
module tdlib

import x.json2

// BotAccount represents a Telegram bot logged in with a bot token.
pub struct BotAccount {
pub mut:
	session Session
	td      &TDLib
}

// --- Constructors ---

// BotAccount.new creates a BotAccount with its own private TDLib hub.
// Use AccountManager.add_bot() when managing multiple accounts.
pub fn BotAccount.new() !&BotAccount {
	mut td := new()
	session := td.create_session()
	return &BotAccount{
		session: session
		td:      td
	}
}

// BotAccount.new_shared creates a BotAccount sharing an existing TDLib hub.
// Used internally by AccountManager.
pub fn BotAccount.new_shared(mut td TDLib) &BotAccount {
	session := td.create_session()
	return &BotAccount{
		session: session
		td:      td
	}
}

// --- Lifecycle ---

// setup sends setTdlibParameters. Must be called once before login().
// Proxy calls (add_socks5_proxy / add_http_proxy) must also come after setup().
pub fn (mut b BotAccount) setup(api_id int, api_hash string, data_dir string) !json2.Any {
	return setup_parameters(b.session, mut *b.td, api_id, api_hash, data_dir)
}

// login runs the bot-token authentication flow.
// Blocks until authorizationStateReady or an error.
pub fn (mut b BotAccount) login(token string) ! {
	run_bot_auth(b.session, mut *b.td, token)!
}

// login_custom runs the bot-token authentication flow using a caller-supplied
// callback instead of a hard-coded token string.  This is useful for reading
// the token from an environment variable, a secrets manager, or a config file
// at runtime rather than embedding it in source code.
//
//   handler := tdlib.BotLoginHandler{
//       get_token: fn() string { return os.getenv('BOT_TOKEN') }
//   }
//   bot.login_custom(handler)!
pub fn (mut b BotAccount) login_custom(handler BotLoginHandler) ! {
	run_bot_auth_with_handler(b.session, mut *b.td, handler)!
}

// shutdown stops the private TDLib hub.
// Call only when this BotAccount owns its own hub (created with BotAccount.new()).
// For shared-hub accounts, call AccountManager.shutdown() instead.
pub fn (mut b BotAccount) shutdown() {
	b.td.shutdown()
}

// --- Update handlers ---

// on registers a handler for a specific TDLib @type on this account.
// The handler is called in a new goroutine per update so it can safely
// call any synchronous API method (send_text, download, etc.).
//
//   bot.on('updateNewMessage', fn [mut bot] (upd json2.Any) {
//       msg := tdlib.Message.from(tdlib.map_obj(upd.as_map(), 'message'))
//       if !msg.is_outgoing() {
//           bot.send_text(msg.chat_id(), 'Hello!') or {}
//       }
//   })
pub fn (mut b BotAccount) on(typ string, handler Handler) {
	b.td.on(b.session.id, typ, handler)
}

// off removes a previously registered handler for this account.
pub fn (mut b BotAccount) off(typ string) {
	b.td.off(b.session.id, typ)
}

// get_update blocks until an update with no registered handler arrives
// for this account. Useful during auth and for custom manual polling loops.
pub fn (mut b BotAccount) get_update() json2.Any {
	return b.td.get_update(b.session.id)
}

// --- Identity ---

pub fn (mut b BotAccount) get_me() !User {
	return get_me(b.session, mut *b.td)
}

pub fn (mut b BotAccount) get_user(user_id i64) !User {
	return get_user(b.session, mut *b.td, user_id)
}

pub fn (mut b BotAccount) get_chat(chat_id i64) !Chat {
	return get_chat(b.session, mut *b.td, chat_id)
}

pub fn (mut b BotAccount) get_message(chat_id i64, message_id i64) !Message {
	return get_message(b.session, mut *b.td, chat_id, message_id)
}

// --- Proxy ---

// add_socks5_proxy adds a SOCKS5 proxy and enables it.
// Must be called after setup(). Returns the proxy object from TDLib.
pub fn (mut b BotAccount) add_socks5_proxy(server string, port int, username string, password string) !json2.Any {
	return add_socks5_proxy(b.session, mut *b.td, server, port, username, password)
}

// add_http_proxy adds an HTTP proxy and enables it.
// Must be called after setup(). Returns the proxy object from TDLib.
pub fn (mut b BotAccount) add_http_proxy(server string, port int, username string, password string) !json2.Any {
	return add_http_proxy(b.session, mut *b.td, server, port, username, password)
}

// --- Sending text messages ---

pub fn (mut b BotAccount) send_text(chat_id i64, text string) !json2.Any {
	return send_text_message(b.session, mut *b.td, chat_id, text, SendOptions{})
}

pub fn (mut b BotAccount) send_text_opts(chat_id i64, text string, opts SendOptions) !json2.Any {
	return send_text_message(b.session, mut *b.td, chat_id, text, opts)
}

pub fn (mut b BotAccount) send_html(chat_id i64, html string) !json2.Any {
	return send_html_message(b.session, mut *b.td, chat_id, html, SendOptions{})
}

pub fn (mut b BotAccount) send_html_opts(chat_id i64, html string, opts SendOptions) !json2.Any {
	return send_html_message(b.session, mut *b.td, chat_id, html, opts)
}

pub fn (mut b BotAccount) send_markdown(chat_id i64, md string) !json2.Any {
	return send_markdown_message(b.session, mut *b.td, chat_id, md, SendOptions{})
}

pub fn (mut b BotAccount) send_markdown_opts(chat_id i64, md string, opts SendOptions) !json2.Any {
	return send_markdown_message(b.session, mut *b.td, chat_id, md, opts)
}

// reply_text replies to a specific message with plain text.
pub fn (mut b BotAccount) reply_text(chat_id i64, reply_to_id i64, text string) !json2.Any {
	return send_text_message(b.session, mut *b.td, chat_id, text, SendOptions{
		reply_to_message_id: reply_to_id
	})
}

// reply_html replies to a specific message with HTML-formatted text.
// Equivalent to send_html_opts with reply_to_message_id set.
pub fn (mut b BotAccount) reply_html(chat_id i64, reply_to_id i64, html string) !json2.Any {
	return send_html_message(b.session, mut *b.td, chat_id, html, SendOptions{
		reply_to_message_id: reply_to_id
	})
}

// reply_markdown replies to a specific message with MarkdownV2-formatted text.
pub fn (mut b BotAccount) reply_markdown(chat_id i64, reply_to_id i64, md string) !json2.Any {
	return send_markdown_message(b.session, mut *b.td, chat_id, md, SendOptions{
		reply_to_message_id: reply_to_id
	})
}

// send_text_keyboard sends plain text with an inline keyboard attached.
pub fn (mut b BotAccount) send_text_keyboard(chat_id i64, text string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_text_with_keyboard(b.session, mut *b.td, chat_id, text, markup, opts)
}

// send_html_keyboard sends HTML-formatted text with an inline keyboard in one call.
// Combines html_text() parsing and the reply_markup in a single sendMessage.
pub fn (mut b BotAccount) send_html_keyboard(chat_id i64, html string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_html_with_keyboard(b.session, mut *b.td, chat_id, html, markup, opts)
}

// send_markdown_keyboard sends MarkdownV2-formatted text with an inline keyboard.
pub fn (mut b BotAccount) send_markdown_keyboard(chat_id i64, md string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_markdown_with_keyboard(b.session, mut *b.td, chat_id, md, markup, opts)
}

// --- Sending media ---

pub fn (mut b BotAccount) send_photo(chat_id i64, input_file json2.Any, opts PhotoSendOptions) !json2.Any {
	return send_photo(b.session, mut *b.td, chat_id, input_file, opts)
}

pub fn (mut b BotAccount) send_video(chat_id i64, input_file json2.Any, opts VideoSendOptions) !json2.Any {
	return send_video(b.session, mut *b.td, chat_id, input_file, opts)
}

pub fn (mut b BotAccount) send_audio(chat_id i64, input_file json2.Any, opts AudioSendOptions) !json2.Any {
	return send_audio(b.session, mut *b.td, chat_id, input_file, opts)
}

pub fn (mut b BotAccount) send_voice_note(chat_id i64, input_file json2.Any, opts VoiceSendOptions) !json2.Any {
	return send_voice_note(b.session, mut *b.td, chat_id, input_file, opts)
}

pub fn (mut b BotAccount) send_video_note(chat_id i64, input_file json2.Any, opts VideoNoteSendOptions) !json2.Any {
	return send_video_note(b.session, mut *b.td, chat_id, input_file, opts)
}

pub fn (mut b BotAccount) send_document(chat_id i64, input_file json2.Any, opts DocumentSendOptions) !json2.Any {
	return send_document(b.session, mut *b.td, chat_id, input_file, opts)
}

// send_animation sends an animation file (GIF or H.264/MPEG-4 AVC without sound).
// Use input_local(), input_id(), or input_remote() to specify the file.
pub fn (mut b BotAccount) send_animation(chat_id i64, input_file json2.Any, opts AnimationSendOptions) !json2.Any {
	return send_animation(b.session, mut *b.td, chat_id, input_file, opts)
}

pub fn (mut b BotAccount) send_location(chat_id i64, latitude f64, longitude f64) !json2.Any {
	return send_location(b.session, mut *b.td, chat_id, latitude, longitude, SendOptions{})
}

pub fn (mut b BotAccount) send_location_opts(chat_id i64, latitude f64, longitude f64, opts SendOptions) !json2.Any {
	return send_location(b.session, mut *b.td, chat_id, latitude, longitude, opts)
}

// send_live_location sends a live location message.
// The map pin updates in real-time in Telegram clients while the live period is active.
// Use edit_live_location() to push position updates.
pub fn (mut b BotAccount) send_live_location(chat_id i64, latitude f64, longitude f64, opts LiveLocationOptions) !json2.Any {
	return send_live_location(b.session, mut *b.td, chat_id, latitude, longitude, opts)
}

// edit_live_location pushes a new GPS position to an active live-location message.
// heading: direction of travel in degrees (1..360), or 0 to omit.
// proximity_alert_radius: alert radius in metres (1..100000), or 0 to omit.
pub fn (mut b BotAccount) edit_live_location(chat_id i64, message_id i64, latitude f64, longitude f64, heading int, proximity_alert_radius int) !json2.Any {
	return edit_message_live_location(b.session, mut *b.td, chat_id, message_id, latitude,
		longitude, heading, proximity_alert_radius)
}

// stop_live_location stops an active live-location message, freezing the pin at
// its last position.  Equivalent to calling editMessageLiveLocation without a
// location field.
pub fn (mut b BotAccount) stop_live_location(chat_id i64, message_id i64) !json2.Any {
	return stop_message_live_location(b.session, mut *b.td, chat_id, message_id)
}

// send_venue sends a venue (named location with address).
// Displayed with a map pin, title, and address in Telegram clients.
// Set provider='' and provider_id='' for a plain venue without a map provider link.
pub fn (mut b BotAccount) send_venue(chat_id i64, latitude f64, longitude f64, title string, address string, provider string, provider_id string, opts VenueOptions) !json2.Any {
	return send_venue(b.session, mut *b.td, chat_id, latitude, longitude, title, address,
		provider, provider_id, opts)
}

pub fn (mut b BotAccount) send_album(chat_id i64, items []AlbumItem, opts SendOptions) !json2.Any {
	return send_album(b.session, mut *b.td, chat_id, items, opts)
}

// --- Chat action ---

// send_chat_action broadcasts a typing/upload indicator to other participants.
// See common.v send_chat_action for available action_type strings.
pub fn (mut b BotAccount) send_chat_action(chat_id i64, action_type string) !json2.Any {
	return send_chat_action(b.session, mut *b.td, chat_id, action_type)
}

// --- Message reactions ---

// add_message_reaction adds an emoji reaction to a message.
pub fn (mut b BotAccount) add_message_reaction(chat_id i64, message_id i64, emoji string, is_big bool) !json2.Any {
	return add_message_reaction(b.session, mut *b.td, chat_id, message_id, emoji, is_big,
		true)
}

// remove_message_reaction removes a previously set emoji reaction.
pub fn (mut b BotAccount) remove_message_reaction(chat_id i64, message_id i64, emoji string) !json2.Any {
	return remove_message_reaction(b.session, mut *b.td, chat_id, message_id, emoji)
}

// --- Forwarding ---

pub fn (mut b BotAccount) forward_messages(to_chat_id i64, from_chat_id i64, message_ids []i64) !json2.Any {
	return forward_messages(b.session, mut *b.td, to_chat_id, from_chat_id, message_ids)
}

// forward_message_with_markup forwards a single message to another chat and
// re-attaches its inline keyboard to the forwarded copy.
// TDLib normally strips reply_markup from forwarded messages; this function
// patches the forwarded copy with editMessageReplyMarkup automatically.
pub fn (mut b BotAccount) forward_message_with_markup(to_chat_id i64, from_chat_id i64, message_id i64) !Message {
	return forward_message_with_markup(b.session, mut *b.td, to_chat_id, from_chat_id,
		message_id)
}

// --- Editing ---

pub fn (mut b BotAccount) edit_text(chat_id i64, message_id i64, text string) !json2.Any {
	return edit_message_text(b.session, mut *b.td, chat_id, message_id, text)
}

// edit_html edits the text of an existing message using HTML formatting.
pub fn (mut b BotAccount) edit_html(chat_id i64, message_id i64, html string) !json2.Any {
	return edit_message_html(b.session, mut *b.td, chat_id, message_id, html)
}

// edit_markdown edits the text of an existing message using MarkdownV2 formatting.
pub fn (mut b BotAccount) edit_markdown(chat_id i64, message_id i64, md string) !json2.Any {
	return edit_message_markdown(b.session, mut *b.td, chat_id, message_id, md)
}

pub fn (mut b BotAccount) edit_caption(chat_id i64, message_id i64, caption string) !json2.Any {
	return edit_message_caption(b.session, mut *b.td, chat_id, message_id, caption)
}

pub fn (mut b BotAccount) edit_reply_markup(chat_id i64, message_id i64, markup json2.Any) !json2.Any {
	return edit_message_reply_markup(b.session, mut *b.td, chat_id, message_id, markup)
}

// --- Editing inline messages (sent via inline query) ---
//
// Messages posted through @bot inline queries fire updateNewInlineCallbackQuery
// (not updateNewCallbackQuery) and are edited with these methods.
// inline_message_id comes from the update's 'inline_message_id' field (string).

// edit_inline_markup replaces the keyboard on an inline-query message.
pub fn (mut b BotAccount) edit_inline_markup(inline_message_id string, markup json2.Any) !json2.Any {
	return edit_inline_message_reply_markup(b.session, mut *b.td, inline_message_id, markup)
}

// edit_inline_text replaces the text (and optionally the keyboard) on an
// inline-query message using HTML formatting.
pub fn (mut b BotAccount) edit_inline_text(inline_message_id string, html string, markup json2.Any) !json2.Any {
	formatted := html_text(html)!
	return edit_inline_message_text(b.session, mut *b.td, inline_message_id, formatted,
		markup)
}

// edit_inline_text_plain replaces the text of an inline-query message with
// plain unformatted text (and optionally replaces the keyboard).
pub fn (mut b BotAccount) edit_inline_text_plain(inline_message_id string, text string, markup json2.Any) !json2.Any {
	return edit_inline_message_text(b.session, mut *b.td, inline_message_id, plain_text(text),
		markup)
}

// edit_inline_text_markdown replaces the text of an inline-query message with
// MarkdownV2-formatted text (and optionally replaces the keyboard).
pub fn (mut b BotAccount) edit_inline_text_markdown(inline_message_id string, md string, markup json2.Any) !json2.Any {
	formatted := markdown_text(md)!
	return edit_inline_message_text(b.session, mut *b.td, inline_message_id, formatted,
		markup)
}

// --- Deleting messages ---

// delete deletes specific messages. revoke=true deletes for all participants.
pub fn (mut b BotAccount) delete(chat_id i64, message_ids []i64, revoke bool) !json2.Any {
	return delete_messages(b.session, mut *b.td, chat_id, message_ids, revoke)
}

// delete_album deletes all messages in an album identified by any one member's ID.
pub fn (mut b BotAccount) delete_album(chat_id i64, any_album_message_id i64, revoke bool) !json2.Any {
	return delete_album(b.session, mut *b.td, chat_id, any_album_message_id, revoke)
}

// --- Pinning ---

pub fn (mut b BotAccount) pin_message(chat_id i64, message_id i64, silent bool) !json2.Any {
	return pin_message(b.session, mut *b.td, chat_id, message_id, silent)
}

pub fn (mut b BotAccount) unpin_message(chat_id i64, message_id i64) !json2.Any {
	return unpin_message(b.session, mut *b.td, chat_id, message_id)
}

// --- File download ---

// download starts downloading a file. Register an 'updateFile' handler to
// track progress; the handler receives TDFile updates with downloaded_size/size.
pub fn (mut b BotAccount) download(file_id i64, priority int) !TDFile {
	return download_file(b.session, mut *b.td, file_id, priority)
}

pub fn (mut b BotAccount) cancel_download(file_id i64) !json2.Any {
	return cancel_download(b.session, mut *b.td, file_id)
}

// get_file returns current file metadata (local path, size, etc.) by file ID.
pub fn (mut b BotAccount) get_file(file_id i64) !TDFile {
	return get_file(b.session, mut *b.td, file_id)
}

// --- Moderation ---

pub fn (mut b BotAccount) ban_chat_member(chat_id i64, user_id i64, revoke_messages bool) !json2.Any {
	return ban_chat_member(b.session, mut *b.td, chat_id, user_id, revoke_messages)
}

pub fn (mut b BotAccount) unban_chat_member(chat_id i64, user_id i64) !json2.Any {
	return unban_chat_member(b.session, mut *b.td, chat_id, user_id)
}

pub fn (mut b BotAccount) kick_chat_member(chat_id i64, user_id i64) !json2.Any {
	return kick_chat_member(b.session, mut *b.td, chat_id, user_id)
}

pub fn (mut b BotAccount) restrict_chat_member(chat_id i64, user_id i64, permissions ChatPermissions, until_date i64) !json2.Any {
	return restrict_chat_member(b.session, mut *b.td, chat_id, user_id, permissions, until_date)
}

// --- Chat member queries ---

pub fn (mut b BotAccount) get_chat_administrators(chat_id i64) ![]ChatMember {
	return get_chat_administrators(b.session, mut *b.td, chat_id)
}

pub fn (mut b BotAccount) get_chat_member_count(chat_id i64) !int {
	return get_chat_member_count(b.session, mut *b.td, chat_id)
}

// get_chat_member returns the membership status of user_id in chat_id.
pub fn (mut b BotAccount) get_chat_member(chat_id i64, user_id i64) !ChatMember {
	return get_chat_member(b.session, mut *b.td, chat_id, user_id)
}

// get_supergroup_members returns members of a supergroup or channel.
// Use Chat.supergroup_id() to get the supergroup_id from a Chat object.
pub fn (mut b BotAccount) get_supergroup_members(supergroup_id i64, filter SupergroupMembersFilter, offset int, limit int) ![]ChatMember {
	return get_supergroup_members(b.session, mut *b.td, supergroup_id, filter, offset,
		limit)
}

// --- Chat management ---

pub fn (mut b BotAccount) set_chat_title(chat_id i64, title string) !json2.Any {
	return set_chat_title(b.session, mut *b.td, chat_id, title)
}

pub fn (mut b BotAccount) set_chat_description(chat_id i64, description string) !json2.Any {
	return set_chat_description(b.session, mut *b.td, chat_id, description)
}

pub fn (mut b BotAccount) set_chat_photo(chat_id i64, local_path string) !json2.Any {
	return set_chat_photo(b.session, mut *b.td, chat_id, local_path)
}

pub fn (mut b BotAccount) delete_chat_photo(chat_id i64) !json2.Any {
	return delete_chat_photo(b.session, mut *b.td, chat_id)
}

pub fn (mut b BotAccount) leave_chat(chat_id i64) !json2.Any {
	return leave_chat(b.session, mut *b.td, chat_id)
}

// --- Invite links ---

pub fn (mut b BotAccount) create_chat_invite_link(chat_id i64, expire_date i64, member_limit int) !string {
	return create_chat_invite_link(b.session, mut *b.td, chat_id, expire_date, member_limit)
}

// --- Extra content ---

pub fn (mut b BotAccount) send_contact(chat_id i64, phone string, first_name string, last_name string) !json2.Any {
	return send_contact(b.session, mut *b.td, chat_id, phone, first_name, last_name, SendOptions{})
}

pub fn (mut b BotAccount) send_contact_opts(chat_id i64, phone string, first_name string, last_name string, opts SendOptions) !json2.Any {
	return send_contact(b.session, mut *b.td, chat_id, phone, first_name, last_name, opts)
}

pub fn (mut b BotAccount) send_sticker(chat_id i64, input_file json2.Any) !json2.Any {
	return send_sticker(b.session, mut *b.td, chat_id, input_file, StickerSendOptions{})
}

// send_sticker_opts sends a sticker with full send options (silent, protect, reply).
pub fn (mut b BotAccount) send_sticker_opts(chat_id i64, input_file json2.Any, opts StickerSendOptions) !json2.Any {
	return send_sticker(b.session, mut *b.td, chat_id, input_file, opts)
}

pub fn (mut b BotAccount) send_poll(chat_id i64, question string, options []string, opts PollSendOptions) !json2.Any {
	return send_poll(b.session, mut *b.td, chat_id, question, options, opts)
}

// stop_poll closes an active poll. Only the bot that created the poll (or a chat admin) can stop it.
pub fn (mut b BotAccount) stop_poll(chat_id i64, message_id i64) !json2.Any {
	return stop_poll(b.session, mut *b.td, chat_id, message_id)
}

pub fn (mut b BotAccount) send_dice(chat_id i64, emoji string) !json2.Any {
	return send_dice(b.session, mut *b.td, chat_id, emoji, SendOptions{})
}

// send_dice_opts sends an animated dice with full send options (silent, protect, reply).
pub fn (mut b BotAccount) send_dice_opts(chat_id i64, emoji string, opts SendOptions) !json2.Any {
	return send_dice(b.session, mut *b.td, chat_id, emoji, opts)
}

// --- Search ---

pub fn (mut b BotAccount) search_public_chat(username string) !Chat {
	return search_public_chat(b.session, mut *b.td, username)
}

pub fn (mut b BotAccount) search_messages(chat_id i64, query string, from_message_id i64, limit int) ![]Message {
	return search_messages_in_chat(b.session, mut *b.td, chat_id, query, from_message_id,
		limit)
}

pub fn (mut b BotAccount) get_user_profile_photos(user_id i64, limit int) ![]Photo {
	return get_user_profile_photos(b.session, mut *b.td, user_id, limit)
}

// --- Bot-specific API ---

// set_commands replaces the bot's command list shown in the Telegram UI.
pub fn (mut b BotAccount) set_commands(commands []BotCommand) !json2.Any {
	return bot_set_commands(b.session, mut *b.td, commands)
}

// get_commands returns the bot's currently registered command list.
pub fn (mut b BotAccount) get_commands() ![]BotCommand {
	return bot_get_commands(b.session, mut *b.td)
}

// set_name changes the bot's display name.
pub fn (mut b BotAccount) set_name(name string) !json2.Any {
	return bot_set_name(b.session, mut *b.td, name)
}

// set_description sets the bot's description shown to users who have never
// started a chat with it.
pub fn (mut b BotAccount) set_description(description string) !json2.Any {
	return bot_set_description(b.session, mut *b.td, description)
}

// set_short_description sets the bot's short description shown on the
// profile page and on sharing.
pub fn (mut b BotAccount) set_short_description(short_description string) !json2.Any {
	return bot_set_short_description(b.session, mut *b.td, short_description)
}

// set_profile_photo uploads a new profile photo for the bot from a local file.
pub fn (mut b BotAccount) set_profile_photo(local_path string) !json2.Any {
	return bot_set_profile_photo(b.session, mut *b.td, local_path)
}

// answer_inline_query sends a response to an inline query received via
// updateNewInlineQuery.  results is a slice of inputInlineQueryResult objects.
// cache_time: seconds to cache the result on Telegram's servers (0 = default).
// is_personal: true to cache per-user rather than globally.
// next_offset: pagination cursor for the next page of results ('' = no more).
pub fn (mut b BotAccount) answer_inline_query(inline_query_id i64, results []json2.Any, cache_time int, is_personal bool, next_offset string) !json2.Any {
	return bot_answer_inline_query(b.session, mut *b.td, inline_query_id, results, cache_time,
		is_personal, next_offset)
}

// answer_callback_query responds to a callback query from an inline keyboard
// button press (updateNewCallbackQuery).
//
// Bots MUST answer every callback query or the button will spin indefinitely.
//
// callback_query_id: from the updateNewCallbackQuery update.
// text:              notification text shown to the user; '' for a silent ack.
// show_alert:        true shows a dialog alert instead of a toast notification.
// url:               URL to open (for 'game' buttons); '' for none.
// cache_time:        seconds Telegram may cache this answer (0 = default 0).
pub fn (mut b BotAccount) answer_callback_query(callback_query_id i64, text string, show_alert bool, url string, cache_time int) !json2.Any {
	return bot_answer_callback_query(b.session, mut *b.td, callback_query_id, text, show_alert,
		url, cache_time)
}

// --- Raw access ---
// Use these to call any TDLib method not yet wrapped by the library.
// Build requests with new_request() from builder.v.

pub fn (mut b BotAccount) raw_send(req json2.Any) !chan json2.Any {
	return b.session.send(mut *b.td, req)
}

pub fn (mut b BotAccount) raw_send_sync(req json2.Any) !json2.Any {
	return b.session.send_sync(mut *b.td, req)
}

pub fn (mut b BotAccount) raw_send_fire(req json2.Any) ! {
	b.session.send_fire(mut *b.td, req)!
}

// --- Synchronous file download ---

// download_sync downloads a file and BLOCKS until it is fully on disk.
// Returns a TDFile with local_path() set.  No updateFile handler needed.
// priority: 1 (lowest) .. 32 (highest).
pub fn (mut b BotAccount) download_sync(file_id i64, priority int) !TDFile {
	return download_file_sync(b.session, mut *b.td, file_id, priority)
}

// --- Preliminary file upload ---

// upload_file pre-uploads a local file to Telegram without sending it anywhere.
// file_type: one of the tdlib.file_type_* constants (e.g. file_type_photo).
// Returns a TDFile whose id() you can track via updateFile.  Once the upload
// completes, use input_remote(f.remote_id()) to send it to many recipients.
pub fn (mut b BotAccount) upload_file(local_path string, file_type string) !TDFile {
	return preliminary_upload_file(b.session, mut *b.td, local_path, file_type)
}

// cancel_upload cancels a preliminary upload started by upload_file().
pub fn (mut b BotAccount) cancel_upload(file_id i64) !json2.Any {
	return cancel_preliminary_upload(b.session, mut *b.td, file_id)
}

// --- Extended proxy management ---

// add_mtproto_proxy adds a Telegram MTProto proxy and enables it immediately.
// Returns a typed Proxy object with id(), server(), port(), etc.
pub fn (mut b BotAccount) add_mtproto_proxy(server string, port int, secret string) !Proxy {
	return add_mtproto_proxy(b.session, mut *b.td, server, port, secret)
}

// get_proxies returns all proxies stored for this session.
pub fn (mut b BotAccount) get_proxies() ![]Proxy {
	return get_proxies(b.session, mut *b.td)
}

// remove_proxy permanently removes the proxy with the given ID.
pub fn (mut b BotAccount) remove_proxy(proxy_id int) !json2.Any {
	return remove_proxy(b.session, mut *b.td, proxy_id)
}

// enable_proxy enables the proxy with the given ID and makes it active.
pub fn (mut b BotAccount) enable_proxy(proxy_id int) !json2.Any {
	return enable_proxy(b.session, mut *b.td, proxy_id)
}

// disable_proxy disables the currently active proxy (direct connection).
pub fn (mut b BotAccount) disable_proxy() !json2.Any {
	return disable_proxy(b.session, mut *b.td)
}

// ping_proxy measures the latency to a proxy in milliseconds.
// Returns an error if the proxy is unreachable.
pub fn (mut b BotAccount) ping_proxy(proxy_id int) !f64 {
	return ping_proxy(b.session, mut *b.td, proxy_id)
}

// get_proxies_sorted_by_ping pings all stored proxies and returns the
// reachable ones sorted by latency, fastest first.
pub fn (mut b BotAccount) get_proxies_sorted_by_ping() ![]ProxyPingResult {
	return get_proxies_sorted_by_ping(b.session, mut *b.td)
}

// --- Message copying ---

// copy_message sends a copy of a message without "Forwarded from" attribution.
// remove_caption: strip the original media caption.
pub fn (mut b BotAccount) copy_message(to_chat_id i64, from_chat_id i64, message_id i64, remove_caption bool, opts SendOptions) !json2.Any {
	return copy_message(b.session, mut *b.td, to_chat_id, from_chat_id, message_id, remove_caption,
		opts)
}

// --- Admin management ---

// promote_chat_member promotes user_id to admin in chat_id with the given
// rights.  custom_title sets an optional badge ('' = default "Administrator").
pub fn (mut b BotAccount) promote_chat_member(chat_id i64, user_id i64, rights AdminRights, custom_title string) !json2.Any {
	return promote_chat_member(b.session, mut *b.td, chat_id, user_id, rights, custom_title)
}

// demote_chat_member strips admin privileges from user_id in chat_id.
pub fn (mut b BotAccount) demote_chat_member(chat_id i64, user_id i64) !json2.Any {
	return demote_chat_member(b.session, mut *b.td, chat_id, user_id)
}

// unpin_all_messages removes every pinned message from a chat at once.
pub fn (mut b BotAccount) unpin_all_messages(chat_id i64) !json2.Any {
	return unpin_all_messages(b.session, mut *b.td, chat_id)
}

// set_slow_mode sets the inter-message delay for non-admin members.
// delay_seconds: 0 (off), 10, 30, 60, 300, 900, or 3600.
pub fn (mut b BotAccount) set_slow_mode(chat_id i64, delay_seconds int) !json2.Any {
	return set_slow_mode(b.session, mut *b.td, chat_id, delay_seconds)
}

// --- Bot info ---

// get_info returns the bot's current name, description, and short description.
pub fn (mut b BotAccount) get_info() !BotInfo {
	return bot_get_info(b.session, mut *b.td)
}

// --- Bot menu button ---

// set_menu_button sets a Web App button in the chat input area.
// user_id: specific user to set it for, or 0 for all users (default).
// text:    label shown on the button.
// url:     HTTPS URL of the Web App to open when tapped.
pub fn (mut b BotAccount) set_menu_button(user_id i64, text string, url string) !json2.Any {
	return bot_set_menu_button(b.session, mut *b.td, user_id, text, url)
}

// reset_menu_button resets the menu button back to the default keyboard
// commands button for a specific user, or for all users if user_id = 0.
pub fn (mut b BotAccount) reset_menu_button(user_id i64) !json2.Any {
	return bot_reset_menu_button(b.session, mut *b.td, user_id)
}

// --- Reply keyboards ---
// These methods send a message with a replyMarkupShowKeyboard, which displays
// persistent buttons below the text input box.  Build the markup with
// tdlib.reply_keyboard_markup() or tdlib.reply_keyboard_auto().
// To remove the keyboard, pass tdlib.remove_keyboard(false) as the markup.

// send_text_reply_keyboard sends plain text with a reply keyboard markup.
// The keyboard stays visible until explicitly removed.
pub fn (mut b BotAccount) send_text_reply_keyboard(chat_id i64, text string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_text_with_keyboard(b.session, mut *b.td, chat_id, text, markup, opts)
}

// send_html_reply_keyboard sends HTML-formatted text with a reply keyboard markup.
pub fn (mut b BotAccount) send_html_reply_keyboard(chat_id i64, html string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_html_with_keyboard(b.session, mut *b.td, chat_id, html, markup, opts)
}

// send_markdown_reply_keyboard sends MarkdownV2-formatted text with a reply keyboard markup.
pub fn (mut b BotAccount) send_markdown_reply_keyboard(chat_id i64, md string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_markdown_with_keyboard(b.session, mut *b.td, chat_id, md, markup, opts)
}

// --- Extended user information ---

// get_user_full_info returns the extended profile of a user, including their bio,
// call settings, common group count, and full-resolution profile photos.
pub fn (mut b BotAccount) get_user_full_info(user_id i64) !UserFullInfo {
	return get_user_full_info(b.session, mut *b.td, user_id)
}

// --- Extended supergroup / channel information ---

// get_supergroup_full_info returns extended data for a supergroup or channel:
// description, member counts, invite link, profile photo, slow mode, and more.
// supergroup_id is the bare positive ID from Chat.supergroup_id().
pub fn (mut b BotAccount) get_supergroup_full_info(supergroup_id i64) !SupergroupFullInfo {
	return get_supergroup_full_info(b.session, mut *b.td, supergroup_id)
}

// --- Chat profile photo history ---

// get_chat_photo_history returns all profile photos for a chat accessible to
// this bot, oldest first.  Each ChatPhoto exposes id(), added_date(), and sizes().
// offset: number of photos to skip; limit: maximum to return.
pub fn (mut b BotAccount) get_chat_photo_history(chat_id i64, offset int, limit int) ![]ChatPhoto {
	return get_chat_photo_history(b.session, mut *b.td, chat_id, offset, limit)
}
