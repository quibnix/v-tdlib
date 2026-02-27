// tdlib/account.v
// UserAccount: a Telegram user account authenticated with a phone number.
//
// Users have the full Telegram API available:
//   - Read and send messages in all their chats
//   - Manage their own profile (name, bio, profile photo)
//   - Access message history
//   - Join/leave groups and channels
//   - Download any accessible file
//   - Retrieve extended user info (bio, call settings) via get_user_full_info()
//   - Retrieve extended supergroup/channel info via get_supergroup_full_info()
//   - Browse all profile photo history with get_chat_photo_history()
//   - Manage chat folders: list, create, edit, delete, add/remove chats,
//     create and join via invite links
//
// UserAccount is fundamentally different from BotAccount - users can access
// all their chats, whereas bots can only access chats they have been added to.
module tdlib

import x.json2

// UserAccount represents a Telegram user logged in with a phone number.
pub struct UserAccount {
pub mut:
	session Session
	td      &TDLib
}

// --- Constructors ---

// UserAccount.new creates a UserAccount with its own private TDLib hub.
// Use AccountManager.add_user() when managing multiple accounts.
pub fn UserAccount.new() !&UserAccount {
	mut td := new()
	session := td.create_session()
	return &UserAccount{
		session: session
		td:      td
	}
}

// UserAccount.new_shared creates a UserAccount sharing an existing TDLib hub.
// Used internally by AccountManager.
pub fn UserAccount.new_shared(mut td TDLib) &UserAccount {
	session := td.create_session()
	return &UserAccount{
		session: session
		td:      td
	}
}

// --- Lifecycle ---

// setup sends setTdlibParameters. Must be called once before login().
pub fn (mut u UserAccount) setup(api_id int, api_hash string, data_dir string) !json2.Any {
	return setup_parameters(u.session, mut *u.td, api_id, api_hash, data_dir)
}

// login runs the phone-number authentication flow.
// phone is optional: pass the number (e.g. '+12025550100') to skip the stdin
// prompt, or pass none to have the library prompt on stdin instead.
//
//   // Provide phone at call time (no stdin prompt):
//   user.login('+12025550100')!
//
//   // No phone known yet - library will prompt via stdin:
//   user.login(none)!
//
// Prompts for OTP and optional 2FA password via stdin unless you supply
// them through login_custom() instead.
// Blocks until authorizationStateReady or an error.
pub fn (mut u UserAccount) login(phone ?string) ! {
	run_user_auth(u.session, mut *u.td, phone)!
}

// login_custom runs the phone-number authentication flow using caller-supplied
// callbacks instead of stdin prompts.  This is useful for GUI applications,
// automated tests, or any program that cannot use stdin.
//
// Assign at minimum handler.get_phone and handler.get_code.  Any callback
// left as nil (the zero value) falls back to an os.input() prompt.
//
//   handler := tdlib.UserLoginHandler{
//       get_phone: fn() string { return os.getenv('TG_PHONE') }
//       get_code:  fn() string { return read_from_database('otp') }
//   }
//   user.login_custom(handler)!
pub fn (mut u UserAccount) login_custom(handler UserLoginHandler) ! {
	run_user_auth_with_handler(u.session, mut *u.td, handler)!
}

// shutdown stops the private TDLib hub.
// Call only when this UserAccount owns its own hub (created with UserAccount.new()).
// For shared-hub accounts, call AccountManager.shutdown() instead.
pub fn (mut u UserAccount) shutdown() {
	u.td.shutdown()
}

// --- Update handlers ---

// on registers a handler for a specific TDLib @type on this account.
// The handler is called in a new goroutine per update, so it can safely
// call any synchronous API method (send_text, download, etc.).
//
//   user.on('updateNewMessage', fn [mut user] (upd json2.Any) {
//       msg := tdlib.Message.from(tdlib.map_obj(upd.as_map(), 'message'))
//       if !msg.is_outgoing() {
//           user.send_text(msg.chat_id(), 'Got it!') or {}
//       }
//   })
pub fn (mut u UserAccount) on(typ string, handler Handler) {
	u.td.on(u.session.id, typ, handler)
}

// off removes a previously registered handler for this account.
pub fn (mut u UserAccount) off(typ string) {
	u.td.off(u.session.id, typ)
}

// get_update blocks until an update with no registered handler arrives
// for this account. Useful during auth and for custom manual polling loops.
pub fn (mut u UserAccount) get_update() json2.Any {
	return u.td.get_update(u.session.id)
}

// --- Identity ---

pub fn (mut u UserAccount) get_me() !User {
	return get_me(u.session, mut *u.td)
}

pub fn (mut u UserAccount) get_user(user_id i64) !User {
	return get_user(u.session, mut *u.td, user_id)
}

pub fn (mut u UserAccount) get_chat(chat_id i64) !Chat {
	return get_chat(u.session, mut *u.td, chat_id)
}

pub fn (mut u UserAccount) get_message(chat_id i64, message_id i64) !Message {
	return get_message(u.session, mut *u.td, chat_id, message_id)
}

pub fn (mut u UserAccount) get_chat_history(chat_id i64, from_message_id i64, limit int) ![]Message {
	return get_chat_history(u.session, mut *u.td, chat_id, from_message_id, limit)
}

// get_chats returns the first limit chat IDs from the main chat list,
// sorted by last activity (most recent first).
pub fn (mut u UserAccount) get_chats(limit int) ![]i64 {
	return get_chats(u.session, mut *u.td, limit)
}

// --- Proxy ---

pub fn (mut u UserAccount) add_socks5_proxy(server string, port int, username string, password string) !json2.Any {
	return add_socks5_proxy(u.session, mut *u.td, server, port, username, password)
}

