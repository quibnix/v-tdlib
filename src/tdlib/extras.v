// tdlib/extras.v
// Additional useful features: moderation, chat management, polls,
// stickers, dice, contacts, search helpers, and more.
//
// All functions here follow the same pattern as common.v:
//   - Module-level implementation (no account struct dependency)
//   - Exposed on UserAccount and/or BotAccount as one-liner wrappers in botaccount.v / account.v
module tdlib

import x.json2

// --- Types ---

// ChatMember wraps a TDLib chatMember object.
pub struct ChatMember {
pub:
	raw map[string]json2.Any
}

pub fn ChatMember.from(m map[string]json2.Any) ChatMember {
	return ChatMember{
		raw: m
	}
}

// member_id returns the user_id of this member (0 if the sender is a chat/channel).
pub fn (cm ChatMember) member_id() i64 {
	sender := map_obj(cm.raw, 'member_id')
	if map_str(sender, '@type') == 'messageSenderUser' {
		return map_i64(sender, 'user_id')
	}
	return 0
}

// status_type returns the raw @type of the member's status, e.g.
// "chatMemberStatusAdministrator", "chatMemberStatusMember",
// "chatMemberStatusBanned", "chatMemberStatusLeft".
pub fn (cm ChatMember) status_type() string {
	return map_type(cm.raw, 'status')
}

pub fn (cm ChatMember) is_admin() bool {
	return cm.status_type() == 'chatMemberStatusAdministrator'
}

pub fn (cm ChatMember) is_owner() bool {
	return cm.status_type() == 'chatMemberStatusCreator'
}

pub fn (cm ChatMember) is_banned() bool {
	return cm.status_type() == 'chatMemberStatusBanned'
}

// joined_chat_date returns the Unix timestamp when the member joined.
pub fn (cm ChatMember) joined_chat_date() i64 {
	return map_i64(cm.raw, 'joined_chat_date')
}

// ChatPermissions controls what a restricted member may do.
// All fields default to false (most restrictive).
pub struct ChatPermissions {
pub:
	can_send_messages         bool
	can_send_media_messages   bool
	can_send_polls            bool
	can_send_other_messages   bool
	can_add_web_page_previews bool
	can_change_info           bool
	can_invite_users          bool
	can_pin_messages          bool
	// can_create_topics is required by chatPermissions since TDLib 1.8.20.
	can_create_topics bool
}

fn chat_permissions_obj(p ChatPermissions) map[string]json2.Any {
	return {
		'@type':                   json2.Any('chatPermissions')
		'can_send_basic_messages': json2.Any(p.can_send_messages)
		'can_send_audios':         json2.Any(p.can_send_media_messages)
		'can_send_documents':      json2.Any(p.can_send_media_messages)
		'can_send_photos':         json2.Any(p.can_send_media_messages)
		'can_send_videos':         json2.Any(p.can_send_media_messages)
		'can_send_video_notes':    json2.Any(p.can_send_media_messages)
		'can_send_voice_notes':    json2.Any(p.can_send_media_messages)
		'can_send_polls':          json2.Any(p.can_send_polls)
		'can_send_other_messages': json2.Any(p.can_send_other_messages)
		'can_add_link_previews':   json2.Any(p.can_add_web_page_previews)
		'can_change_info':         json2.Any(p.can_change_info)
		'can_invite_users':        json2.Any(p.can_invite_users)
		'can_pin_messages':        json2.Any(p.can_pin_messages)
		// can_create_topics is a required field of chatPermissions in current TDLib.
		// Omitting it caused TDLib to reject restriction requests with a parameter error.
		'can_create_topics':       json2.Any(p.can_create_topics)
	}
}

// --- Moderation ---

