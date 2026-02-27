// tdlib/topics.v
// Forum topic management for supergroups with the "is_forum" flag set.
//
// Forum supergroups organize messages into named threads called "topics".
// Each topic behaves like a sub-chat: messages sent to it carry a
// message_thread_id that identifies the topic.
//
// --- Creating and using topics ---
//
//   // Create a new topic.
//   info := user.create_forum_topic(chat_id, 'Announcements', 0, '')!
//   thread_id := info.message_thread_id()
//
//   // Send a message inside the topic.
//   user.send_text_opts(chat_id, 'Hello topic!',
//       tdlib.SendOptions{ message_thread_id: thread_id })!
//
//   // List all topics.
//   topics := user.get_forum_topics(chat_id, '', 0, 0, 0, 20)!
//   for t in topics {
//       println('${t.info().name()} thread=${t.info().message_thread_id()}')
//   }
//
//   // Close (archive) a topic.
//   user.close_forum_topic(chat_id, thread_id)!
//
//   // Delete a topic and all its messages.
//   user.delete_forum_topic(chat_id, thread_id)!
//
// Topic management is available on both UserAccount (with appropriate admin
// rights) and BotAccount (when the bot has can_manage_topics or is an admin).
module tdlib

import x.json2

// --- Types ---

// ForumTopicInfo wraps the TDLib forumTopicInfo object.
//
// TDLib schema: forumTopicInfo message_thread_id:int53 name:string
//   icon:forumTopicIcon creation_date:int32 creator_id:MessageSender
//   is_outgoing:bool is_closed:bool is_hidden:bool is_editable:bool
//   is_pinned:bool has_icon:bool
pub struct ForumTopicInfo {
pub:
	raw map[string]json2.Any
}

pub fn ForumTopicInfo.from(m map[string]json2.Any) ForumTopicInfo {
	return ForumTopicInfo{
		raw: m
	}
}

// message_thread_id returns the topic's thread ID.
// Use this value as SendOptions.message_thread_id when sending to this topic.
pub fn (fi ForumTopicInfo) message_thread_id() i64 {
	return map_i64(fi.raw, 'message_thread_id')
}

// name returns the display name of the topic.
pub fn (fi ForumTopicInfo) name() string {
	return map_str(fi.raw, 'name')
}

// creation_date returns the Unix timestamp when the topic was created.
pub fn (fi ForumTopicInfo) creation_date() i64 {
	return map_i64(fi.raw, 'creation_date')
}

// is_closed returns true when the topic has been closed (archived).
// Closed topics still display their history but no new messages can be posted.
pub fn (fi ForumTopicInfo) is_closed() bool {
	return map_bool(fi.raw, 'is_closed')
}

// is_hidden returns true when the topic is hidden from the topic list.
// Only the "General" topic can be hidden by supergroup admins.
pub fn (fi ForumTopicInfo) is_hidden() bool {
	return map_bool(fi.raw, 'is_hidden')
}

// is_pinned returns true when the topic is pinned at the top of the topic list.
pub fn (fi ForumTopicInfo) is_pinned() bool {
	return map_bool(fi.raw, 'is_pinned')
}

// is_outgoing returns true when the current account created this topic.
pub fn (fi ForumTopicInfo) is_outgoing() bool {
	return map_bool(fi.raw, 'is_outgoing')
}

// icon_custom_emoji_id returns the custom emoji ID used as the topic icon, or 0
// when the topic uses a built-in coloured icon.
pub fn (fi ForumTopicInfo) icon_custom_emoji_id() i64 {
	return map_i64(map_obj(fi.raw, 'icon'), 'custom_emoji_id')
}

// icon_color returns the ARGB colour integer of the built-in topic icon,
// or 0 when a custom emoji icon is used.
pub fn (fi ForumTopicInfo) icon_color() int {
	return map_int(map_obj(fi.raw, 'icon'), 'color')
}

// creator_user_id returns the user ID of the member who created the topic,
// or 0 when the creator is anonymous or a chat.
pub fn (fi ForumTopicInfo) creator_user_id() i64 {
	c := map_obj(fi.raw, 'creator_id')
	if map_str(c, '@type') == 'messageSenderUser' {
		return map_i64(c, 'user_id')
	}
	return 0
}