pub fn (mut u UserAccount) add_http_proxy(server string, port int, username string, password string) !json2.Any {
	return add_http_proxy(u.session, mut *u.td, server, port, username, password)
}

// --- Sending text messages ---

pub fn (mut u UserAccount) send_text(chat_id i64, text string) !json2.Any {
	return send_text_message(u.session, mut *u.td, chat_id, text, SendOptions{})
}

pub fn (mut u UserAccount) send_text_opts(chat_id i64, text string, opts SendOptions) !json2.Any {
	return send_text_message(u.session, mut *u.td, chat_id, text, opts)
}

pub fn (mut u UserAccount) send_html(chat_id i64, html string) !json2.Any {
	return send_html_message(u.session, mut *u.td, chat_id, html, SendOptions{})
}

pub fn (mut u UserAccount) send_html_opts(chat_id i64, html string, opts SendOptions) !json2.Any {
	return send_html_message(u.session, mut *u.td, chat_id, html, opts)
}

pub fn (mut u UserAccount) send_markdown(chat_id i64, md string) !json2.Any {
	return send_markdown_message(u.session, mut *u.td, chat_id, md, SendOptions{})
}

pub fn (mut u UserAccount) send_markdown_opts(chat_id i64, md string, opts SendOptions) !json2.Any {
	return send_markdown_message(u.session, mut *u.td, chat_id, md, opts)
}

// reply_text replies to a specific message with plain text.
pub fn (mut u UserAccount) reply_text(chat_id i64, reply_to_id i64, text string) !json2.Any {
	return send_text_message(u.session, mut *u.td, chat_id, text, SendOptions{
		reply_to_message_id: reply_to_id
	})
}

// reply_html replies to a specific message with HTML-formatted text.
pub fn (mut u UserAccount) reply_html(chat_id i64, reply_to_id i64, html string) !json2.Any {
	return send_html_message(u.session, mut *u.td, chat_id, html, SendOptions{
		reply_to_message_id: reply_to_id
	})
}

// reply_markdown replies to a specific message with MarkdownV2-formatted text.
pub fn (mut u UserAccount) reply_markdown(chat_id i64, reply_to_id i64, md string) !json2.Any {
	return send_markdown_message(u.session, mut *u.td, chat_id, md, SendOptions{
		reply_to_message_id: reply_to_id
	})
}

// send_text_keyboard sends plain text with an inline keyboard attached.
pub fn (mut u UserAccount) send_text_keyboard(chat_id i64, text string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_text_with_keyboard(u.session, mut *u.td, chat_id, text, markup, opts)
}

// send_html_keyboard sends HTML-formatted text with an inline keyboard in one call.
// Combines html_text() parsing and the reply_markup in a single sendMessage.
pub fn (mut u UserAccount) send_html_keyboard(chat_id i64, html string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_html_with_keyboard(u.session, mut *u.td, chat_id, html, markup, opts)
}

// send_markdown_keyboard sends MarkdownV2-formatted text with an inline keyboard.
pub fn (mut u UserAccount) send_markdown_keyboard(chat_id i64, md string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_markdown_with_keyboard(u.session, mut *u.td, chat_id, md, markup, opts)
}

// --- Sending media ---

pub fn (mut u UserAccount) send_photo(chat_id i64, input_file json2.Any, opts PhotoSendOptions) !json2.Any {
	return send_photo(u.session, mut *u.td, chat_id, input_file, opts)
}

pub fn (mut u UserAccount) send_video(chat_id i64, input_file json2.Any, opts VideoSendOptions) !json2.Any {
	return send_video(u.session, mut *u.td, chat_id, input_file, opts)
}

pub fn (mut u UserAccount) send_audio(chat_id i64, input_file json2.Any, opts AudioSendOptions) !json2.Any {
	return send_audio(u.session, mut *u.td, chat_id, input_file, opts)
}

pub fn (mut u UserAccount) send_voice_note(chat_id i64, input_file json2.Any, opts VoiceSendOptions) !json2.Any {
	return send_voice_note(u.session, mut *u.td, chat_id, input_file, opts)
}

pub fn (mut u UserAccount) send_video_note(chat_id i64, input_file json2.Any, opts VideoNoteSendOptions) !json2.Any {
	return send_video_note(u.session, mut *u.td, chat_id, input_file, opts)
}

pub fn (mut u UserAccount) send_document(chat_id i64, input_file json2.Any, opts DocumentSendOptions) !json2.Any {
	return send_document(u.session, mut *u.td, chat_id, input_file, opts)
}

// send_animation sends an animation file (GIF or H.264/MPEG-4 AVC without sound).
// Use input_local(), input_id(), or input_remote() to specify the file.
pub fn (mut u UserAccount) send_animation(chat_id i64, input_file json2.Any, opts AnimationSendOptions) !json2.Any {
	return send_animation(u.session, mut *u.td, chat_id, input_file, opts)
}

pub fn (mut u UserAccount) send_location(chat_id i64, latitude f64, longitude f64) !json2.Any {
	return send_location(u.session, mut *u.td, chat_id, latitude, longitude, SendOptions{})
}

pub fn (mut u UserAccount) send_location_opts(chat_id i64, latitude f64, longitude f64, opts SendOptions) !json2.Any {
	return send_location(u.session, mut *u.td, chat_id, latitude, longitude, opts)
}

// send_live_location sends a live location message.
// The map pin updates in real-time while the live period is active.
// Use edit_live_location() to push position updates.
pub fn (mut u UserAccount) send_live_location(chat_id i64, latitude f64, longitude f64, opts LiveLocationOptions) !json2.Any {
	return send_live_location(u.session, mut *u.td, chat_id, latitude, longitude, opts)
}