// ban_chat_member permanently bans user_id from chat_id.
// Set revoke_messages=true to also delete the user's messages.
//
// BUG FIX: The previous implementation omitted the required banned_until_date field.
// TDLib's banChatMember signature:
//   banChatMember chat_id member_id banned_until_date:int32 revoke_messages:bool
// banned_until_date is a Unix timestamp; 0 means the ban never expires (permanent).
fn ban_chat_member(s Session, mut td TDLib, chat_id i64, user_id i64, revoke_messages bool) !json2.Any {
	req := new_request('banChatMember').with_i64('chat_id', chat_id).with_obj('member_id',
		{
		'@type':   json2.Any('messageSenderUser')
		'user_id': json2.Any(user_id)
	}).with_int('banned_until_date', 0).with_bool('revoke_messages', revoke_messages).build()!
	return s.send_sync(mut td, req)
}

// unban_chat_member lifts a ban, allowing the user to re-join.
fn unban_chat_member(s Session, mut td TDLib, chat_id i64, user_id i64) !json2.Any {
	req := new_request('setChatMemberStatus').with_i64('chat_id', chat_id).with_obj('member_id',
		{
		'@type':   json2.Any('messageSenderUser')
		'user_id': json2.Any(user_id)
	}).with_obj('status', {
		'@type': json2.Any('chatMemberStatusLeft')
	}).build()!
	return s.send_sync(mut td, req)
}

// kick_chat_member removes user_id from chat_id without a permanent ban.
// The user can be re-added or rejoin via invite link.
fn kick_chat_member(s Session, mut td TDLib, chat_id i64, user_id i64) !json2.Any {
	req := new_request('setChatMemberStatus').with_i64('chat_id', chat_id).with_obj('member_id',
		{
		'@type':   json2.Any('messageSenderUser')
		'user_id': json2.Any(user_id)
	}).with_obj('status', {
		'@type': json2.Any('chatMemberStatusLeft')
	}).build()!
	return s.send_sync(mut td, req)
}

// restrict_chat_member applies ChatPermissions to user_id in chat_id.
// until_date is a Unix timestamp; 0 means permanent restriction.
fn restrict_chat_member(s Session, mut td TDLib, chat_id i64, user_id i64, permissions ChatPermissions, until_date i64) !json2.Any {
	req := new_request('setChatMemberStatus').with_i64('chat_id', chat_id).with_obj('member_id',
		{
		'@type':   json2.Any('messageSenderUser')
		'user_id': json2.Any(user_id)
	}).with_obj('status', {
		'@type':                 json2.Any('chatMemberStatusRestricted')
		'is_member':             json2.Any(true)
		'restricted_until_date': json2.Any(until_date)
		'permissions':           json2.Any(chat_permissions_obj(permissions))
	}).build()!
	return s.send_sync(mut td, req)
}

// --- Chat member queries ---

// get_chat_administrators returns all administrators of a group or channel.
fn get_chat_administrators(s Session, mut td TDLib, chat_id i64) ![]ChatMember {
	req := new_request('getChatAdministrators').with_i64('chat_id', chat_id).build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'administrators')
	mut out := []ChatMember{cap: raw_arr.len}
	for item in raw_arr {
		out << ChatMember.from(item.as_map())
	}
	return out
}

// get_chat_member_count returns the number of members in a group or channel.
//
// BUG FIX: The previous implementation called map_int(resp.raw, 'member_count') on a
// Chat object. TDLib's `chat` JSON type does not include a `member_count` field; it is
// only available on `supergroupFullInfo` (via getSupergroupFullInfo) and on the
// `members` array of `basicGroupFullInfo` (via getBasicGroupFullInfo).
//
// This implementation dispatches to the correct TDLib method based on chat type:
//   - Supergroups and channels: getSupergroupFullInfo -> member_count field
//   - Basic groups:             getBasicGroupFullInfo -> members array length
//   - Private chats / others:   returns 0 (no member count concept)
fn get_chat_member_count(s Session, mut td TDLib, chat_id i64) !int {
	chat := get_chat(s, mut td, chat_id)!
	if chat.is_supergroup() || chat.is_channel() {
		req := new_request('getSupergroupFullInfo').with_i64('supergroup_id', chat.supergroup_id()).build()!
		resp := s.send_sync(mut td, req)!
		return map_int(resp.as_map(), 'member_count')
	} else if chat.is_group() {
		req := new_request('getBasicGroupFullInfo').with_i64('basic_group_id', map_i64(map_obj(chat.raw,
			'type'), 'basic_group_id')).build()!
		resp := s.send_sync(mut td, req)!
		members := map_arr(resp.as_map(), 'members')
		return members.len
	}
	return 0
}