// --- ForumTopic ---

// ForumTopic wraps the TDLib forumTopic object returned by getForumTopics.
//
// TDLib schema: forumTopic info:forumTopicInfo last_message:message?
//   is_pinned:bool unread_count:int32 last_read_inbox_message_id:int53
//   last_read_outbox_message_id:int53 unread_mention_count:int32
//   unread_reaction_count:int32 notification_settings:chatNotificationSettings
//   draft_message:draftMessage?
pub struct ForumTopic {
pub:
	raw map[string]json2.Any
}

pub fn ForumTopic.from(m map[string]json2.Any) ForumTopic {
	return ForumTopic{
		raw: m
	}
}

// info returns the ForumTopicInfo summary of this topic.
pub fn (ft ForumTopic) info() ForumTopicInfo {
	return ForumTopicInfo.from(map_obj(ft.raw, 'info'))
}

// is_pinned returns true when the topic is pinned in the forum list.
pub fn (ft ForumTopic) is_pinned() bool {
	return map_bool(ft.raw, 'is_pinned')
}

// unread_count returns the number of unread messages in this topic.
pub fn (ft ForumTopic) unread_count() int {
	return map_int(ft.raw, 'unread_count')
}

// unread_mention_count returns the number of unread @mentions in this topic.
pub fn (ft ForumTopic) unread_mention_count() int {
	return map_int(ft.raw, 'unread_mention_count')
}

// unread_reaction_count returns the number of unread reactions in this topic.
pub fn (ft ForumTopic) unread_reaction_count() int {
	return map_int(ft.raw, 'unread_reaction_count')
}

// last_message returns the most recent message posted to this topic, if any.
pub fn (ft ForumTopic) last_message() ?Message {
	m := map_obj(ft.raw, 'last_message')
	if m.len == 0 {
		return none
	}
	return Message.from(m)
}

// --- Implementation functions ---

// create_forum_topic creates a new topic inside a forum supergroup.
//
// name: display name of the topic (1-128 characters).
// icon_color: ARGB color integer for the built-in colored icon.
//   Allowed values: 0x6FB9F0, 0xFFD67E, 0xCB86DB, 0x8EEE98, 0xFF93B2, 0xFB6F5F.
//   Pass 0 to let Telegram choose automatically.
// icon_custom_emoji_id: custom emoji document ID for the icon.
//   Pass '' to use the built-in color icon instead.
//
// Returns the ForumTopicInfo of the newly created topic.
// Use ForumTopicInfo.message_thread_id() to send messages to the new topic.
fn create_forum_topic(s Session, mut td TDLib, chat_id i64, name string, icon_color int, icon_custom_emoji_id string) !ForumTopicInfo {
	mut icon := map[string]json2.Any{}
	icon['@type'] = json2.Any('forumTopicIcon')
	if icon_color != 0 {
		icon['color'] = json2.Any(icon_color)
	}
	if icon_custom_emoji_id != '' {
		icon['custom_emoji_id'] = json2.Any(icon_custom_emoji_id.i64())
	}
	req := new_request('createForumTopic').with_i64('chat_id', chat_id).with_str('name',
		name).with_obj('icon', icon).build()!
	resp := s.send_sync(mut td, req)!
	return ForumTopicInfo.from(resp.as_map())
}

// edit_forum_topic changes the name and/or icon of an existing topic.
// Pass the same name to leave it unchanged; pass icon_custom_emoji_id='' to
// keep the existing icon.
fn edit_forum_topic(s Session, mut td TDLib, chat_id i64, message_thread_id i64, name string, icon_custom_emoji_id string) !json2.Any {
	mut req := new_request('editForumTopic').with_i64('chat_id', chat_id).with_i64('message_thread_id',
		message_thread_id).with_str('name', name)
	if icon_custom_emoji_id != '' {
		req = req.with_i64('icon_custom_emoji_id', icon_custom_emoji_id.i64())
	}
	return s.send_sync(mut td, req.build()!)
}

// close_forum_topic archives a topic so no new messages can be posted.
// The topic history remains accessible; use reopen_forum_topic to reverse.
fn close_forum_topic(s Session, mut td TDLib, chat_id i64, message_thread_id i64) !json2.Any {
	req := new_request('closeForumTopic').with_i64('chat_id', chat_id).with_i64('message_thread_id',
		message_thread_id).build()!
	return s.send_sync(mut td, req)
}