// edit_live_location pushes a new GPS position to an active live-location message.
// heading: direction of travel in degrees (1..360), or 0 to omit.
// proximity_alert_radius: alert radius in metres (1..100000), or 0 to omit.
pub fn (mut u UserAccount) edit_live_location(chat_id i64, message_id i64, latitude f64, longitude f64, heading int, proximity_alert_radius int) !json2.Any {
	return edit_message_live_location(u.session, mut *u.td, chat_id, message_id, latitude,
		longitude, heading, proximity_alert_radius)
}

// stop_live_location stops an active live-location message, freezing the pin at
// its last position.  Equivalent to calling editMessageLiveLocation without a
// location field.
pub fn (mut u UserAccount) stop_live_location(chat_id i64, message_id i64) !json2.Any {
	return stop_message_live_location(u.session, mut *u.td, chat_id, message_id)
}

// send_venue sends a venue (named location with address).
// Set provider='' and provider_id='' for a plain venue without a map provider link.
pub fn (mut u UserAccount) send_venue(chat_id i64, latitude f64, longitude f64, title string, address string, provider string, provider_id string, opts VenueOptions) !json2.Any {
	return send_venue(u.session, mut *u.td, chat_id, latitude, longitude, title, address,
		provider, provider_id, opts)
}

pub fn (mut u UserAccount) send_album(chat_id i64, items []AlbumItem, opts SendOptions) !json2.Any {
	return send_album(u.session, mut *u.td, chat_id, items, opts)
}

// --- Chat open / close ---

// open_chat informs TDLib that the user is viewing this chat.
// Call close_chat when navigating away.
pub fn (mut u UserAccount) open_chat(chat_id i64) !json2.Any {
	return open_chat(u.session, mut *u.td, chat_id)
}

// close_chat informs TDLib that the user has left this chat view.
pub fn (mut u UserAccount) close_chat(chat_id i64) !json2.Any {
	return close_chat(u.session, mut *u.td, chat_id)
}

// --- Reading messages ---

// view_messages marks the given messages as read, updating unread counts
// and notification badges.
pub fn (mut u UserAccount) view_messages(chat_id i64, message_ids []i64, force_read bool) !json2.Any {
	return view_messages(u.session, mut *u.td, chat_id, message_ids, force_read)
}

// --- Chat action ---

// send_chat_action broadcasts a typing/upload indicator to other participants.
// See common.v send_chat_action for available action_type strings.
pub fn (mut u UserAccount) send_chat_action(chat_id i64, action_type string) !json2.Any {
	return send_chat_action(u.session, mut *u.td, chat_id, action_type)
}

// --- Message reactions ---

// add_message_reaction adds an emoji reaction to a message.
pub fn (mut u UserAccount) add_message_reaction(chat_id i64, message_id i64, emoji string, is_big bool) !json2.Any {
	return add_message_reaction(u.session, mut *u.td, chat_id, message_id, emoji, is_big,
		true)
}

// remove_message_reaction removes a previously set emoji reaction.
pub fn (mut u UserAccount) remove_message_reaction(chat_id i64, message_id i64, emoji string) !json2.Any {
	return remove_message_reaction(u.session, mut *u.td, chat_id, message_id, emoji)
}

// --- Forwarding ---

pub fn (mut u UserAccount) forward_messages(to_chat_id i64, from_chat_id i64, message_ids []i64) !json2.Any {
	return forward_messages(u.session, mut *u.td, to_chat_id, from_chat_id, message_ids)
}

// forward_message_with_markup forwards a single message to another chat and
// re-attaches its inline keyboard to the forwarded copy.
// TDLib normally strips reply_markup from forwarded messages; this function
// patches the forwarded copy with editMessageReplyMarkup automatically.
pub fn (mut u UserAccount) forward_message_with_markup(to_chat_id i64, from_chat_id i64, message_id i64) !Message {
	return forward_message_with_markup(u.session, mut *u.td, to_chat_id, from_chat_id,
		message_id)
}

// --- Editing ---

pub fn (mut u UserAccount) edit_text(chat_id i64, message_id i64, text string) !json2.Any {
	return edit_message_text(u.session, mut *u.td, chat_id, message_id, text)
}

// edit_html edits the text of an existing message using HTML formatting.
pub fn (mut u UserAccount) edit_html(chat_id i64, message_id i64, html string) !json2.Any {
	return edit_message_html(u.session, mut *u.td, chat_id, message_id, html)
}

// edit_markdown edits the text of an existing message using MarkdownV2 formatting.
pub fn (mut u UserAccount) edit_markdown(chat_id i64, message_id i64, md string) !json2.Any {
	return edit_message_markdown(u.session, mut *u.td, chat_id, message_id, md)
}

pub fn (mut u UserAccount) edit_caption(chat_id i64, message_id i64, caption string) !json2.Any {
	return edit_message_caption(u.session, mut *u.td, chat_id, message_id, caption)
}

pub fn (mut u UserAccount) edit_reply_markup(chat_id i64, message_id i64, markup json2.Any) !json2.Any {
	return edit_message_reply_markup(u.session, mut *u.td, chat_id, message_id, markup)
}

// --- Editing inline messages (sent via inline query) ---
//
// Messages created through inline queries are identified by a string
// inline_message_id instead of (chat_id, message_id).  Callbacks from
// these messages arrive in updateNewInlineCallbackQuery (not
// updateNewCallbackQuery), and they must be edited with the dedicated
// editInlineMessage* methods below.

// edit_inline_markup replaces the keyboard on an inline-query message.
// inline_message_id comes from the update's 'inline_message_id' field (string).
pub fn (mut u UserAccount) edit_inline_markup(inline_message_id string, markup json2.Any) !json2.Any {
	return edit_inline_message_reply_markup(u.session, mut *u.td, inline_message_id, markup)
}