// get_chat_member returns the ChatMember object for a specific user in a chat.
// Useful for checking a user's status (admin, restricted, banned, etc.) before
// taking a moderation action.
fn get_chat_member(s Session, mut td TDLib, chat_id i64, user_id i64) !ChatMember {
	req := new_request('getChatMember').with_i64('chat_id', chat_id).with_obj('member_id',
		{
		'@type':   json2.Any('messageSenderUser')
		'user_id': json2.Any(user_id)
	}).build()!
	resp := s.send_sync(mut td, req)!
	return ChatMember.from(resp.as_map())
}

// SupergroupMembersFilter is passed to get_supergroup_members to restrict results.
// Common @type values:
//   "supergroupMembersFilterRecent"         - most recently joined members
//   "supergroupMembersFilterAdministrators" - all admins
//   "supergroupMembersFilterBanned"         - banned users
//   "supergroupMembersFilterRestricted"     - restricted users
//   "supergroupMembersFilterBots"           - bots in the group
pub type SupergroupMembersFilter = string

pub const sg_filter_recent = SupergroupMembersFilter('supergroupMembersFilterRecent')
pub const sg_filter_administrators = SupergroupMembersFilter('supergroupMembersFilterAdministrators')
pub const sg_filter_banned = SupergroupMembersFilter('supergroupMembersFilterBanned')
pub const sg_filter_restricted = SupergroupMembersFilter('supergroupMembersFilterRestricted')
pub const sg_filter_bots = SupergroupMembersFilter('supergroupMembersFilterBots')

// get_supergroup_members returns members of a supergroup or channel.
// supergroup_id: the numeric supergroup ID (use Chat.supergroup_id()).
// filter:        one of the sg_filter_* constants above.
// offset:        number of members to skip (for pagination).
// limit:         maximum number of members to return (up to 200).
fn get_supergroup_members(s Session, mut td TDLib, supergroup_id i64, filter SupergroupMembersFilter, offset int, limit int) ![]ChatMember {
	req := new_request('getSupergroupMembers').with_i64('supergroup_id', supergroup_id).with_obj('filter',
		{
		'@type': json2.Any(string(filter))
	}).with_int('offset', offset).with_int('limit', limit).build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'members')
	mut out := []ChatMember{cap: raw_arr.len}
	for item in raw_arr {
		out << ChatMember.from(item.as_map())
	}
	return out
}

// --- Chat management ---

// set_chat_title changes the title of a group, supergroup, or channel.
fn set_chat_title(s Session, mut td TDLib, chat_id i64, title string) !json2.Any {
	req := new_request('setChatTitle').with_i64('chat_id', chat_id).with_str('title',
		title).build()!
	return s.send_sync(mut td, req)
}

// set_chat_description changes the description/about of a supergroup or channel.
fn set_chat_description(s Session, mut td TDLib, chat_id i64, description string) !json2.Any {
	req := new_request('setChatDescription').with_i64('chat_id', chat_id).with_str('description',
		description).build()!
	return s.send_sync(mut td, req)
}

// set_chat_photo sets a new photo for a group, supergroup, or channel.
//
// BUG FIX: The previous implementation used '@type': 'inputChatPhotoLocal', which
// does not exist in TDLib. The correct type is 'inputChatPhotoStatic'.
fn set_chat_photo(s Session, mut td TDLib, chat_id i64, local_path string) !json2.Any {
	req := new_request('setChatPhoto').with_i64('chat_id', chat_id).with_obj('photo',
		{
		'@type': json2.Any('inputChatPhotoStatic')
		'photo': input_local(local_path)
	}).build()!
	return s.send_sync(mut td, req)
}

