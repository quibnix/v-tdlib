// tdlib/types.v
// Typed wrappers for common TDLib JSON objects.
//
// Instead of manually indexing raw maps, use these helpers:
//
//   msg := tdlib.Message.from(raw_map)
//   println('${msg.sender_user_id()} said: ${msg.text()}')
//
//   photo := msg.content().as_photo()?
//   if sz := photo.largest_size() {
//       println('Photo: ${sz.width()}x${sz.height()} file_id=${sz.file().id()}')
//   }
//
//   if thumb := vid.thumbnail() {
//       println('Thumb: ${thumb.width()}x${thumb.height()} file=${thumb.file().local_path()}')
//   }
//
// Extended user info (bio, profile photos, call settings):
//   full := user_acc.get_user_full_info(user_id)!
//   println('Bio: ${full.bio()}')
//   if cp := full.photo() { println('Photo id: ${cp.id()}') }
//
// Extended supergroup / channel info (description, invite link, photo, counts):
//   sgfi := user_acc.get_supergroup_full_info(chat.supergroup_id())!
//   println('Members: ${sgfi.member_count()}  Link: ${sgfi.invite_link_url()}')
//
// All profile photos for a chat:
//   photos := user_acc.get_chat_photo_history(chat_id, 0, 50)!
//   for p in photos { println('Photo id=${p.id()} added=${p.added_date()}') }
//
// Chat folder types (ChatFolderInfo, ChatFolder) are used by the folder
// management methods on UserAccount (get_chat_folders, create_chat_folder, etc.).
module tdlib

import x.json2
import encoding.base64

// --- Channel ID helper ---

// channel_id_to_chat_id converts a bare channel/supergroup ID (as returned in
// chatTypeSupergroup.supergroup_id) into the full chat ID used by all API calls.
//
// TDLib uses two different ID representations for channels and supergroups:
//
//   supergroup_id  — a bare positive integer used by object-level methods such as
//                    getSupergroup, getSupergroupFullInfo, getSupergroupMembers.
//                    This is what Chat.supergroup_id() returns.
//
//   chat_id        — the negative identifier required by every message/send/forward
//                    API call (sendMessage, forwardMessages, getChat, copyMessage, …).
//                    For channels and supergroups this is always -100XXXXXXXXX.
//                    This is what Chat.id() and Chat.channel_chat_id() return.
//
// Formula: chat_id = -(supergroup_id + 1_000_000_000_000)
//
// If the value is already negative (already a chat_id) it is returned unchanged,
// so this function is safe to call defensively.
pub fn channel_id_to_chat_id(id i64) i64 {
	if id <= 0 {
		return id
	}
	return -(id + 1_000_000_000_000)
}

// --- Low-level map helpers ---
// Exported so callers can work with raw json2.Any maps from update handlers.

// map_str extracts a string field, returning '' if absent.
pub fn map_str(m map[string]json2.Any, key string) string {
	v := m[key] or { return '' }
	return v.str()
}

// map_i64 extracts an i64 field, handling int/f64/string variants.
pub fn map_i64(m map[string]json2.Any, key string) i64 {
	v := m[key] or { return 0 }
	return any_to_i64(v)
}

// map_int extracts an int field.
pub fn map_int(m map[string]json2.Any, key string) int {
	return int(map_i64(m, key))
}

// map_bool extracts a bool field.
pub fn map_bool(m map[string]json2.Any, key string) bool {
	v := m[key] or { return false }
	if v is bool {
		return v
	}
	s := v.str()
	return s == 'true' || s == '1'
}

// map_arr extracts an array field, returning [] if absent or wrong type.
pub fn map_arr(m map[string]json2.Any, key string) []json2.Any {
	v := m[key] or { return [] }
	if v is []json2.Any {
		return v as []json2.Any
	}
	return []
}

// map_obj extracts a nested object field, returning {} if absent.
pub fn map_obj(m map[string]json2.Any, key string) map[string]json2.Any {
	v := m[key] or { return map[string]json2.Any{} }
	return v.as_map()
}

// map_type returns the @type of a nested field, or '' if absent.
pub fn map_type(m map[string]json2.Any, key string) string {
	return map_str(map_obj(m, key), '@type')
}

// any_to_i64 coerces any numeric json2.Any variant to i64.
pub fn any_to_i64(v json2.Any) i64 {
	if v is i64 {
		return v
	}
	if v is int {
		return i64(int(v))
	}
	if v is f64 {
		return i64(f64(v))
	}
	if v is f32 {
		return i64(f32(v))
	}
	if v is i8 {
		return i64(i8(v))
	}
	if v is i16 {
		return i64(i16(v))
	}
	if v is u8 {
		return i64(u8(v))
	}
	if v is u16 {
		return i64(u16(v))
	}
	if v is u32 {
		return i64(u32(v))
	}
	if v is u64 {
		return i64(u64(v))
	}
	if v is string {
		return string(v).i64()
	}
	return 0
}

// --- TDFile ---

pub struct TDFile {
pub:
	raw map[string]json2.Any
}

pub fn TDFile.from(m map[string]json2.Any) TDFile {
	return TDFile{
		raw: m
	}
}

pub fn (f TDFile) id() i64 {
	return map_i64(f.raw, 'id')
}

pub fn (f TDFile) size() i64 {
	return map_i64(f.raw, 'size')
}

pub fn (f TDFile) expected_size() i64 {
	return map_i64(f.raw, 'expected_size')
}

pub fn (f TDFile) remote_id() string {
	return map_str(map_obj(f.raw, 'remote'), 'id')
}

pub fn (f TDFile) remote_unique_id() string {
	return map_str(map_obj(f.raw, 'remote'), 'unique_id')
}

pub fn (f TDFile) local_path() string {
	return map_str(map_obj(f.raw, 'local'), 'path')
}

pub fn (f TDFile) is_downloaded() bool {
	return map_bool(map_obj(f.raw, 'local'), 'is_downloading_completed')
}

pub fn (f TDFile) is_downloading() bool {
	return map_bool(map_obj(f.raw, 'local'), 'is_downloading_active')
}

pub fn (f TDFile) downloaded_size() i64 {
	return map_i64(map_obj(f.raw, 'local'), 'downloaded_size')
}

pub fn (f TDFile) can_be_downloaded() bool {
	return map_bool(map_obj(f.raw, 'local'), 'can_be_downloaded')
}

// --- PhotoSize ---
// Wraps TDLib's photoSize object (used in Photo.sizes() and similar photo arrays).
// Fields: type:string  photo:file  width:int32  height:int32
//
// NOTE: This is NOT the same as TDLib's thumbnail object.
// Media thumbnails (Video.thumbnail, Audio.thumbnail, etc.) use the Thumbnail type below.

pub struct PhotoSize {
pub:
	raw map[string]json2.Any
}

pub fn PhotoSize.from(m map[string]json2.Any) PhotoSize {
	return PhotoSize{
		raw: m
	}
}

pub fn (p PhotoSize) size_type() string {
	return map_str(p.raw, 'type')
}

pub fn (p PhotoSize) width() int {
	return map_int(p.raw, 'width')
}

pub fn (p PhotoSize) height() int {
	return map_int(p.raw, 'height')
}