// edit_inline_text replaces the text (and optionally the keyboard) on an
// inline-query message using HTML formatting.
pub fn (mut u UserAccount) edit_inline_text(inline_message_id string, html string, markup json2.Any) !json2.Any {
	formatted := html_text(html)!
	return edit_inline_message_text(u.session, mut *u.td, inline_message_id, formatted,
		markup)
}

// edit_inline_text_plain replaces the text of an inline-query message with
// plain unformatted text (and optionally replaces the keyboard).
pub fn (mut u UserAccount) edit_inline_text_plain(inline_message_id string, text string, markup json2.Any) !json2.Any {
	return edit_inline_message_text(u.session, mut *u.td, inline_message_id, plain_text(text),
		markup)
}

// edit_inline_text_markdown replaces the text of an inline-query message with
// MarkdownV2-formatted text (and optionally replaces the keyboard).
pub fn (mut u UserAccount) edit_inline_text_markdown(inline_message_id string, md string, markup json2.Any) !json2.Any {
	formatted := markdown_text(md)!
	return edit_inline_message_text(u.session, mut *u.td, inline_message_id, formatted,
		markup)
}

// --- Deleting messages ---

// delete deletes specific messages.  revoke=true deletes for all participants.
pub fn (mut u UserAccount) delete(chat_id i64, message_ids []i64, revoke bool) !json2.Any {
	return delete_messages(u.session, mut *u.td, chat_id, message_ids, revoke)
}

// delete_album deletes all messages in an album identified by any one member's ID.
pub fn (mut u UserAccount) delete_album(chat_id i64, any_album_message_id i64, revoke bool) !json2.Any {
	return delete_album(u.session, mut *u.td, chat_id, any_album_message_id, revoke)
}

// --- Pinning ---

pub fn (mut u UserAccount) pin_message(chat_id i64, message_id i64, silent bool) !json2.Any {
	return pin_message(u.session, mut *u.td, chat_id, message_id, silent)
}

pub fn (mut u UserAccount) unpin_message(chat_id i64, message_id i64) !json2.Any {
	return unpin_message(u.session, mut *u.td, chat_id, message_id)
}

// --- File download ---

// download starts downloading a file. Register an 'updateFile' handler to
// track progress; the handler receives TDFile updates with downloaded_size/size.
pub fn (mut u UserAccount) download(file_id i64, priority int) !TDFile {
	return download_file(u.session, mut *u.td, file_id, priority)
}

pub fn (mut u UserAccount) cancel_download(file_id i64) !json2.Any {
	return cancel_download(u.session, mut *u.td, file_id)
}

// get_file returns current file metadata (local path, size, etc.) by file ID.
pub fn (mut u UserAccount) get_file(file_id i64) !TDFile {
	return get_file(u.session, mut *u.td, file_id)
}

// --- Profile management (user-only) ---

// set_name changes the account's first and/or last name.
pub fn (mut u UserAccount) set_name(first_name string, last_name string) !json2.Any {
	req := new_request('setName').with_str('first_name', first_name).with_str('last_name',
		last_name).build()!
	return u.session.send_sync(mut *u.td, req)
}

// set_bio sets the account's About / bio text.
pub fn (mut u UserAccount) set_bio(bio string) !json2.Any {
	req := new_request('setBio').with_str('bio', bio).build()!
	return u.session.send_sync(mut *u.td, req)
}

// set_username changes the account's public @username.
// Pass an empty string to remove the username.
pub fn (mut u UserAccount) set_username(username string) !json2.Any {
	req := new_request('setUsername').with_str('username', username).build()!
	return u.session.send_sync(mut *u.td, req)
}

// set_profile_photo uploads a new profile photo from a local file path.
//
// BUG FIX: The previous implementation used '@type': 'inputChatPhotoLocal', which
// does not exist in TDLib. The correct type is 'inputChatPhotoStatic'.
pub fn (mut u UserAccount) set_profile_photo(local_path string) !json2.Any {
	req := new_request('setProfilePhoto').with_obj('photo', {
		'@type': json2.Any('inputChatPhotoStatic')
		'photo': input_local(local_path)
	}).build()!
	return u.session.send_sync(mut *u.td, req)
}

// --- Raw access ---
// Use these to call any TDLib method not yet wrapped by the library.
// Build requests with new_request() from builder.v.

pub fn (mut u UserAccount) raw_send(req json2.Any) !chan json2.Any {
	return u.session.send(mut *u.td, req)
}

pub fn (mut u UserAccount) raw_send_sync(req json2.Any) !json2.Any {
	return u.session.send_sync(mut *u.td, req)
}

pub fn (mut u UserAccount) raw_send_fire(req json2.Any) ! {
	u.session.send_fire(mut *u.td, req)!
}

// --- Moderation ---

pub fn (mut u UserAccount) ban_chat_member(chat_id i64, user_id i64, revoke_messages bool) !json2.Any {
	return ban_chat_member(u.session, mut *u.td, chat_id, user_id, revoke_messages)
}

pub fn (mut u UserAccount) unban_chat_member(chat_id i64, user_id i64) !json2.Any {
	return unban_chat_member(u.session, mut *u.td, chat_id, user_id)
}

pub fn (mut u UserAccount) kick_chat_member(chat_id i64, user_id i64) !json2.Any {
	return kick_chat_member(u.session, mut *u.td, chat_id, user_id)
}

pub fn (mut u UserAccount) restrict_chat_member(chat_id i64, user_id i64, permissions ChatPermissions, until_date i64) !json2.Any {
	return restrict_chat_member(u.session, mut *u.td, chat_id, user_id, permissions, until_date)
}

// --- Chat member queries ---