// delete_chat_photo removes the current photo of a group or channel.
fn delete_chat_photo(s Session, mut td TDLib, chat_id i64) !json2.Any {
	req := new_request('deleteChatPhoto').with_i64('chat_id', chat_id).build()!
	return s.send_sync(mut td, req)
}

// leave_chat leaves a group, supergroup, or channel.
fn leave_chat(s Session, mut td TDLib, chat_id i64) !json2.Any {
	req := new_request('leaveChat').with_i64('chat_id', chat_id).build()!
	return s.send_sync(mut td, req)
}

// --- Chat open / close ---

// open_chat informs TDLib that the user has opened a specific chat.
// TDLib uses this to deliver live location updates, updateChatReadInbox, etc.
// Always call close_chat when the user navigates away.
fn open_chat(s Session, mut td TDLib, chat_id i64) !json2.Any {
	req := new_request('openChat').with_i64('chat_id', chat_id).build()!
	return s.send_sync(mut td, req)
}

// close_chat informs TDLib that the user has closed a specific chat.
// Should be paired with every open_chat call.
fn close_chat(s Session, mut td TDLib, chat_id i64) !json2.Any {
	req := new_request('closeChat').with_i64('chat_id', chat_id).build()!
	return s.send_sync(mut td, req)
}

// --- Reading / acknowledging messages ---

// view_messages marks the given messages as read in a chat.
//
// TDLib >= 1.8.6 added a required source:MessageSource parameter.
// messageSourceChatHistory is the correct value when reading messages
// in a chat window; omitting source causes a parameter error on current TDLib.
fn view_messages(s Session, mut td TDLib, chat_id i64, message_ids []i64, force_read bool) !json2.Any {
	req := new_request('viewMessages').with_i64('chat_id', chat_id).with_obj('source',
		{
		'@type': json2.Any('messageSourceChatHistory')
	}).with('message_ids', arr_of_i64(message_ids)).with_bool('force_read', force_read).build()!
	return s.send_sync(mut td, req)
}

// --- Invite links ---

// create_chat_invite_link creates a new invite link for a group or channel.
// expire_date: Unix timestamp (0 = no expiry).
// member_limit: max number of uses (0 = unlimited).
fn create_chat_invite_link(s Session, mut td TDLib, chat_id i64, expire_date i64, member_limit int) !string {
	req := new_request('createChatInviteLink').with_i64('chat_id', chat_id).with_i64('expiration_date',
		expire_date).with_int('member_limit', member_limit).build()!
	resp := s.send_sync(mut td, req)!
	return map_str(resp.as_map(), 'invite_link')
}

// join_chat_by_invite_link joins a chat using an invite link (user accounts only).
fn join_chat_by_invite_link(s Session, mut td TDLib, invite_link string) !json2.Any {
	req := new_request('joinChatByInviteLink').with_str('invite_link', invite_link).build()!
	return s.send_sync(mut td, req)
}

// --- Sending extra content types ---