// reopen_forum_topic re-opens a previously closed topic.
fn reopen_forum_topic(s Session, mut td TDLib, chat_id i64, message_thread_id i64) !json2.Any {
	req := new_request('reopenForumTopic').with_i64('chat_id', chat_id).with_i64('message_thread_id',
		message_thread_id).build()!
	return s.send_sync(mut td, req)
}

// delete_forum_topic permanently deletes a topic and all of its messages.
// Requires the delete_messages admin right.
fn delete_forum_topic(s Session, mut td TDLib, chat_id i64, message_thread_id i64) !json2.Any {
	req := new_request('deleteForumTopic').with_i64('chat_id', chat_id).with_i64('message_thread_id',
		message_thread_id).build()!
	return s.send_sync(mut td, req)
}

// pin_forum_topic pins or unpins a topic in the forum topic list.
// Requires the pin_messages admin right.
fn pin_forum_topic(s Session, mut td TDLib, chat_id i64, message_thread_id i64, is_pinned bool) !json2.Any {
	req := new_request('toggleForumTopicIsPinned').with_i64('chat_id', chat_id).with_i64('message_thread_id',
		message_thread_id).with_bool('is_pinned', is_pinned).build()!
	return s.send_sync(mut td, req)
}

// hide_general_forum_topic hides or shows the "General" topic (always thread_id=1).
// Only supergroup owners can hide the General topic.
fn hide_general_forum_topic(s Session, mut td TDLib, chat_id i64, hide bool) !json2.Any {
	method := if hide { 'hideGeneralForumTopic' } else { 'unhideGeneralForumTopic' }
	req := new_request(method).with_i64('chat_id', chat_id).build()!
	return s.send_sync(mut td, req)
}

// get_forum_topics returns a paginated list of topics in a forum supergroup.
//
// query:              filter by topic name ('' for all topics).
// offset_date:        pagination cursor - Unix timestamp of the last topic seen (0 to start).
// offset_message_id:  pagination cursor - last message ID seen (0 to start).
// offset_message_thread_id: pagination cursor - last thread ID seen (0 to start).
// limit:              maximum number of topics to return.
//
// For the first call, pass offset_date=0, offset_message_id=0,
// offset_message_thread_id=0.  To fetch the next page, use the values from
// the last topic returned on the previous call.
fn get_forum_topics(s Session, mut td TDLib, chat_id i64, query string, offset_date i64, offset_message_id i64, offset_message_thread_id i64, limit int) ![]ForumTopic {
	req := new_request('getForumTopics').with_i64('chat_id', chat_id).with_str('query',
		query).with_i64('offset_date', offset_date).with_i64('offset_message_id', offset_message_id).with_i64('offset_message_thread_id',
		offset_message_thread_id).with_int('limit', limit).build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'topics')
	mut out := []ForumTopic{cap: raw_arr.len}
	for item in raw_arr {
		out << ForumTopic.from(item.as_map())
	}
	return out
}

// get_forum_topic returns the details of a single topic by its thread ID.
fn get_forum_topic(s Session, mut td TDLib, chat_id i64, message_thread_id i64) !ForumTopic {
	req := new_request('getForumTopic').with_i64('chat_id', chat_id).with_i64('message_thread_id',
		message_thread_id).build()!
	resp := s.send_sync(mut td, req)!
	return ForumTopic.from(resp.as_map())
}

// get_forum_topic_history returns messages from a specific forum topic.
// Equivalent to getChatHistory filtered to the topic thread.
// from_message_id: start after this message ID (0 = most recent).
// limit: maximum number of messages to return.
fn get_forum_topic_history(s Session, mut td TDLib, chat_id i64, message_thread_id i64, from_message_id i64, limit int) ![]Message {
	req := new_request('getMessageThreadHistory').with_i64('chat_id', chat_id).with_i64('message_id',
		message_thread_id).with_i64('from_message_id', from_message_id).with_int('offset',
		0).with_int('limit', limit).build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'messages')
	mut out := []Message{cap: raw_arr.len}
	for rm in raw_arr {
		out << Message.from(rm.as_map())
	}
	return out
}