// file returns the underlying TDLib File.
// The photoSize object stores the file under the key "photo".
pub fn (p PhotoSize) file() TDFile {
	return TDFile.from(map_obj(p.raw, 'photo'))
}

// --- Thumbnail ---
// Wraps TDLib's thumbnail object returned for media attachments
// (Video, Audio, Document, Sticker, Animation, VideoNote).
//
// TDLib schema: thumbnail format:ThumbnailFormat width:int32 height:int32 file:file
//
// BUG FIX: The previous code returned ?PhotoSize for all thumbnail() methods, but
// thumbnail objects use "file" (not "photo") for the file field, causing PhotoSize.file()
// to always return an empty TDFile. A dedicated Thumbnail struct fixes this.

pub struct Thumbnail {
pub:
	raw map[string]json2.Any
}

pub fn Thumbnail.from(m map[string]json2.Any) Thumbnail {
	return Thumbnail{
		raw: m
	}
}

pub fn (t Thumbnail) width() int {
	return map_int(t.raw, 'width')
}

pub fn (t Thumbnail) height() int {
	return map_int(t.raw, 'height')
}

// file returns the underlying TDLib File.
// The thumbnail object stores the file under the key "file" (not "photo").
pub fn (t Thumbnail) file() TDFile {
	return TDFile.from(map_obj(t.raw, 'file'))
}

// format_type returns the @type string of the thumbnail format, e.g.
// "thumbnailFormatJpeg", "thumbnailFormatPng", "thumbnailFormatWebp",
// "thumbnailFormatTgs", "thumbnailFormatWebm", "thumbnailFormatMpeg4".
pub fn (t Thumbnail) format_type() string {
	return map_str(map_obj(t.raw, 'format'), '@type')
}

// --- Photo ---

pub struct Photo {
pub:
	raw map[string]json2.Any
}

pub fn Photo.from(m map[string]json2.Any) Photo {
	return Photo{
		raw: m
	}
}

pub fn (p Photo) id() i64 {
	return map_i64(p.raw, 'id')
}

pub fn (p Photo) has_stickers() bool {
	return map_bool(p.raw, 'has_stickers')
}

// sizes returns all available PhotoSize variants, smallest to largest.
pub fn (p Photo) sizes() []PhotoSize {
	raw_arr := map_arr(p.raw, 'sizes')
	mut out := []PhotoSize{cap: raw_arr.len}
	for item in raw_arr {
		out << PhotoSize.from(item.as_map())
	}
	return out
}

// largest_size returns the highest-resolution PhotoSize, or none if empty.
pub fn (p Photo) largest_size() ?PhotoSize {
	sizes := p.sizes()
	if sizes.len == 0 {
		return none
	}
	return sizes[sizes.len - 1]
}

// smallest_size returns the thumbnail PhotoSize, or none if empty.
pub fn (p Photo) smallest_size() ?PhotoSize {
	sizes := p.sizes()
	if sizes.len == 0 {
		return none
	}
	return sizes[0]
}

// --- Video ---

pub struct Video {
pub:
	raw map[string]json2.Any
}

pub fn Video.from(m map[string]json2.Any) Video {
	return Video{
		raw: m
	}
}

pub fn (v Video) duration() int {
	return map_int(v.raw, 'duration')
}

pub fn (v Video) width() int {
	return map_int(v.raw, 'width')
}

pub fn (v Video) height() int {
	return map_int(v.raw, 'height')
}

pub fn (v Video) file_name() string {
	return map_str(v.raw, 'file_name')
}

pub fn (v Video) mime_type() string {
	return map_str(v.raw, 'mime_type')
}

pub fn (v Video) supports_streaming() bool {
	return map_bool(v.raw, 'supports_streaming')
}

pub fn (v Video) file() TDFile {
	return TDFile.from(map_obj(v.raw, 'video'))
}

// thumbnail returns the video thumbnail as a Thumbnail (not PhotoSize).
// TDLib schema: video thumbnail:thumbnail - uses the thumbnail object type with
// field "file", not the photoSize type with field "photo".
pub fn (v Video) thumbnail() ?Thumbnail {
	m := map_obj(v.raw, 'thumbnail')
	if m.len == 0 {
		return none
	}
	return Thumbnail.from(m)
}

// --- Audio ---

pub struct Audio {
pub:
	raw map[string]json2.Any
}

pub fn Audio.from(m map[string]json2.Any) Audio {
	return Audio{
		raw: m
	}
}

pub fn (a Audio) duration() int {
	return map_int(a.raw, 'duration')
}

pub fn (a Audio) title() string {
	return map_str(a.raw, 'title')
}

pub fn (a Audio) performer() string {
	return map_str(a.raw, 'performer')
}

pub fn (a Audio) file_name() string {
	return map_str(a.raw, 'file_name')
}

pub fn (a Audio) mime_type() string {
	return map_str(a.raw, 'mime_type')
}

pub fn (a Audio) file() TDFile {
	return TDFile.from(map_obj(a.raw, 'audio'))
}

// thumbnail returns the album cover thumbnail as a Thumbnail (not PhotoSize).
// TDLib schema: audio album_cover_thumbnail:thumbnail - uses the thumbnail type.
pub fn (a Audio) thumbnail() ?Thumbnail {
	m := map_obj(a.raw, 'album_cover_thumbnail')
	if m.len == 0 {
		return none
	}
	return Thumbnail.from(m)
}

// --- VoiceNote ---

pub struct VoiceNote {
pub:
	raw map[string]json2.Any
}

pub fn VoiceNote.from(m map[string]json2.Any) VoiceNote {
	return VoiceNote{
		raw: m
	}
}

pub fn (v VoiceNote) duration() int {
	return map_int(v.raw, 'duration')
}

pub fn (v VoiceNote) mime_type() string {
	return map_str(v.raw, 'mime_type')
}

pub fn (v VoiceNote) file() TDFile {
	return TDFile.from(map_obj(v.raw, 'voice'))
}

// waveform returns the raw PCM waveform bytes for this voice note.
// TDLib encodes the waveform as a base64 string in the JSON response.
// Returns an empty slice when no waveform data is available.
pub fn (v VoiceNote) waveform() []u8 {
	raw := map_str(v.raw, 'waveform')
	if raw == '' {
		return []
	}
	return base64.decode(raw)
}

// --- VideoNote ---

pub struct VideoNote {
pub:
	raw map[string]json2.Any
}

pub fn VideoNote.from(m map[string]json2.Any) VideoNote {
	return VideoNote{
		raw: m
	}
}

pub fn (v VideoNote) duration() int {
	return map_int(v.raw, 'duration')
}

pub fn (v VideoNote) length() int {
	return map_int(v.raw, 'length')
}

pub fn (v VideoNote) file() TDFile {
	return TDFile.from(map_obj(v.raw, 'video'))
}

// thumbnail returns the video note thumbnail as a Thumbnail (not PhotoSize).
// TDLib schema: videoNote thumbnail:thumbnail - uses the thumbnail type.
pub fn (v VideoNote) thumbnail() ?Thumbnail {
	m := map_obj(v.raw, 'thumbnail')
	if m.len == 0 {
		return none
	}
	return Thumbnail.from(m)
}

// --- Document ---

pub struct Document {
pub:
	raw map[string]json2.Any
}

pub fn Document.from(m map[string]json2.Any) Document {
	return Document{
		raw: m
	}
}