// send_contact sends a phone contact card.
fn send_contact(s Session, mut td TDLib, chat_id i64, phone string, first_name string, last_name string, opts SendOptions) !json2.Any {
	content := typed_obj('inputMessageContact', {
		'contact': typed_obj('contact', {
			'phone_number': json2.Any(phone)
			'first_name':   json2.Any(first_name)
			'last_name':    json2.Any(last_name)
			'user_id':      json2.Any(i64(0))
		})
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts, json2.Any(map[string]json2.Any{}))
}

// send_sticker sends a sticker file with optional display options.
// StickerSendOptions.width and .height are display dimensions in pixels (0 = let TDLib decide).
// StickerSendOptions.emoji is the primary emoji string ('' = none / use set metadata).
fn send_sticker(s Session, mut td TDLib, chat_id i64, input_file json2.Any, opts StickerSendOptions) !json2.Any {
	mut fields := map[string]json2.Any{}
	fields['@type'] = json2.Any('inputMessageSticker')
	fields['sticker'] = input_file
	if opts.width > 0 {
		fields['width'] = json2.Any(opts.width)
	}
	if opts.height > 0 {
		fields['height'] = json2.Any(opts.height)
	}
	if opts.emoji != '' {
		fields['emoji'] = json2.Any(opts.emoji)
	}
	return dispatch_send_message(s, mut td, chat_id, obj(fields), opts.send, json2.Any(map[string]json2.Any{}))
}

// PollSendOptions holds parameters for a poll message.
pub struct PollSendOptions {
pub:
	send                    SendOptions
	is_anonymous            bool = true
	allows_multiple_answers bool
	// For quiz mode: set correct_option_id >= 0
	correct_option_id int = -1
	explanation       string
	open_period       int // seconds the poll is open (0 = unlimited)
	close_date        i64 // Unix timestamp when poll auto-closes (0 = no auto-close)
}

// send_poll sends an interactive poll.
// question: poll question string.
// options: list of answer option strings (2-10 items).
//
// TDLib schema (current):
//   inputMessagePoll question:formattedText options:vector<formattedText>
//     is_anonymous:Bool type:PollType open_period:int32 close_date:int32
//
// Each option is a plain formattedText object (no intermediate wrapper type).
// This matches the current TDLib schema where options are vector<formattedText>,
// not vector<string> (old) and not vector<inputPollOption> (Bot API concept).
fn send_poll(s Session, mut td TDLib, chat_id i64, question string, options []string, opts PollSendOptions) !json2.Any {
	if options.len < 2 || options.len > 10 {
		return error('poll must have 2-10 options')
	}
	mut opt_arr := []json2.Any{cap: options.len}
	for o in options {
		opt_arr << plain_text(o)
	}
	mut poll_fields := map[string]json2.Any{}
	poll_fields['@type'] = json2.Any('inputMessagePoll')
	poll_fields['question'] = plain_text(question)
	poll_fields['options'] = json2.Any(opt_arr)
	poll_fields['is_anonymous'] = json2.Any(opts.is_anonymous)
	if opts.correct_option_id >= 0 {
		// Quiz mode: correct_option_id is the 0-based index of the correct answer.
		poll_fields['type'] = typed_obj('pollTypeQuiz', {
			'correct_option_id': json2.Any(opts.correct_option_id)
			'explanation':       plain_text(opts.explanation)
		})
	} else {
		poll_fields['type'] = typed_obj('pollTypeRegular', {
			'allow_multiple_answers': json2.Any(opts.allows_multiple_answers)
		})
	}
	if opts.open_period > 0 {
		poll_fields['open_period'] = json2.Any(opts.open_period)
	}
	if opts.close_date > 0 {
		poll_fields['close_date'] = json2.Any(opts.close_date)
	}
	return dispatch_send_message(s, mut td, chat_id, obj(poll_fields), opts.send, json2.Any(map[string]json2.Any{}))
}

// set_poll_answer votes for the specified options in a non-anonymous poll.
// option_ids: 0-based indices of the chosen options (empty to retract a vote).
// For quiz polls, pass a single element slice with the selected answer index.
fn set_poll_answer(s Session, mut td TDLib, chat_id i64, message_id i64, option_ids []int) !json2.Any {
	mut ids := []json2.Any{cap: option_ids.len}
	for id in option_ids {
		ids << json2.Any(id)
	}
	req := new_request('setPollAnswer').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).with_arr('option_ids', ids).build()!
	return s.send_sync(mut td, req)
}

// stop_poll closes an active poll so that no new answers can be submitted.
// Only the poll creator or a chat admin can stop a poll.
fn stop_poll(s Session, mut td TDLib, chat_id i64, message_id i64) !json2.Any {
	req := new_request('stopPoll').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).build()!
	return s.send_sync(mut td, req)
}

// send_dice sends an animated dice emoji.
// emoji: the emoji string identifying the dice type (e.g. a die, a dart target,
// a basketball, etc.).  Pass the emoji character as a runtime string value.
// Note: do not hard-code non-ASCII characters in source files.  Instead, store
// the emoji string in a variable or constant defined at runtime or in a
// dedicated constants file.
fn send_dice(s Session, mut td TDLib, chat_id i64, emoji string, opts SendOptions) !json2.Any {
	content := typed_obj('inputMessageDice', {
		'emoji':       json2.Any(emoji)
		'clear_draft': json2.Any(false)
	})
	return dispatch_send_message(s, mut td, chat_id, content, opts, json2.Any(map[string]json2.Any{}))
}