pub fn (mut u UserAccount) get_chat_administrators(chat_id i64) ![]ChatMember {
	return get_chat_administrators(u.session, mut *u.td, chat_id)
}

pub fn (mut u UserAccount) get_chat_member_count(chat_id i64) !int {
	return get_chat_member_count(u.session, mut *u.td, chat_id)
}

// get_chat_member returns the membership status of user_id in chat_id.
pub fn (mut u UserAccount) get_chat_member(chat_id i64, user_id i64) !ChatMember {
	return get_chat_member(u.session, mut *u.td, chat_id, user_id)
}

// get_supergroup_members returns members of a supergroup or channel.
// Use Chat.supergroup_id() to get the supergroup_id from a Chat object.
pub fn (mut u UserAccount) get_supergroup_members(supergroup_id i64, filter SupergroupMembersFilter, offset int, limit int) ![]ChatMember {
	return get_supergroup_members(u.session, mut *u.td, supergroup_id, filter, offset,
		limit)
}

// --- Chat management ---

pub fn (mut u UserAccount) set_chat_title(chat_id i64, title string) !json2.Any {
	return set_chat_title(u.session, mut *u.td, chat_id, title)
}

pub fn (mut u UserAccount) set_chat_description(chat_id i64, description string) !json2.Any {
	return set_chat_description(u.session, mut *u.td, chat_id, description)
}

pub fn (mut u UserAccount) set_chat_photo(chat_id i64, local_path string) !json2.Any {
	return set_chat_photo(u.session, mut *u.td, chat_id, local_path)
}

pub fn (mut u UserAccount) delete_chat_photo(chat_id i64) !json2.Any {
	return delete_chat_photo(u.session, mut *u.td, chat_id)
}

pub fn (mut u UserAccount) leave_chat(chat_id i64) !json2.Any {
	return leave_chat(u.session, mut *u.td, chat_id)
}

// join_chat_by_invite_link joins a chat using a Telegram invite link (user accounts only).
pub fn (mut u UserAccount) join_chat_by_invite_link(invite_link string) !json2.Any {
	return join_chat_by_invite_link(u.session, mut *u.td, invite_link)
}

// --- Invite links ---

pub fn (mut u UserAccount) create_chat_invite_link(chat_id i64, expire_date i64, member_limit int) !string {
	return create_chat_invite_link(u.session, mut *u.td, chat_id, expire_date, member_limit)
}

// --- Extra content ---

pub fn (mut u UserAccount) send_contact(chat_id i64, phone string, first_name string, last_name string) !json2.Any {
	return send_contact(u.session, mut *u.td, chat_id, phone, first_name, last_name, SendOptions{})
}

pub fn (mut u UserAccount) send_contact_opts(chat_id i64, phone string, first_name string, last_name string, opts SendOptions) !json2.Any {
	return send_contact(u.session, mut *u.td, chat_id, phone, first_name, last_name, opts)
}

pub fn (mut u UserAccount) send_sticker(chat_id i64, input_file json2.Any) !json2.Any {
	return send_sticker(u.session, mut *u.td, chat_id, input_file, StickerSendOptions{})
}

// send_sticker_opts sends a sticker with full send options (silent, protect, reply).
pub fn (mut u UserAccount) send_sticker_opts(chat_id i64, input_file json2.Any, opts StickerSendOptions) !json2.Any {
	return send_sticker(u.session, mut *u.td, chat_id, input_file, opts)
}

pub fn (mut u UserAccount) send_poll(chat_id i64, question string, options []string, opts PollSendOptions) !json2.Any {
	return send_poll(u.session, mut *u.td, chat_id, question, options, opts)
}

// set_poll_answer casts a vote in a poll. Pass an empty slice to retract a vote.
pub fn (mut u UserAccount) set_poll_answer(chat_id i64, message_id i64, option_ids []int) !json2.Any {
	return set_poll_answer(u.session, mut *u.td, chat_id, message_id, option_ids)
}

// stop_poll closes an active poll.
pub fn (mut u UserAccount) stop_poll(chat_id i64, message_id i64) !json2.Any {
	return stop_poll(u.session, mut *u.td, chat_id, message_id)
}

pub fn (mut u UserAccount) send_dice(chat_id i64, emoji string) !json2.Any {
	return send_dice(u.session, mut *u.td, chat_id, emoji, SendOptions{})
}

// send_dice_opts sends an animated dice with full send options (silent, protect, reply).
pub fn (mut u UserAccount) send_dice_opts(chat_id i64, emoji string, opts SendOptions) !json2.Any {
	return send_dice(u.session, mut *u.td, chat_id, emoji, opts)
}

// --- Search ---

pub fn (mut u UserAccount) search_public_chat(username string) !Chat {
	return search_public_chat(u.session, mut *u.td, username)
}

pub fn (mut u UserAccount) search_messages(chat_id i64, query string, from_message_id i64, limit int) ![]Message {
	return search_messages_in_chat(u.session, mut *u.td, chat_id, query, from_message_id,
		limit)
}

pub fn (mut u UserAccount) get_user_profile_photos(user_id i64, limit int) ![]Photo {
	return get_user_profile_photos(u.session, mut *u.td, user_id, limit)
}

// --- Synchronous file download ---

// download_sync downloads a file and BLOCKS until it is fully on disk.
// Returns a TDFile with local_path() set.  No updateFile handler needed.
// priority: 1 (lowest) .. 32 (highest).
pub fn (mut u UserAccount) download_sync(file_id i64, priority int) !TDFile {
	return download_file_sync(u.session, mut *u.td, file_id, priority)
}

// --- Preliminary file upload ---