pub fn (d Document) file_name() string {
	return map_str(d.raw, 'file_name')
}

pub fn (d Document) mime_type() string {
	return map_str(d.raw, 'mime_type')
}

pub fn (d Document) file() TDFile {
	return TDFile.from(map_obj(d.raw, 'document'))
}

// thumbnail returns the document thumbnail as a Thumbnail (not PhotoSize).
// TDLib schema: document thumbnail:thumbnail - uses the thumbnail type.
pub fn (d Document) thumbnail() ?Thumbnail {
	m := map_obj(d.raw, 'thumbnail')
	if m.len == 0 {
		return none
	}
	return Thumbnail.from(m)
}

// --- Sticker ---

pub struct Sticker {
pub:
	raw map[string]json2.Any
}

pub fn Sticker.from(m map[string]json2.Any) Sticker {
	return Sticker{
		raw: m
	}
}

pub fn (s Sticker) set_id() i64 {
	return map_i64(s.raw, 'set_id')
}

pub fn (s Sticker) width() int {
	return map_int(s.raw, 'width')
}

pub fn (s Sticker) height() int {
	return map_int(s.raw, 'height')
}

pub fn (s Sticker) emoji() string {
	return map_str(s.raw, 'emoji')
}

// format returns the sticker format @type:
// stickerFormatWebp, stickerFormatTgs, or stickerFormatWebm.
pub fn (s Sticker) format() string {
	return map_type(s.raw, 'format')
}

pub fn (s Sticker) file() TDFile {
	return TDFile.from(map_obj(s.raw, 'sticker'))
}

// thumbnail returns the sticker thumbnail as a Thumbnail (not PhotoSize).
// TDLib schema: sticker thumbnail:thumbnail - uses the thumbnail type.
pub fn (s Sticker) thumbnail() ?Thumbnail {
	m := map_obj(s.raw, 'thumbnail')
	if m.len == 0 {
		return none
	}
	return Thumbnail.from(m)
}

// --- Animation (GIF) ---

pub struct Animation {
pub:
	raw map[string]json2.Any
}

pub fn Animation.from(m map[string]json2.Any) Animation {
	return Animation{
		raw: m
	}
}

pub fn (a Animation) duration() int {
	return map_int(a.raw, 'duration')
}

pub fn (a Animation) width() int {
	return map_int(a.raw, 'width')
}

pub fn (a Animation) height() int {
	return map_int(a.raw, 'height')
}

pub fn (a Animation) file_name() string {
	return map_str(a.raw, 'file_name')
}

pub fn (a Animation) mime_type() string {
	return map_str(a.raw, 'mime_type')
}

pub fn (a Animation) file() TDFile {
	return TDFile.from(map_obj(a.raw, 'animation'))
}

// thumbnail returns the animation thumbnail as a Thumbnail (not PhotoSize).
// TDLib schema: animation thumbnail:thumbnail - uses the thumbnail type.
pub fn (a Animation) thumbnail() ?Thumbnail {
	m := map_obj(a.raw, 'thumbnail')
	if m.len == 0 {
		return none
	}
	return Thumbnail.from(m)
}

// --- Location ---

pub struct Location {
pub:
	raw map[string]json2.Any
}

pub fn Location.from(m map[string]json2.Any) Location {
	return Location{
		raw: m
	}
}

pub fn (l Location) latitude() f64 {
	v := l.raw['latitude'] or { return 0.0 }
	if v is f64 {
		return v
	}
	return v.str().f64()
}

pub fn (l Location) longitude() f64 {
	v := l.raw['longitude'] or { return 0.0 }
	if v is f64 {
		return v
	}
	return v.str().f64()
}

pub fn (l Location) horizontal_accuracy() f64 {
	v := l.raw['horizontal_accuracy'] or { return 0.0 }
	if v is f64 {
		return v
	}
	return v.str().f64()
}

// --- Contact ---

pub struct Contact {
pub:
	raw map[string]json2.Any
}

pub fn Contact.from(m map[string]json2.Any) Contact {
	return Contact{
		raw: m
	}
}

pub fn (c Contact) phone_number() string {
	return map_str(c.raw, 'phone_number')
}

pub fn (c Contact) first_name() string {
	return map_str(c.raw, 'first_name')
}

pub fn (c Contact) last_name() string {
	return map_str(c.raw, 'last_name')
}

pub fn (c Contact) user_id() i64 {
	return map_i64(c.raw, 'user_id')
}

// --- Poll ---
// Wraps the TDLib poll object returned inside messagePoll content.
//
// TDLib schema:
//   poll id:int64 question:formattedText options:vector<pollOption>
//        total_voter_count:int32 is_anonymous:bool type:PollType is_closed:bool
//
// PollType is one of:
//   pollTypeRegular  allow_multiple_answers:bool
//   pollTypeQuiz     correct_option_id:int32  explanation:formattedText

pub struct Poll {
pub:
	raw map[string]json2.Any
}

pub fn Poll.from(m map[string]json2.Any) Poll {
	return Poll{
		raw: m
	}
}

// id returns the unique poll identifier.
pub fn (p Poll) id() i64 {
	return map_i64(p.raw, 'id')
}

// question returns the poll question as plain text.
// TDLib stores the question as a formattedText object; this extracts the text field.
pub fn (p Poll) question() string {
	return map_str(map_obj(p.raw, 'question'), 'text')
}

// is_anonymous returns true when voter identities are hidden.
pub fn (p Poll) is_anonymous() bool {
	return map_bool(p.raw, 'is_anonymous')
}

// is_closed returns true when the poll has been stopped and no further votes
// can be submitted.
pub fn (p Poll) is_closed() bool {
	return map_bool(p.raw, 'is_closed')
}

// total_voter_count returns the number of users who have voted so far.
pub fn (p Poll) total_voter_count() int {
	return map_int(p.raw, 'total_voter_count')
}

// type_str returns the @type of the poll's type object:
//   "pollTypeRegular" for a regular poll.
//   "pollTypeQuiz"    for a quiz.
pub fn (p Poll) type_str() string {
	return map_type(p.raw, 'type')
}

// is_quiz returns true when this poll is a quiz (has a correct answer).
pub fn (p Poll) is_quiz() bool {
	return p.type_str() == 'pollTypeQuiz'
}

// options returns the raw pollOption array.
// Each element is a json2.Any map with fields:
//   text:formattedText  voter_count:int32  vote_percentage:int32  is_chosen:bool  is_being_chosen:bool
pub fn (p Poll) options() []json2.Any {
	return map_arr(p.raw, 'options')
}

// option_text returns the plain text of the poll option at zero-based index i.
// Returns '' when index is out of range.
pub fn (p Poll) option_text(i int) string {
	opts := p.options()
	if i < 0 || i >= opts.len {
		return ''
	}
	return map_str(map_obj(opts[i].as_map(), 'text'), 'text')
}

// --- User ---

pub struct User {
pub:
	raw map[string]json2.Any
}

pub fn User.from(m map[string]json2.Any) User {
	return User{
		raw: m
	}
}

pub fn (u User) id() i64 {
	return map_i64(u.raw, 'id')
}

pub fn (u User) first_name() string {
	return map_str(u.raw, 'first_name')
}

pub fn (u User) last_name() string {
	return map_str(u.raw, 'last_name')
}