// --- File helpers ---

// get_file returns the current metadata for a TDLib file by its integer ID.
fn get_file(s Session, mut td TDLib, file_id i64) !TDFile {
	req := new_request('getFile').with_i64('file_id', file_id).build()!
	resp := s.send_sync(mut td, req)!
	return TDFile.from(resp.as_map())
}

// --- Search helpers ---

// search_public_chat finds a public chat by its @username.
fn search_public_chat(s Session, mut td TDLib, username string) !Chat {
	clean := if username.starts_with('@') { username[1..] } else { username }
	req := new_request('searchPublicChat').with_str('username', clean).build()!
	resp := s.send_sync(mut td, req)!
	return Chat.from(resp.as_map())
}

// search_messages_in_chat searches for messages containing a query string in a chat.
// Returns up to limit messages. Pass from_message_id=0 to start from the newest.
//
// BUG FIX: The previous implementation omitted the required 'filter' parameter.
// TDLib's searchChatMessages schema:
//   searchChatMessages chat_id from_message_id offset limit query
//     sender_id:MessageSender? filter:SearchMessagesFilter message_thread_id
// Omitting 'filter' caused TDLib to reject the request.  Pass
// searchMessagesFilterEmpty to search all message types.
fn search_messages_in_chat(s Session, mut td TDLib, chat_id i64, query string, from_message_id i64, limit int) ![]Message {
	req := new_request('searchChatMessages').with_i64('chat_id', chat_id).with_str('query',
		query).with_i64('from_message_id', from_message_id).with_int('offset', 0).with_int('limit',
		limit).with_obj('filter', {
		'@type': json2.Any('searchMessagesFilterEmpty')
	}).build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'messages')
	mut out := []Message{cap: raw_arr.len}
	for rm in raw_arr {
		out << Message.from(rm.as_map())
	}
	return out
}

// get_user_profile_photos returns the most recent profile photos of a user.
fn get_user_profile_photos(s Session, mut td TDLib, user_id i64, limit int) ![]Photo {
	req := new_request('getUserProfilePhotos').with_i64('user_id', user_id).with_int('offset',
		0).with_int('limit', limit).build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'photos')
	mut out := []Photo{cap: raw_arr.len}
	for item in raw_arr {
		out << Photo.from(item.as_map())
	}
	return out
}

// --- Message copying ---

// copy_message sends a copy of a message to another chat without the
// "Forwarded from" attribution header.
//
// Unlike forward_messages(), the recipient sees a normal message with no
// forwarding header.  Only one message can be copied per call.
fn copy_message(s Session, mut td TDLib, to_chat_id i64, from_chat_id i64, message_id i64, remove_caption bool, opts SendOptions) !json2.Any {
	mut req := new_request('forwardMessages').with_i64('chat_id', to_chat_id).with_i64('from_chat_id',
		from_chat_id).with('message_ids', arr_of_i64([message_id])).with_bool('send_copy',
		true).with_bool('remove_caption', remove_caption)
	if opts.silent || opts.protect_content {
		req = req.with_obj('options', {
			'@type':                json2.Any('messageSendOptions')
			'disable_notification': json2.Any(opts.silent)
			'protect_content':      json2.Any(opts.protect_content)
		})
	}
	// BUG FIX: reply_to_message_id from SendOptions was silently ignored.
	// All other send functions honour this field; copy_message must too.
	if opts.reply_to_message_id != 0 {
		req = req.with_obj('reply_to', {
			'@type':      json2.Any('inputMessageReplyToMessage')
			'chat_id':    json2.Any(to_chat_id)
			'message_id': json2.Any(opts.reply_to_message_id)
		})
	}
	return s.send_sync(mut td, req.build()!)
}