// upload_file pre-uploads a local file to Telegram without sending it anywhere.
// file_type: one of the tdlib.file_type_* constants (e.g. file_type_photo).
// Returns a TDFile whose id() you can track via updateFile.  Once the upload
// completes, use input_remote(f.remote_id()) to reference it in send calls.
pub fn (mut u UserAccount) upload_file(local_path string, file_type string) !TDFile {
	return preliminary_upload_file(u.session, mut *u.td, local_path, file_type)
}

// cancel_upload cancels a preliminary upload started by upload_file().
pub fn (mut u UserAccount) cancel_upload(file_id i64) !json2.Any {
	return cancel_preliminary_upload(u.session, mut *u.td, file_id)
}

// --- Extended proxy management ---

// add_mtproto_proxy adds a Telegram MTProto proxy and enables it immediately.
// Returns a typed Proxy object with id(), server(), port(), etc.
pub fn (mut u UserAccount) add_mtproto_proxy(server string, port int, secret string) !Proxy {
	return add_mtproto_proxy(u.session, mut *u.td, server, port, secret)
}

// get_proxies returns all proxies stored for this session.
pub fn (mut u UserAccount) get_proxies() ![]Proxy {
	return get_proxies(u.session, mut *u.td)
}

// remove_proxy permanently removes the proxy with the given ID.
pub fn (mut u UserAccount) remove_proxy(proxy_id int) !json2.Any {
	return remove_proxy(u.session, mut *u.td, proxy_id)
}

// enable_proxy enables the proxy with the given ID and makes it active.
pub fn (mut u UserAccount) enable_proxy(proxy_id int) !json2.Any {
	return enable_proxy(u.session, mut *u.td, proxy_id)
}

// disable_proxy disables the currently active proxy (direct connection).
pub fn (mut u UserAccount) disable_proxy() !json2.Any {
	return disable_proxy(u.session, mut *u.td)
}

// ping_proxy measures the latency to a proxy in milliseconds.
// Returns an error if the proxy is unreachable.
pub fn (mut u UserAccount) ping_proxy(proxy_id int) !f64 {
	return ping_proxy(u.session, mut *u.td, proxy_id)
}

// get_proxies_sorted_by_ping pings all stored proxies and returns the
// reachable ones sorted by latency, fastest first.
pub fn (mut u UserAccount) get_proxies_sorted_by_ping() ![]ProxyPingResult {
	return get_proxies_sorted_by_ping(u.session, mut *u.td)
}

// --- Message copying ---

// copy_message sends a copy of a message without "Forwarded from" attribution.
// remove_caption: strip the original media caption.
pub fn (mut u UserAccount) copy_message(to_chat_id i64, from_chat_id i64, message_id i64, remove_caption bool, opts SendOptions) !json2.Any {
	return copy_message(u.session, mut *u.td, to_chat_id, from_chat_id, message_id, remove_caption,
		opts)
}

// --- Admin management ---

// promote_chat_member promotes user_id to admin in chat_id with the given
// rights.  custom_title sets an optional badge ('' = default "Administrator").
pub fn (mut u UserAccount) promote_chat_member(chat_id i64, user_id i64, rights AdminRights, custom_title string) !json2.Any {
	return promote_chat_member(u.session, mut *u.td, chat_id, user_id, rights, custom_title)
}

// demote_chat_member strips admin privileges from user_id in chat_id.
pub fn (mut u UserAccount) demote_chat_member(chat_id i64, user_id i64) !json2.Any {
	return demote_chat_member(u.session, mut *u.td, chat_id, user_id)
}

// unpin_all_messages removes every pinned message from a chat at once.
pub fn (mut u UserAccount) unpin_all_messages(chat_id i64) !json2.Any {
	return unpin_all_messages(u.session, mut *u.td, chat_id)
}

// set_slow_mode sets the inter-message delay for non-admin members.
// delay_seconds: 0 (off), 10, 30, 60, 300, 900, or 3600.
pub fn (mut u UserAccount) set_slow_mode(chat_id i64, delay_seconds int) !json2.Any {
	return set_slow_mode(u.session, mut *u.td, chat_id, delay_seconds)
}

// --- Profile photo (extended) ---

// delete_profile_photo removes a specific profile photo by its ID.
// profile_photo_id comes from the photo returned by get_user_profile_photos()
// or from User.profile_photo_small() / profile_photo_big().
pub fn (mut u UserAccount) delete_profile_photo(profile_photo_id i64) !json2.Any {
	return delete_profile_photo(u.session, mut *u.td, profile_photo_id)
}

// --- Reply keyboards ---
// These methods send a message with a replyMarkupShowKeyboard, which displays
// persistent buttons below the text input box.  Build the markup with
// tdlib.reply_keyboard_markup() or tdlib.reply_keyboard_auto().
// To remove the keyboard, pass tdlib.remove_keyboard(false) as the markup.

// send_text_reply_keyboard sends plain text with a reply keyboard markup.
pub fn (mut u UserAccount) send_text_reply_keyboard(chat_id i64, text string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_text_with_keyboard(u.session, mut *u.td, chat_id, text, markup, opts)
}

// send_html_reply_keyboard sends HTML-formatted text with a reply keyboard markup.
pub fn (mut u UserAccount) send_html_reply_keyboard(chat_id i64, html string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_html_with_keyboard(u.session, mut *u.td, chat_id, html, markup, opts)
}

// send_markdown_reply_keyboard sends MarkdownV2-formatted text with a reply keyboard markup.
pub fn (mut u UserAccount) send_markdown_reply_keyboard(chat_id i64, md string, markup json2.Any, opts SendOptions) !json2.Any {
	return send_markdown_with_keyboard(u.session, mut *u.td, chat_id, md, markup, opts)
}

// --- Extended user information ---

// get_user_full_info returns the extended profile of a user, including their bio,
// call settings, common group count, and full-resolution profile photos.
pub fn (mut u UserAccount) get_user_full_info(user_id i64) !UserFullInfo {
	return get_user_full_info(u.session, mut *u.td, user_id)
}