pub fn (u User) phone_number() string {
	return map_str(u.raw, 'phone_number')
}

pub fn (u User) language_code() string {
	return map_str(u.raw, 'language_code')
}

pub fn (u User) is_verified() bool {
	return map_bool(u.raw, 'is_verified')
}

pub fn (u User) is_premium() bool {
	return map_bool(u.raw, 'is_premium')
}

pub fn (u User) is_support() bool {
	return map_bool(u.raw, 'is_support')
}

pub fn (u User) is_scam() bool {
	return map_bool(u.raw, 'is_scam')
}

pub fn (u User) is_fake() bool {
	return map_bool(u.raw, 'is_fake')
}

pub fn (u User) is_mutual_contact() bool {
	return map_bool(u.raw, 'is_mutual_contact')
}

// username returns the first active username from the usernames object.
// TDLib returns usernames as:
//   {"@type":"usernames","active_usernames":["abc_d123"],"editable_username":"abc_d123",...}
pub fn (u User) username() string {
	usernames_m := map_obj(u.raw, 'usernames')
	active := map_arr(usernames_m, 'active_usernames')
	if active.len == 0 {
		return ''
	}
	return active[0].str()
}

// full_name returns "First Last", or just "First" when last name is empty.
pub fn (u User) full_name() string {
	last := u.last_name()
	if last == '' {
		return u.first_name()
	}
	return '${u.first_name()} ${last}'
}

// is_bot returns true when the user's type is userTypeBot.
pub fn (u User) is_bot() bool {
	return map_type(u.raw, 'type') == 'userTypeBot'
}

// profile_photo_small returns the small profile photo file, if available.
pub fn (u User) profile_photo_small() ?TDFile {
	pp := map_obj(u.raw, 'profile_photo')
	if pp.len == 0 {
		return none
	}
	m := map_obj(pp, 'small')
	if m.len == 0 {
		return none
	}
	return TDFile.from(m)
}

// profile_photo_big returns the large profile photo file, if available.
pub fn (u User) profile_photo_big() ?TDFile {
	pp := map_obj(u.raw, 'profile_photo')
	if pp.len == 0 {
		return none
	}
	m := map_obj(pp, 'big')
	if m.len == 0 {
		return none
	}
	return TDFile.from(m)
}

// --- Chat ---

pub struct Chat {
pub:
	raw map[string]json2.Any
}

pub fn Chat.from(m map[string]json2.Any) Chat {
	return Chat{
		raw: m
	}
}

pub fn (c Chat) id() i64 {
	return map_i64(c.raw, 'id')
}

pub fn (c Chat) title() string {
	return map_str(c.raw, 'title')
}

pub fn (c Chat) unread_count() int {
	return map_int(c.raw, 'unread_count')
}

pub fn (c Chat) unread_mention_count() int {
	return map_int(c.raw, 'unread_mention_count')
}

pub fn (c Chat) is_marked_as_unread() bool {
	return map_bool(c.raw, 'is_marked_as_unread')
}

pub fn (c Chat) has_protected_content() bool {
	return map_bool(c.raw, 'has_protected_content')
}

pub fn (c Chat) chat_type() string {
	return map_type(c.raw, 'type')
}

pub fn (c Chat) is_private() bool {
	return c.chat_type() == 'chatTypePrivate'
}

pub fn (c Chat) is_group() bool {
	return c.chat_type() == 'chatTypeBasicGroup'
}

pub fn (c Chat) is_supergroup() bool {
	return c.chat_type() == 'chatTypeSupergroup' && !map_bool(map_obj(c.raw, 'type'), 'is_channel')
}

pub fn (c Chat) is_channel() bool {
	return c.chat_type() == 'chatTypeSupergroup' && map_bool(map_obj(c.raw, 'type'), 'is_channel')
}

pub fn (c Chat) is_secret() bool {
	return c.chat_type() == 'chatTypeSecret'
}

// private_user_id returns the peer user ID for private chats, or 0 for other types.
pub fn (c Chat) private_user_id() i64 {
	if c.is_private() {
		return map_i64(map_obj(c.raw, 'type'), 'user_id')
	}
	return 0
}

// supergroup_id returns the raw supergroup/channel ID from the chatTypeSupergroup
// type object, or 0 for other chat types.
//
// This is the bare positive integer required by object-level TDLib methods:
//   getSupergroup, getSupergroupFullInfo, getSupergroupMembers, etc.
//
// Do NOT pass this value to message or forwarding API calls — those require the
// full chat_id in -100XXXXXXXXX form. Use channel_chat_id() for that instead.
pub fn (c Chat) supergroup_id() i64 {
	if c.chat_type() == 'chatTypeSupergroup' {
		return map_i64(map_obj(c.raw, 'type'), 'supergroup_id')
	}
	return 0
}

// channel_chat_id returns the API-level chat ID (-100XXXXXXXXX) for channel and
// supergroup chats, or 0 for private, basic-group, and secret chats.
//
// Use this — not supergroup_id() — when you need to pass a channel or supergroup
// identifier to sendMessage, forwardMessages, copyMessage, getChat, or any other
// method that operates on messages.
//
//   // WRONG — bare supergroup_id will be rejected or silently misrouted:
//   bot.forward_messages(dest, chat.supergroup_id(), [msg_id])!
//
//   // CORRECT:
//   bot.forward_messages(dest, chat.channel_chat_id(), [msg_id])!
//   // or simply use chat.id() if you already have the Chat object from getChat.
pub fn (c Chat) channel_chat_id() i64 {
	return channel_id_to_chat_id(c.supergroup_id())
}

// member_count returns a cached member count if present in this chat object, otherwise 0.
//
// NOTE: TDLib's `chat` type does not include a `member_count` field in its schema.
// This method exists for compatibility with update payloads that may embed a count,
// but will return 0 for most standard chat objects.
// Use get_chat_member_count() for an authoritative, live count.
pub fn (c Chat) member_count() int {
	return map_int(c.raw, 'member_count')
}

// --- MessageContent ---

pub struct MessageContent {
pub:
	raw map[string]json2.Any
}

pub fn MessageContent.from(m map[string]json2.Any) MessageContent {
	return MessageContent{
		raw: m
	}
}

pub fn (mc MessageContent) content_type() string {
	return map_str(mc.raw, '@type')
}

pub fn (mc MessageContent) as_photo() ?Photo {
	if mc.content_type() != 'messagePhoto' {
		return none
	}
	return Photo.from(map_obj(mc.raw, 'photo'))
}

pub fn (mc MessageContent) as_video() ?Video {
	if mc.content_type() != 'messageVideo' {
		return none
	}
	return Video.from(map_obj(mc.raw, 'video'))
}

pub fn (mc MessageContent) as_audio() ?Audio {
	if mc.content_type() != 'messageAudio' {
		return none
	}
	return Audio.from(map_obj(mc.raw, 'audio'))
}

pub fn (mc MessageContent) as_voice_note() ?VoiceNote {
	if mc.content_type() != 'messageVoiceNote' {
		return none
	}
	return VoiceNote.from(map_obj(mc.raw, 'voice_note'))
}

pub fn (mc MessageContent) as_video_note() ?VideoNote {
	if mc.content_type() != 'messageVideoNote' {
		return none
	}
	return VideoNote.from(map_obj(mc.raw, 'video_note'))
}