// --- Admin promotion / demotion ---

// AdminRights controls what a promoted chat administrator is allowed to do.
// All fields default to false.  Use full_admin_rights() for a fully-powered admin.
//
// Note: can_post_messages and can_edit_messages are only meaningful for
// channel admins; they are ignored in regular groups and supergroups.
pub struct AdminRights {
pub:
	can_manage_chat        bool // access admin log, statistics, and member list
	can_change_info        bool // change title, description, photo
	can_post_messages      bool // channels: post messages
	can_edit_messages      bool // channels: edit others' messages
	can_delete_messages    bool // delete others' messages
	can_invite_users       bool // add members or create invite links
	can_restrict_members   bool // ban, kick, or mute members
	can_pin_messages       bool // pin and unpin messages
	can_promote_members    bool // add/remove other admins (dangerous)
	can_manage_video_chats bool // start/stop video chats
	is_anonymous           bool // admin name shown as the channel name
	// The following fields are part of chatAdministratorRights in current TDLib.
	can_manage_topics          bool // forum supergroups: create/close/hide topics
	can_post_stories           bool // supergroups/channels: post stories to chat page
	can_edit_stories           bool // supergroups/channels: edit others' stories and pin stories
	can_delete_stories         bool // supergroups/channels: delete others' stories
	can_manage_direct_messages bool // channels: answer channel direct messages
}

// full_admin_rights returns AdminRights with every permission enabled and
// is_anonymous set to false.
pub fn full_admin_rights() AdminRights {
	return AdminRights{
		can_manage_chat:            true
		can_change_info:            true
		can_post_messages:          true
		can_edit_messages:          true
		can_delete_messages:        true
		can_invite_users:           true
		can_restrict_members:       true
		can_pin_messages:           true
		can_promote_members:        true
		can_manage_video_chats:     true
		is_anonymous:               false
		can_manage_topics:          true
		can_post_stories:           true
		can_edit_stories:           true
		can_delete_stories:         true
		can_manage_direct_messages: true
	}
}

// promote_chat_member promotes user_id to administrator in chat_id with the
// given AdminRights.  custom_title sets an optional admin badge string (e.g.
// "Moderator"); pass '' to use the default "Administrator" label.
//
// The caller must already be an owner or an admin with can_promote_members.
fn promote_chat_member(s Session, mut td TDLib, chat_id i64, user_id i64, rights AdminRights, custom_title string) !json2.Any {
	rights_obj := {
		'@type':                      json2.Any('chatAdministratorRights')
		'can_manage_chat':            json2.Any(rights.can_manage_chat)
		'can_change_info':            json2.Any(rights.can_change_info)
		'can_post_messages':          json2.Any(rights.can_post_messages)
		'can_edit_messages':          json2.Any(rights.can_edit_messages)
		'can_delete_messages':        json2.Any(rights.can_delete_messages)
		'can_invite_users':           json2.Any(rights.can_invite_users)
		'can_restrict_members':       json2.Any(rights.can_restrict_members)
		'can_pin_messages':           json2.Any(rights.can_pin_messages)
		'can_promote_members':        json2.Any(rights.can_promote_members)
		'can_manage_video_chats':     json2.Any(rights.can_manage_video_chats)
		'is_anonymous':               json2.Any(rights.is_anonymous)
		'can_manage_topics':          json2.Any(rights.can_manage_topics)
		'can_post_stories':           json2.Any(rights.can_post_stories)
		'can_edit_stories':           json2.Any(rights.can_edit_stories)
		'can_delete_stories':         json2.Any(rights.can_delete_stories)
		'can_manage_direct_messages': json2.Any(rights.can_manage_direct_messages)
	}
	req := new_request('setChatMemberStatus').with_i64('chat_id', chat_id).with_obj('member_id',
		{
		'@type':   json2.Any('messageSenderUser')
		'user_id': json2.Any(user_id)
	}).with_obj('status', {
		'@type':         json2.Any('chatMemberStatusAdministrator')
		'custom_title':  json2.Any(custom_title)
		'can_be_edited': json2.Any(true)
		'rights':        json2.Any(rights_obj)
	}).build()!
	return s.send_sync(mut td, req)
}