// --- Extended supergroup / channel information ---

// get_supergroup_full_info returns extended data for a supergroup or channel:
// description, member counts, invite link, profile photo, slow mode, and more.
// supergroup_id is the bare positive ID from Chat.supergroup_id().
pub fn (mut u UserAccount) get_supergroup_full_info(supergroup_id i64) !SupergroupFullInfo {
	return get_supergroup_full_info(u.session, mut *u.td, supergroup_id)
}

// --- Chat profile photo history ---

// get_chat_photo_history returns all profile photos for a chat, oldest first.
// Each ChatPhoto exposes id(), added_date(), and sizes().
// offset: number of photos to skip; limit: maximum to return.
pub fn (mut u UserAccount) get_chat_photo_history(chat_id i64, offset int, limit int) ![]ChatPhoto {
	return get_chat_photo_history(u.session, mut *u.td, chat_id, offset, limit)
}

// --- Chat folder management ---

// get_chat_folders returns the list of all chat folders for this account.
pub fn (mut u UserAccount) get_chat_folders() ![]ChatFolderInfo {
	return get_chat_folders(u.session, mut *u.td)
}

// get_chat_folder returns the full configuration of a folder by its ID.
// Use ChatFolderInfo.id() from get_chat_folders() to find the ID.
pub fn (mut u UserAccount) get_chat_folder(chat_folder_id int) !ChatFolder {
	return get_chat_folder(u.session, mut *u.td, chat_folder_id)
}

// get_chats_in_folder returns the first limit chat IDs from a folder,
// sorted by last activity (most recent first).
pub fn (mut u UserAccount) get_chats_in_folder(chat_folder_id int, limit int) ![]i64 {
	return get_chats_in_folder(u.session, mut *u.td, chat_folder_id, limit)
}

// create_chat_folder creates a new chat folder with the given name and options.
// Returns the ID of the newly created folder.
pub fn (mut u UserAccount) create_chat_folder(name string, opts ChatFolderOptions) !int {
	return create_chat_folder(u.session, mut *u.td, name, opts)
}

// edit_chat_folder replaces the configuration of an existing folder.
pub fn (mut u UserAccount) edit_chat_folder(chat_folder_id int, name string, opts ChatFolderOptions) !ChatFolderInfo {
	return edit_chat_folder(u.session, mut *u.td, chat_folder_id, name, opts)
}

// delete_chat_folder removes a folder from the account.
// leave_chat_ids: chat IDs to leave when the folder is deleted; pass [] to keep all.
pub fn (mut u UserAccount) delete_chat_folder(chat_folder_id int, leave_chat_ids []i64) !json2.Any {
	return delete_chat_folder(u.session, mut *u.td, chat_folder_id, leave_chat_ids)
}

// add_chat_to_folder adds a chat to an existing folder.
pub fn (mut u UserAccount) add_chat_to_folder(chat_id i64, chat_folder_id int) !json2.Any {
	return add_chat_to_folder(u.session, mut *u.td, chat_id, chat_folder_id)
}

// remove_chat_from_folder removes a chat from a folder without leaving the chat.
pub fn (mut u UserAccount) remove_chat_from_folder(chat_id i64, chat_folder_id int) !json2.Any {
	return remove_chat_from_folder(u.session, mut *u.td, chat_id, chat_folder_id)
}

// join_chat_folder_by_link subscribes to all (or a subset of) chats referenced
// by a folder invite link.  Pass an empty chat_ids slice to join all chats.
pub fn (mut u UserAccount) join_chat_folder_by_link(invite_link string, chat_ids []i64) !json2.Any {
	return join_chat_folder_by_link(u.session, mut *u.td, invite_link, chat_ids)
}

// check_chat_folder_invite_link returns information about a folder invite link
// without joining it.  The raw response map contains chat_folder_info,
// missing_chat_ids, and added_chat_ids fields.
pub fn (mut u UserAccount) check_chat_folder_invite_link(invite_link string) !json2.Any {
	return check_chat_folder_invite_link(u.session, mut *u.td, invite_link)
}

// create_chat_folder_invite_link creates a shareable invite link for a folder.
// chat_ids lists the folder's chats to include; pass [] for all shareable chats.
// Returns the invite link URL.
pub fn (mut u UserAccount) create_chat_folder_invite_link(chat_folder_id int, name string, chat_ids []i64) !string {
	return create_chat_folder_invite_link(u.session, mut *u.td, chat_folder_id, name,
		chat_ids)
}

// --- Scheduled messages ---

// send_scheduled_text schedules a plain-text message for delivery at send_date (Unix timestamp).
pub fn (mut u UserAccount) send_scheduled_text(chat_id i64, text string, send_date i64, opts SendOptions) !json2.Any {
	return send_scheduled_text(u.session, mut *u.td, chat_id, text, send_date, opts)
}

// send_scheduled_html schedules an HTML-formatted message for delivery at send_date.
pub fn (mut u UserAccount) send_scheduled_html(chat_id i64, html string, send_date i64, opts SendOptions) !json2.Any {
	return send_scheduled_html(u.session, mut *u.td, chat_id, html, send_date, opts)
}

// send_scheduled_markdown schedules a MarkdownV2-formatted message for delivery at send_date.
pub fn (mut u UserAccount) send_scheduled_markdown(chat_id i64, md string, send_date i64, opts SendOptions) !json2.Any {
	return send_scheduled_markdown(u.session, mut *u.td, chat_id, md, send_date, opts)
}