pub fn (mc MessageContent) as_document() ?Document {
	if mc.content_type() != 'messageDocument' {
		return none
	}
	return Document.from(map_obj(mc.raw, 'document'))
}

pub fn (mc MessageContent) as_sticker() ?Sticker {
	if mc.content_type() != 'messageSticker' {
		return none
	}
	return Sticker.from(map_obj(mc.raw, 'sticker'))
}

pub fn (mc MessageContent) as_animation() ?Animation {
	if mc.content_type() != 'messageAnimation' {
		return none
	}
	return Animation.from(map_obj(mc.raw, 'animation'))
}

pub fn (mc MessageContent) as_location() ?Location {
	if mc.content_type() != 'messageLocation' {
		return none
	}
	return Location.from(map_obj(mc.raw, 'location'))
}

pub fn (mc MessageContent) as_contact() ?Contact {
	if mc.content_type() != 'messageContact' {
		return none
	}
	return Contact.from(map_obj(mc.raw, 'contact'))
}

// as_poll returns the Poll when content_type() == 'messagePoll', otherwise none.
// TDLib schema: messagePoll poll:poll
pub fn (mc MessageContent) as_poll() ?Poll {
	if mc.content_type() != 'messagePoll' {
		return none
	}
	return Poll.from(map_obj(mc.raw, 'poll'))
}

// text returns the plain text for messageText content, '' for other types.
pub fn (mc MessageContent) text() string {
	if mc.content_type() != 'messageText' {
		return ''
	}
	return map_str(map_obj(mc.raw, 'text'), 'text')
}

// caption returns the caption text for media messages (photos, videos, etc.).
pub fn (mc MessageContent) caption() string {
	return map_str(map_obj(mc.raw, 'caption'), 'text')
}

// --- Message ---

pub struct Message {
pub:
	raw map[string]json2.Any
}

pub fn Message.from(m map[string]json2.Any) Message {
	return Message{
		raw: m
	}
}

pub fn (m Message) id() i64 {
	return map_i64(m.raw, 'id')
}

pub fn (m Message) chat_id() i64 {
	return map_i64(m.raw, 'chat_id')
}

pub fn (m Message) date() i64 {
	return map_i64(m.raw, 'date')
}

pub fn (m Message) edit_date() i64 {
	return map_i64(m.raw, 'edit_date')
}

pub fn (m Message) is_outgoing() bool {
	return map_bool(m.raw, 'is_outgoing')
}

pub fn (m Message) is_pinned() bool {
	return map_bool(m.raw, 'is_pinned')
}

pub fn (m Message) is_channel_post() bool {
	return map_bool(m.raw, 'is_channel_post')
}

pub fn (m Message) can_be_edited() bool {
	return map_bool(m.raw, 'can_be_edited')
}

pub fn (m Message) can_be_deleted_only_for_self() bool {
	return map_bool(m.raw, 'can_be_deleted_only_for_self')
}

pub fn (m Message) can_be_deleted_for_all_users() bool {
	return map_bool(m.raw, 'can_be_deleted_for_all_users')
}

// media_album_id is non-zero for messages that are part of an album.
pub fn (m Message) media_album_id() i64 {
	return map_i64(m.raw, 'media_album_id')
}

// via_bot_user_id returns the user ID of the inline bot through which this
// message was sent, or 0 when the message was sent directly.
// TDLib schema: message.via_bot_user_id:int53
pub fn (m Message) via_bot_user_id() i64 {
	return map_i64(m.raw, 'via_bot_user_id')
}

// author_signature returns the signature of the post author for channel
// messages, or '' for regular messages and anonymous channel posts.
// TDLib schema: message.author_signature:string
pub fn (m Message) author_signature() string {
	return map_str(m.raw, 'author_signature')
}

// sender_user_id returns the sender's user ID, or 0 for channels/anonymous senders.
pub fn (m Message) sender_user_id() i64 {
	s := map_obj(m.raw, 'sender_id')
	if map_str(s, '@type') == 'messageSenderUser' {
		return map_i64(s, 'user_id')
	}
	return 0
}

// sender_chat_id returns the sender's chat ID for channel/anonymous posts.
// For channel and supergroup senders the value is normalised to the
// -100XXXXXXXXX form required by every message/send API call.
// channel_id_to_chat_id is a no-op when the ID is already negative.
pub fn (m Message) sender_chat_id() i64 {
	s := map_obj(m.raw, 'sender_id')
	if map_str(s, '@type') == 'messageSenderChat' {
		return channel_id_to_chat_id(map_i64(s, 'chat_id'))
	}
	return 0
}

// reply_to_message_id returns the ID of the message being replied to, or 0.
pub fn (m Message) reply_to_message_id() i64 {
	rt := map_obj(m.raw, 'reply_to')
	if map_str(rt, '@type') == 'messageReplyToMessage' {
		return map_i64(rt, 'message_id')
	}
	return 0
}

// content returns the typed MessageContent wrapper.
pub fn (m Message) content() MessageContent {
	return MessageContent.from(map_obj(m.raw, 'content'))
}

// text is a convenience shortcut for content().text().
pub fn (m Message) text() string {
	return m.content().text()
}

// caption is a convenience shortcut for content().caption().
pub fn (m Message) caption() string {
	return m.content().caption()
}

// reply_markup_raw returns the raw reply_markup field of the message as a
// json2.Any map.  Useful for re-attaching a keyboard to a forwarded copy via
// forward_message_with_markup() or edit_reply_markup().
// Returns an empty map when the message has no markup.
pub fn (m Message) reply_markup_raw() json2.Any {
	rm := map_obj(m.raw, 'reply_markup')
	return json2.Any(rm)
}

// reply_to_chat_id returns the chat ID of the message being replied to.
// Non-zero only when the replied-to message lives in a different chat (e.g. a
// linked discussion channel).  For replies within the same chat use
// chat_id() alongside reply_to_message_id().
//
// TDLib schema: messageReplyToMessage.chat_id:int53
pub fn (m Message) reply_to_chat_id() i64 {
	rt := map_obj(m.raw, 'reply_to')
	if map_str(rt, '@type') == 'messageReplyToMessage' {
		return map_i64(rt, 'chat_id')
	}
	return 0
}

// --- Venue ---
// Wraps the TDLib venue object contained in a messageVenue content.
//
// TDLib schema: venue location:location title:string address:string
//   provider:string id:string type:string

pub struct Venue {
pub:
	raw map[string]json2.Any
}

pub fn Venue.from(m map[string]json2.Any) Venue {
	return Venue{
		raw: m
	}
}

// location returns the geographic coordinates of this venue.
pub fn (v Venue) location() Location {
	return Location.from(map_obj(v.raw, 'location'))
}

pub fn (v Venue) title() string {
	return map_str(v.raw, 'title')
}

pub fn (v Venue) address() string {
	return map_str(v.raw, 'address')
}

// provider returns the map provider name, e.g. 'foursquare' or ''.
pub fn (v Venue) provider() string {
	return map_str(v.raw, 'provider')
}

// provider_id returns the third-party place ID within the provider.
pub fn (v Venue) provider_id() string {
	return map_str(v.raw, 'id')
}