// demote_chat_member removes administrator privileges from user_id in chat_id,
// restoring them to a regular member.
fn demote_chat_member(s Session, mut td TDLib, chat_id i64, user_id i64) !json2.Any {
	req := new_request('setChatMemberStatus').with_i64('chat_id', chat_id).with_obj('member_id',
		{
		'@type':   json2.Any('messageSenderUser')
		'user_id': json2.Any(user_id)
	}).with_obj('status', {
		'@type': json2.Any('chatMemberStatusMember')
	}).build()!
	return s.send_sync(mut td, req)
}

// --- Pinning (group-level) ---

// unpin_all_messages removes all pinned messages from a chat at once.
// Requires pin_messages admin right.
fn unpin_all_messages(s Session, mut td TDLib, chat_id i64) !json2.Any {
	req := new_request('unpinAllChatMessages').with_i64('chat_id', chat_id).build()!
	return s.send_sync(mut td, req)
}

// --- Slow mode ---

// set_slow_mode sets the minimum interval between messages for non-admin members.
// delay_seconds must be one of: 0 (off), 10, 30, 60, 300, 900, 3600.
// Requires change_info admin right.
fn set_slow_mode(s Session, mut td TDLib, chat_id i64, delay_seconds int) !json2.Any {
	req := new_request('setChatSlowModeDelay').with_i64('chat_id', chat_id).with_int('slow_mode_delay',
		delay_seconds).build()!
	return s.send_sync(mut td, req)
}

// --- Profile photo management ---

// delete_profile_photo removes a specific profile photo by its ID.
// Only available on UserAccount (bots use set_profile_photo exclusively).
fn delete_profile_photo(s Session, mut td TDLib, profile_photo_id i64) !json2.Any {
	req := new_request('deleteProfilePhoto').with_i64('profile_photo_id', profile_photo_id).build()!
	return s.send_sync(mut td, req)
}

// --- Extended user information ---

// get_user_full_info returns the extended profile information for a user.
// This includes the bio, call settings, common group count, and profile photos.
// The returned UserFullInfo wraps the TDLib userFullInfo object.
fn get_user_full_info(s Session, mut td TDLib, user_id i64) !UserFullInfo {
	req := new_request('getUserFullInfo').with_i64('user_id', user_id).build()!
	resp := s.send_sync(mut td, req)!
	return UserFullInfo.from(resp.as_map())
}

// --- Extended supergroup / channel information ---

// get_supergroup_full_info returns the extended information for a supergroup or channel.
// supergroup_id is the bare positive integer from Chat.supergroup_id().
// The returned SupergroupFullInfo wraps the TDLib supergroupFullInfo object and
// exposes: description, member counts, invite link, profile photo, slow mode delay,
// linked chat ID, sticker set IDs, and capability flags.
fn get_supergroup_full_info(s Session, mut td TDLib, supergroup_id i64) !SupergroupFullInfo {
	req := new_request('getSupergroupFullInfo').with_i64('supergroup_id', supergroup_id).build()!
	resp := s.send_sync(mut td, req)!
	return SupergroupFullInfo.from(resp.as_map())
}

// --- Chat profile photo history ---

// get_chat_photo_history returns the full profile photo history for a chat
// (user, group, supergroup, or channel).
// offset: number of photos to skip for pagination.
// limit: maximum number of photos to return.
// Each element is a ChatPhoto exposing id(), added_date(), and sizes().
fn get_chat_photo_history(s Session, mut td TDLib, chat_id i64, offset int, limit int) ![]ChatPhoto {
	req := new_request('getChatPhotoHistory').with_i64('chat_id', chat_id).with_int('offset',
		offset).with_int('limit', limit).build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'photos')
	mut out := []ChatPhoto{cap: raw_arr.len}
	for item in raw_arr {
		out << ChatPhoto.from(item.as_map())
	}
	return out
}