// send_scheduled_photo schedules a photo message for delivery at send_date.
pub fn (mut u UserAccount) send_scheduled_photo(chat_id i64, input_file json2.Any, caption string, send_date i64, opts SendOptions) !json2.Any {
	return send_scheduled_photo(u.session, mut *u.td, chat_id, input_file, caption, send_date,
		opts)
}

// send_scheduled_document schedules a document message for delivery at send_date.
pub fn (mut u UserAccount) send_scheduled_document(chat_id i64, input_file json2.Any, caption string, send_date i64, opts SendOptions) !json2.Any {
	return send_scheduled_document(u.session, mut *u.td, chat_id, input_file, caption,
		send_date, opts)
}

// get_scheduled_messages returns all pending scheduled messages in a chat.
pub fn (mut u UserAccount) get_scheduled_messages(chat_id i64) ![]Message {
	return get_scheduled_messages(u.session, mut *u.td, chat_id)
}

// send_scheduled_message_now delivers a scheduled message immediately.
// message_id must come from get_scheduled_messages().
pub fn (mut u UserAccount) send_scheduled_message_now(chat_id i64, message_id i64) !json2.Any {
	return send_scheduled_message_now(u.session, mut *u.td, chat_id, message_id)
}

// send_all_scheduled_now delivers all pending scheduled messages in a chat immediately.
pub fn (mut u UserAccount) send_all_scheduled_now(chat_id i64) ! {
	send_all_scheduled_now(u.session, mut *u.td, chat_id)!
}

// delete_scheduled_messages cancels scheduled messages without sending them.
pub fn (mut u UserAccount) delete_scheduled_messages(chat_id i64, message_ids []i64) !json2.Any {
	return delete_scheduled_messages(u.session, mut *u.td, chat_id, message_ids)
}

// --- Forum topics ---

// create_forum_topic creates a new topic in a forum supergroup.
// icon_color: ARGB int (use one of the allowed values or 0 for auto).
// icon_custom_emoji_id: custom emoji ID string, or '' for the built-in icon.
// Returns ForumTopicInfo; use .message_thread_id() to send messages to the topic.
pub fn (mut u UserAccount) create_forum_topic(chat_id i64, name string, icon_color int, icon_custom_emoji_id string) !ForumTopicInfo {
	return create_forum_topic(u.session, mut *u.td, chat_id, name, icon_color, icon_custom_emoji_id)
}

// edit_forum_topic changes the name and/or custom emoji icon of an existing topic.
pub fn (mut u UserAccount) edit_forum_topic(chat_id i64, message_thread_id i64, name string, icon_custom_emoji_id string) !json2.Any {
	return edit_forum_topic(u.session, mut *u.td, chat_id, message_thread_id, name, icon_custom_emoji_id)
}

// close_forum_topic archives a topic so no new messages can be posted.
pub fn (mut u UserAccount) close_forum_topic(chat_id i64, message_thread_id i64) !json2.Any {
	return close_forum_topic(u.session, mut *u.td, chat_id, message_thread_id)
}

// reopen_forum_topic re-opens a previously closed topic.
pub fn (mut u UserAccount) reopen_forum_topic(chat_id i64, message_thread_id i64) !json2.Any {
	return reopen_forum_topic(u.session, mut *u.td, chat_id, message_thread_id)
}

// delete_forum_topic permanently deletes a topic and all of its messages.
pub fn (mut u UserAccount) delete_forum_topic(chat_id i64, message_thread_id i64) !json2.Any {
	return delete_forum_topic(u.session, mut *u.td, chat_id, message_thread_id)
}

// pin_forum_topic pins or unpins a topic in the forum list.
pub fn (mut u UserAccount) pin_forum_topic(chat_id i64, message_thread_id i64, is_pinned bool) !json2.Any {
	return pin_forum_topic(u.session, mut *u.td, chat_id, message_thread_id, is_pinned)
}

// hide_general_forum_topic hides or shows the "General" topic (thread_id=1).
pub fn (mut u UserAccount) hide_general_forum_topic(chat_id i64, hide bool) !json2.Any {
	return hide_general_forum_topic(u.session, mut *u.td, chat_id, hide)
}

// get_forum_topics returns a paginated list of topics in a forum supergroup.
// Pass all offset arguments as 0 for the first page.
pub fn (mut u UserAccount) get_forum_topics(chat_id i64, query string, offset_date i64, offset_message_id i64, offset_message_thread_id i64, limit int) ![]ForumTopic {
	return get_forum_topics(u.session, mut *u.td, chat_id, query, offset_date, offset_message_id,
		offset_message_thread_id, limit)
}

// get_forum_topic returns the details of a single topic by its thread ID.
pub fn (mut u UserAccount) get_forum_topic(chat_id i64, message_thread_id i64) !ForumTopic {
	return get_forum_topic(u.session, mut *u.td, chat_id, message_thread_id)
}

// get_forum_topic_history returns messages from a specific forum topic.
// from_message_id: 0 to start from the most recent message.
pub fn (mut u UserAccount) get_forum_topic_history(chat_id i64, message_thread_id i64, from_message_id i64, limit int) ![]Message {
	return get_forum_topic_history(u.session, mut *u.td, chat_id, message_thread_id, from_message_id,
		limit)
}

// --- Translation ---

// translate_text translates a plain string to the target language.
// to_language_code: IETF BCP 47 code (e.g. 'en', 'fr', 'de', 'ja').
// Returns a TranslatedText with the translation result.
pub fn (mut u UserAccount) translate_text(text string, to_language_code string) !TranslatedText {
	return translate_text(u.session, mut *u.td, text, to_language_code)
}

// translate_message translates the text of an existing message to the target language.
pub fn (mut u UserAccount) translate_message(chat_id i64, message_id i64, to_language_code string) !TranslatedText {
	return translate_message(u.session, mut *u.td, chat_id, message_id, to_language_code)
}