// --- Dice ---
// Wraps the TDLib messageDice object for animated dice/dart/etc. messages.
//
// TDLib schema: messageDice emoji:string value:int32
//   initial_state:DiceStickers? final_state:DiceStickers? success_animation_frame_number:int32

pub struct Dice {
pub:
	raw map[string]json2.Any
}

pub fn Dice.from(m map[string]json2.Any) Dice {
	return Dice{
		raw: m
	}
}

// emoji returns the dice emoji, e.g. the dice, darts, or basketball string.
pub fn (d Dice) emoji() string {
	return map_str(d.raw, 'emoji')
}

// value returns the final rolled value (1..6 for a standard die).
// Returns 0 while the animation is still playing (before the result is known).
pub fn (d Dice) value() int {
	return map_int(d.raw, 'value')
}

// --- ForwardInfo ---
// Wraps the TDLib messageForwardInfo object present on forwarded messages.
//
// TDLib schema: messageForwardInfo origin:MessageOrigin date:int32
//   source:forwardSource?
//
// origin is one of:
//   messageOriginUser       - forwarded from a user  (sender_user_id)
//   messageOriginHiddenUser - forwarded from a user with hidden identity (sender_name)
//   messageOriginChat       - forwarded from a group (sender_chat_id, author_signature)
//   messageOriginChannel    - forwarded from a channel (chat_id, message_id, author_signature)

pub struct ForwardInfo {
pub:
	raw map[string]json2.Any
}

pub fn ForwardInfo.from(m map[string]json2.Any) ForwardInfo {
	return ForwardInfo{
		raw: m
	}
}

// date returns the Unix timestamp of the original message.
pub fn (fi ForwardInfo) date() i64 {
	return map_i64(fi.raw, 'date')
}

// origin_type returns the @type of the origin object:
//   "messageOriginUser", "messageOriginHiddenUser",
//   "messageOriginChat", "messageOriginChannel".
pub fn (fi ForwardInfo) origin_type() string {
	return map_type(fi.raw, 'origin')
}

// origin_user_id returns the sender user ID for messageOriginUser, or 0.
pub fn (fi ForwardInfo) origin_user_id() i64 {
	orig := map_obj(fi.raw, 'origin')
	if map_str(orig, '@type') == 'messageOriginUser' {
		return map_i64(orig, 'sender_user_id')
	}
	return 0
}

// origin_sender_name returns the display name for messageOriginHiddenUser, or ''.
pub fn (fi ForwardInfo) origin_sender_name() string {
	orig := map_obj(fi.raw, 'origin')
	if map_str(orig, '@type') == 'messageOriginHiddenUser' {
		return map_str(orig, 'sender_name')
	}
	return ''
}

// origin_chat_id returns the chat ID for messageOriginChat or messageOriginChannel, or 0.
// Channel IDs are normalised to the -100XXXXXXXXX form via channel_id_to_chat_id.
pub fn (fi ForwardInfo) origin_chat_id() i64 {
	orig := map_obj(fi.raw, 'origin')
	typ := map_str(orig, '@type')
	if typ == 'messageOriginChat' {
		return channel_id_to_chat_id(map_i64(orig, 'sender_chat_id'))
	}
	if typ == 'messageOriginChannel' {
		return channel_id_to_chat_id(map_i64(orig, 'chat_id'))
	}
	return 0
}

// origin_message_id returns the original message ID for messageOriginChannel, or 0.
pub fn (fi ForwardInfo) origin_message_id() i64 {
	orig := map_obj(fi.raw, 'origin')
	if map_str(orig, '@type') == 'messageOriginChannel' {
		return map_i64(orig, 'message_id')
	}
	return 0
}

// origin_author_signature returns the author signature for channel / group posts, or ''.
pub fn (fi ForwardInfo) origin_author_signature() string {
	orig := map_obj(fi.raw, 'origin')
	return map_str(orig, 'author_signature')
}

// --- MessageContent additions ---

// as_venue returns the Venue when content_type() == 'messageVenue', otherwise none.
// TDLib schema: messageVenue venue:venue
pub fn (mc MessageContent) as_venue() ?Venue {
	if mc.content_type() != 'messageVenue' {
		return none
	}
	return Venue.from(map_obj(mc.raw, 'venue'))
}

// as_dice returns the Dice when content_type() == 'messageDice', otherwise none.
// TDLib schema: messageDice emoji:string value:int32 ...
pub fn (mc MessageContent) as_dice() ?Dice {
	if mc.content_type() != 'messageDice' {
		return none
	}
	return Dice.from(mc.raw)
}

// --- Message forward info accessor ---

// forward_info returns the ForwardInfo for a forwarded message, or none for
// original (non-forwarded) messages.
// TDLib schema: message.forward_info:messageForwardInfo?
pub fn (m Message) forward_info() ?ForwardInfo {
	fi := map_obj(m.raw, 'forward_info')
	if fi.len == 0 {
		return none
	}
	return ForwardInfo.from(fi)
}

// --- ChatPhoto ---
// Wraps the TDLib chatPhoto object used for user, group, and channel profile photos.
// Returned by UserFullInfo.photo(), SupergroupFullInfo.photo(), and get_chat_photo_history().
//
// TDLib schema: chatPhoto id:int64 added_date:int32
//   minithumbnail:minithumbnail? sizes:vector<photoSize>
//   animation:animatedChatPhoto? small_animation:animatedChatPhoto?
//   sticker:chatPhotoSticker?

pub struct ChatPhoto {
pub:
	raw map[string]json2.Any
}

pub fn ChatPhoto.from(m map[string]json2.Any) ChatPhoto {
	return ChatPhoto{
		raw: m
	}
}

// id returns the unique identifier of this profile photo.
pub fn (cp ChatPhoto) id() i64 {
	return map_i64(cp.raw, 'id')
}

// added_date returns the Unix timestamp when the photo was set.
pub fn (cp ChatPhoto) added_date() i64 {
	return map_i64(cp.raw, 'added_date')
}

// sizes returns all available PhotoSize variants for this profile photo.
// The list is ordered smallest to largest.
pub fn (cp ChatPhoto) sizes() []PhotoSize {
	raw_arr := map_arr(cp.raw, 'sizes')
	mut out := []PhotoSize{cap: raw_arr.len}
	for item in raw_arr {
		out << PhotoSize.from(item.as_map())
	}
	return out
}

// largest_size returns the highest-resolution PhotoSize, or none if empty.
pub fn (cp ChatPhoto) largest_size() ?PhotoSize {
	sizes := cp.sizes()
	if sizes.len == 0 {
		return none
	}
	return sizes[sizes.len - 1]
}

// smallest_size returns the lowest-resolution PhotoSize (thumbnail), or none if empty.
pub fn (cp ChatPhoto) smallest_size() ?PhotoSize {
	sizes := cp.sizes()
	if sizes.len == 0 {
		return none
	}
	return sizes[0]
}

// has_animation returns true when an animated variant of this profile photo is available.
pub fn (cp ChatPhoto) has_animation() bool {
	return map_obj(cp.raw, 'animation').len > 0
}

// --- UserFullInfo ---
// Wraps the TDLib userFullInfo object returned by getUserFullInfo.
// Contains extended information not present on the basic user object:
// bio, profile photo history, common-group count, call settings, and more.
//
// TDLib schema: userFullInfo personal_photo:chatPhoto? photo:chatPhoto?
//   public_photo:chatPhoto? block_list:BlockList? can_be_called:Bool
//   supports_video_calls:Bool has_private_calls:Bool has_private_forwards:Bool
//   has_restricted_voice_and_video_note_messages:Bool has_pinned_stories:Bool
//   has_sponsored_messages_enabled:Bool need_phone_number_privacy_exception:Bool
//   set_chat_background:Bool bio:formattedText? group_in_common_count:Int32
//   business_info:businessInfo? bot_info:botInfo?

pub struct UserFullInfo {
pub:
	raw map[string]json2.Any
}

pub fn UserFullInfo.from(m map[string]json2.Any) UserFullInfo {
	return UserFullInfo{
		raw: m
	}
}

// bio returns the user's About text, or '' when not set.
// TDLib stores the bio as a formattedText object; the plain text field is extracted.
pub fn (u UserFullInfo) bio() string {
	return map_str(map_obj(u.raw, 'bio'), 'text')
}

// group_in_common_count returns the number of groups the current user and
// this user have in common.
pub fn (u UserFullInfo) group_in_common_count() int {
	return map_int(u.raw, 'group_in_common_count')
}

// can_be_called returns true when the current user can call this user.
pub fn (u UserFullInfo) can_be_called() bool {
	return map_bool(u.raw, 'can_be_called')
}

// supports_video_calls returns true when this user's client supports video calls.
pub fn (u UserFullInfo) supports_video_calls() bool {
	return map_bool(u.raw, 'supports_video_calls')
}

// has_private_calls returns true when this user has restricted who can call them.
pub fn (u UserFullInfo) has_private_calls() bool {
	return map_bool(u.raw, 'has_private_calls')
}

// has_private_forwards returns true when this user's forwarded messages hide
// their identity (Telegram Privacy > Forwarded Messages).
pub fn (u UserFullInfo) has_private_forwards() bool {
	return map_bool(u.raw, 'has_private_forwards')
}

// has_restricted_voice_and_video_note_messages returns true when this user
// only allows voice/video notes from contacts.
pub fn (u UserFullInfo) has_restricted_voice_and_video_note_messages() bool {
	return map_bool(u.raw, 'has_restricted_voice_and_video_note_messages')
}

// has_pinned_stories returns true when this user currently has pinned stories.
pub fn (u UserFullInfo) has_pinned_stories() bool {
	return map_bool(u.raw, 'has_pinned_stories')
}

// photo returns the main profile photo visible to the public, or none.
// This is the photo displayed on the user's profile page and in chat lists.
pub fn (u UserFullInfo) photo() ?ChatPhoto {
	m := map_obj(u.raw, 'photo')
	if m.len == 0 {
		return none
	}
	return ChatPhoto.from(m)
}

// personal_photo returns the Telegram Premium personal photo (shown only to contacts),
// or none when not set.
pub fn (u UserFullInfo) personal_photo() ?ChatPhoto {
	m := map_obj(u.raw, 'personal_photo')
	if m.len == 0 {
		return none
	}
	return ChatPhoto.from(m)
}

// public_photo returns the fallback public photo shown when the main photo is
// restricted to contacts only, or none when not set.
pub fn (u UserFullInfo) public_photo() ?ChatPhoto {
	m := map_obj(u.raw, 'public_photo')
	if m.len == 0 {
		return none
	}
	return ChatPhoto.from(m)
}

// is_blocked returns true when the user has been blocked by the current account.
// TDLib >= 1.8.x represents this via block_list:BlockList; the field is non-null
// when the user is on any block list.
pub fn (u UserFullInfo) is_blocked() bool {
	bl := map_obj(u.raw, 'block_list')
	return bl.len > 0
}

// --- SupergroupFullInfo ---
// Wraps the TDLib supergroupFullInfo object returned by getSupergroupFullInfo.
// Contains extended information for supergroups and channels that is not present
// on the basic Chat or chatTypeSupergroup objects.
//
// TDLib schema: supergroupFullInfo photo:chatPhoto? description:String
//   member_count:Int32 administrator_count:Int32 restricted_count:Int32
//   banned_count:Int32 linked_chat_id:Int53 slow_mode_delay:Int32
//   slow_mode_delay_expires_in:Double can_enable_paid_messages:Bool
//   can_get_members:Bool has_hidden_members:Bool can_hide_members:Bool
//   can_set_sticker_set:Bool can_set_location:Bool can_get_statistics:Bool
//   is_all_history_available:Bool has_aggressive_anti_spam_enabled:Bool
//   has_pinned_stories:Bool sticker_set_id:Int64 custom_emoji_sticker_set_id:Int64
//   location:chatLocation? invite_link:chatInviteLink?
//   bot_commands:vector<botCommands> upgraded_from_basic_group_id:Int53
//   upgraded_from_max_message_id:Int53

pub struct SupergroupFullInfo {
pub:
	raw map[string]json2.Any
}

pub fn SupergroupFullInfo.from(m map[string]json2.Any) SupergroupFullInfo {
	return SupergroupFullInfo{
		raw: m
	}
}

// photo returns the current profile photo of the supergroup or channel, or none.
pub fn (sg SupergroupFullInfo) photo() ?ChatPhoto {
	m := map_obj(sg.raw, 'photo')
	if m.len == 0 {
		return none
	}
	return ChatPhoto.from(m)
}

// description returns the About / bio text of the supergroup or channel.
pub fn (sg SupergroupFullInfo) description() string {
	return map_str(sg.raw, 'description')
}

// member_count returns the total number of members.
pub fn (sg SupergroupFullInfo) member_count() int {
	return map_int(sg.raw, 'member_count')
}

// administrator_count returns the number of administrators.
pub fn (sg SupergroupFullInfo) administrator_count() int {
	return map_int(sg.raw, 'administrator_count')
}

// restricted_count returns the number of restricted members.
pub fn (sg SupergroupFullInfo) restricted_count() int {
	return map_int(sg.raw, 'restricted_count')
}

// banned_count returns the number of banned members.
pub fn (sg SupergroupFullInfo) banned_count() int {
	return map_int(sg.raw, 'banned_count')
}

// linked_chat_id returns the chat ID of the linked discussion group (for channels)
// or the linked broadcast channel (for supergroups), or 0 if none.
pub fn (sg SupergroupFullInfo) linked_chat_id() i64 {
	return map_i64(sg.raw, 'linked_chat_id')
}

// slow_mode_delay returns the minimum interval in seconds between messages sent
// by non-administrator members. 0 means slow mode is disabled.
pub fn (sg SupergroupFullInfo) slow_mode_delay() int {
	return map_int(sg.raw, 'slow_mode_delay')
}

// is_all_history_available returns true when all new members can read the full
// message history of the supergroup.
pub fn (sg SupergroupFullInfo) is_all_history_available() bool {
	return map_bool(sg.raw, 'is_all_history_available')
}

// has_aggressive_anti_spam_enabled returns true when anti-spam checks are active.
pub fn (sg SupergroupFullInfo) has_aggressive_anti_spam_enabled() bool {
	return map_bool(sg.raw, 'has_aggressive_anti_spam_enabled')
}

// has_hidden_members returns true when the member list is hidden from non-admins.
pub fn (sg SupergroupFullInfo) has_hidden_members() bool {
	return map_bool(sg.raw, 'has_hidden_members')
}

// sticker_set_id returns the identifier of the supergroup's custom sticker set, or 0.
pub fn (sg SupergroupFullInfo) sticker_set_id() i64 {
	return map_i64(sg.raw, 'sticker_set_id')
}

// custom_emoji_sticker_set_id returns the identifier of the custom emoji sticker
// set associated with this supergroup or channel, or 0.
pub fn (sg SupergroupFullInfo) custom_emoji_sticker_set_id() i64 {
	return map_i64(sg.raw, 'custom_emoji_sticker_set_id')
}

// invite_link_url returns the URL of the primary invite link for this supergroup
// or channel, or '' when none has been created or the caller lacks the right to
// view it.
pub fn (sg SupergroupFullInfo) invite_link_url() string {
	return map_str(map_obj(sg.raw, 'invite_link'), 'invite_link')
}

// has_pinned_stories returns true when the supergroup or channel currently has
// pinned stories on its profile page.
pub fn (sg SupergroupFullInfo) has_pinned_stories() bool {
	return map_bool(sg.raw, 'has_pinned_stories')
}

// upgraded_from_basic_group_id returns the ID of the basic group from which this
// supergroup was upgraded, or 0 if it was not upgraded from a basic group.
pub fn (sg SupergroupFullInfo) upgraded_from_basic_group_id() i64 {
	return map_i64(sg.raw, 'upgraded_from_basic_group_id')
}

// --- ChatFolderInfo ---
// Wraps the TDLib chatFolderInfo object returned in the chat folder list.
// Contains summary fields; use get_chat_folder() to get the full chatFolder.
//
// TDLib schema: chatFolderInfo id:Int32 name:chatFolderName
//   icon:chatFolderIcon color_id:Int32 is_shareable:Bool has_my_invite_links:Bool

pub struct ChatFolderInfo {
pub:
	raw map[string]json2.Any
}

pub fn ChatFolderInfo.from(m map[string]json2.Any) ChatFolderInfo {
	return ChatFolderInfo{
		raw: m
	}
}

// id returns the unique identifier of the chat folder.
pub fn (cfi ChatFolderInfo) id() int {
	return map_int(cfi.raw, 'id')
}

// name returns the display name of the folder.
// TDLib stores the name as a chatFolderName object; the text field is extracted.
pub fn (cfi ChatFolderInfo) name() string {
	return map_str(map_obj(cfi.raw, 'name'), 'text')
}

// icon_name returns the name of the icon used for this folder (e.g. "All", "Unread",
// "Custom", "Groups", "Channels", "Bots", "Crown", etc.), or '' if none.
pub fn (cfi ChatFolderInfo) icon_name() string {
	return map_str(map_obj(cfi.raw, 'icon'), 'name')
}

// color_id returns the identifier of the folder color; -1 when the default color is used.
pub fn (cfi ChatFolderInfo) color_id() int {
	return map_int(cfi.raw, 'color_id')
}

// is_shareable returns true when the folder can be shared via an invite link.
pub fn (cfi ChatFolderInfo) is_shareable() bool {
	return map_bool(cfi.raw, 'is_shareable')
}

// has_my_invite_links returns true when at least one invite link owned by the
// current user exists for this folder.
pub fn (cfi ChatFolderInfo) has_my_invite_links() bool {
	return map_bool(cfi.raw, 'has_my_invite_links')
}

// --- ChatFolder ---
// Wraps the TDLib chatFolder object returned by getChatFolder.
// Contains the full filter configuration for a chat folder.
//
// TDLib schema: chatFolder name:chatFolderName icon:chatFolderIcon? color_id:Int32
//   is_shareable:Bool pinned_chat_ids:vector<Int53> included_chat_ids:vector<Int53>
//   excluded_chat_ids:vector<Int53> exclude_muted:Bool exclude_read:Bool
//   exclude_archived:Bool include_contacts:Bool include_non_contacts:Bool
//   include_bots:Bool include_groups:Bool include_channels:Bool

pub struct ChatFolder {
pub:
	raw map[string]json2.Any
}

pub fn ChatFolder.from(m map[string]json2.Any) ChatFolder {
	return ChatFolder{
		raw: m
	}
}

// name returns the display name of this folder.
pub fn (cf ChatFolder) name() string {
	return map_str(map_obj(cf.raw, 'name'), 'text')
}

// icon_name returns the folder icon name, or '' if none is set.
pub fn (cf ChatFolder) icon_name() string {
	return map_str(map_obj(cf.raw, 'icon'), 'name')
}

// color_id returns the folder color identifier; -1 for the default color.
pub fn (cf ChatFolder) color_id() int {
	return map_int(cf.raw, 'color_id')
}

// is_shareable returns true when an invite link can be created for this folder.
pub fn (cf ChatFolder) is_shareable() bool {
	return map_bool(cf.raw, 'is_shareable')
}

// pinned_chat_ids returns the list of chat IDs that are pinned within this folder.
pub fn (cf ChatFolder) pinned_chat_ids() []i64 {
	raw_arr := map_arr(cf.raw, 'pinned_chat_ids')
	mut out := []i64{cap: raw_arr.len}
	for v in raw_arr {
		out << any_to_i64(v)
	}
	return out
}

// included_chat_ids returns the IDs of chats explicitly included in this folder.
pub fn (cf ChatFolder) included_chat_ids() []i64 {
	raw_arr := map_arr(cf.raw, 'included_chat_ids')
	mut out := []i64{cap: raw_arr.len}
	for v in raw_arr {
		out << any_to_i64(v)
	}
	return out
}

// excluded_chat_ids returns the IDs of chats explicitly excluded from this folder.
pub fn (cf ChatFolder) excluded_chat_ids() []i64 {
	raw_arr := map_arr(cf.raw, 'excluded_chat_ids')
	mut out := []i64{cap: raw_arr.len}
	for v in raw_arr {
		out << any_to_i64(v)
	}
	return out
}

// exclude_muted returns true when muted chats are hidden from this folder.
pub fn (cf ChatFolder) exclude_muted() bool {
	return map_bool(cf.raw, 'exclude_muted')
}

// exclude_read returns true when read chats are hidden from this folder.
pub fn (cf ChatFolder) exclude_read() bool {
	return map_bool(cf.raw, 'exclude_read')
}

// exclude_archived returns true when archived chats are excluded from this folder.
pub fn (cf ChatFolder) exclude_archived() bool {
	return map_bool(cf.raw, 'exclude_archived')
}

// include_contacts returns true when chats with contacts are included.
pub fn (cf ChatFolder) include_contacts() bool {
	return map_bool(cf.raw, 'include_contacts')
}

// include_non_contacts returns true when chats with non-contacts are included.
pub fn (cf ChatFolder) include_non_contacts() bool {
	return map_bool(cf.raw, 'include_non_contacts')
}

// include_bots returns true when bot chats are included.
pub fn (cf ChatFolder) include_bots() bool {
	return map_bool(cf.raw, 'include_bots')
}

// include_groups returns true when group chats (supergroups and basic groups)
// are included.
pub fn (cf ChatFolder) include_groups() bool {
	return map_bool(cf.raw, 'include_groups')
}

// include_channels returns true when channels are included.
pub fn (cf ChatFolder) include_channels() bool {
	return map_bool(cf.raw, 'include_channels')
}
