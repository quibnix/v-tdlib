// tdlib_single.v
// Single-file V library: TDLib wrapper for Telegram.
//
// Five logical sections:
//   1. Core Types & TDLib Hub
//   2. Utilities & Helpers
//   3. User Account
//   4. Bot Account
//   5. Account Manager

module tdlib

import encoding.base64
import os
import rand
import sync
import time
import x.json2

#flag -ltdjson
#include <td/telegram/td_json_client.h>

// =============================================================================
// SECTION 1: Core Types & TDLib Hub
// Handler type, Session, TDLib struct, lifecycle, handler registration,
// low-level messaging (send, send_sync, send_fire), and receiver goroutine.
// Typed wrappers for TDLib JSON objects (Message, Chat, User, Media, etc.).
// Fluent RequestBuilder and value-constructor helpers.
// =============================================================================

// --- tdlib.v ---

// --- C interop ---

fn C.td_create_client_id() int
fn C.td_send(client_id int, request &char)
fn C.td_receive(timeout f64) voidptr
fn C.td_execute(request &char) voidptr

// cstr_to_string safely converts a nullable C string to a V string.
// A nil pointer returns ''.  An empty C string (first byte is '\0') also returns ''
// because cstring_to_vstring already handles that case internally.
fn cstr_to_string(ptr voidptr) string {
	if isnil(ptr) {
		return ''
	}
	return unsafe { cstring_to_vstring(&char(ptr)) }
}

// --- Public types ---

// Handler is the type for update callbacks registered via account.on().
// Each handler is invoked in a fresh goroutine, so blocking calls are safe.
pub type Handler = fn (json2.Any)

// Session is a thin wrapper around a TDLib client_id integer.
// One Session per account. Create via UserAccount.new() or BotAccount.new().
pub struct Session {
pub:
	id int
}

// TDLib is the shared hub. One background goroutine calls td_receive() and
// routes each message to:
//   - A one-shot response channel keyed by @extra (from send_sync).
//   - A per-session Handler registered with on().
//   - A per-session update channel for manual polling via get_update().
pub struct TDLib {
mut:
	response_chans   map[string]chan json2.Any
	session_handlers map[string]Handler
	session_updates  map[int]chan json2.Any
	running          bool
	receiver         ?thread
	mutex            sync.Mutex
}

// --- Lifecycle ---

// new creates a TDLib hub and starts the background receiver goroutine.
pub fn new() &TDLib {
	mut td := &TDLib{
		response_chans:   map[string]chan json2.Any{}
		session_handlers: map[string]Handler{}
		session_updates:  map[int]chan json2.Any{}
	}
	td.start_receiver()
	return td
}

// create_session allocates a new TDLib client_id and registers its channels.
// Called internally by UserAccount.new() and BotAccount.new().
pub fn (mut td TDLib) create_session() Session {
	id := C.td_create_client_id()
	td.mutex.lock()
	td.session_updates[id] = chan json2.Any{cap: 512}
	td.mutex.unlock()
	return Session{id}
}

// shutdown stops the background receiver goroutine, waits for it to exit,
// and unblocks any callers blocked in send_sync() or get_update().
//
// Pending send_sync() calls receive an error response so they return
// immediately with an error instead of silently returning a zero value.
// Pending get_update() calls receive a sentinel and then the channel is
// closed so they unblock.
pub fn (mut td TDLib) shutdown() {
	td.mutex.lock()
	td.running = false
	td.mutex.unlock()
	if t := td.receiver {
		t.wait()
	}
	td.mutex.lock()
	// Build a synthetic error response so send_sync() returns an error
	// rather than silently returning a zero-value json2.Any.
	mut shutdown_map := map[string]json2.Any{}
	shutdown_map['@type'] = json2.Any('error')
	shutdown_map['code'] = json2.Any(0)
	shutdown_map['message'] = json2.Any('TDLib hub shut down')
	shutdown_resp := json2.Any(shutdown_map)
	// Use select + else to avoid blocking if the channel's cap:1 buffer is
	// already full (i.e. TDLib responded between the time the caller issued
	// send_sync() and the time shutdown() reached this point).
	for _, ch in td.response_chans {
		select {
			ch <- shutdown_resp {}
			else {}
		}
		ch.close()
	}
	td.response_chans.clear()
	// Clear registered handlers so no stale closures remain after shutdown.
	// Without this, a handler registered on a now-defunct account would stay
	// in memory and could be dispatched if a final td_receive tick races with
	// the running=false flag.
	td.session_handlers.clear()
	// Push a typed shutdown sentinel into every update channel so that
	// callers blocked in get_update() (e.g. auth loops) unblock and can
	// detect the shutdown rather than spinning on a zero-value receive.
	mut sentinel_m := map[string]json2.Any{}
	sentinel_m['@type'] = json2.Any('tdlibShutdown')
	sentinel := json2.Any(sentinel_m)
	for _, ch in td.session_updates {
		select {
			ch <- sentinel {}
			else {}
		}
		ch.close()
	}
	td.session_updates.clear()
	td.mutex.unlock()
}

// --- Handler registration ---

// on registers a Handler for a specific TDLib @type on the given session.
// Each matching update is dispatched in a new goroutine, so handlers can
// safely make synchronous API calls without deadlocking the receiver.
pub fn (mut td TDLib) on(session_id int, typ string, handler Handler) {
	key := handler_key(session_id, typ)
	td.mutex.lock()
	td.session_handlers[key] = handler
	td.mutex.unlock()
}

// off removes a previously registered Handler.
pub fn (mut td TDLib) off(session_id int, typ string) {
	key := handler_key(session_id, typ)
	td.mutex.lock()
	td.session_handlers.delete(key)
	td.mutex.unlock()
}

// get_update blocks until an update with no registered Handler arrives for
// the given session, or until the hub is shut down (returns empty map).
// Used during authentication and for manual polling.
pub fn (mut td TDLib) get_update(session_id int) json2.Any {
	td.mutex.lock()
	if session_id in td.session_updates {
		ch := td.session_updates[session_id]
		td.mutex.unlock()
		// When the channel is closed by shutdown(), a receive returns
		// the zero value immediately.  Return an empty map so callers
		// can detect the condition by checking for an empty update.
		update := <-ch
		return update
	}
	td.mutex.unlock()
	return json2.Any(map[string]json2.Any{})
}

// --- Low-level request / response ---

// send dispatches req for the given session, registers a one-shot response
// channel keyed by a fresh UUID in @extra, and returns that channel.
// Returns an error immediately if the hub has been shut down.
pub fn (s Session) send(mut td TDLib, req json2.Any) !chan json2.Any {
	mut m := req.as_map()
	if '@type' !in m {
		return error('request must have "@type"')
	}
	extra := rand.uuid_v4()
	m['@extra'] = json2.Any(extra)
	// Register the channel BEFORE calling C.td_send to eliminate the race
	// where TDLib responds before the channel is inserted into response_chans.
	// Also check td.running under the same lock so we never insert into a
	// dead map after shutdown() has already cleared it (which would cause an
	// infinite block in send_sync()).
	ch := chan json2.Any{cap: 1}
	td.mutex.lock()
	if !td.running {
		td.mutex.unlock()
		return error('TDLib hub is not running')
	}
	td.response_chans[extra] = ch
	td.mutex.unlock()
	json_str := json2.encode(m)
	unsafe { C.td_send(s.id, &char(json_str.str)) }
	_ = json_str // keep the V string alive across the C call
	return ch
}

// send_sync dispatches req and blocks until TDLib responds.
// Returns an error if TDLib returns an error-type response, including
// a synthetic error when the hub is shut down while the call is pending.
pub fn (s Session) send_sync(mut td TDLib, req json2.Any) !json2.Any {
	ch := s.send(mut td, req)!
	resp := <-ch
	m := resp.as_map()
	if map_str(m, '@type') == 'error' {
		code := map_int(m, 'code')
		msg := map_str(m, 'message')
		return error('TDLib error ${code}: ${msg}')
	}
	return resp
}

// send_fire dispatches req and does not wait for a response.
// The response (if any) flows to the session's update channel and is discarded.
// Returns an error immediately if the hub has been shut down.
pub fn (s Session) send_fire(mut td TDLib, req json2.Any) ! {
	mut m := req.as_map()
	if '@type' !in m {
		return error('request must have "@type"')
	}
	td.mutex.lock()
	if !td.running {
		td.mutex.unlock()
		return error('TDLib hub is not running')
	}
	td.mutex.unlock()
	json_str := json2.encode(m)
	unsafe { C.td_send(s.id, &char(json_str.str)) }
	_ = json_str
}

// execute runs a synchronous TDLib call via td_execute().
// Only a small subset of methods support this (e.g. parseTextEntities,
// setLogVerbosityLevel).
pub fn execute(req json2.Any) !json2.Any {
	json_str := json2.encode(req.as_map())
	raw_ptr := unsafe { C.td_execute(&char(json_str.str)) }
	_ = json_str
	raw := cstr_to_string(raw_ptr)
	if raw == '' {
		return error('td_execute returned empty response')
	}
	return json2.decode[json2.Any](raw)!
}

// --- Internal helpers ---

fn handler_key(session_id int, typ string) string {
	return '${session_id}:${typ}'
}

fn (mut td TDLib) start_receiver() {
	td.mutex.lock()
	if td.running {
		td.mutex.unlock()
		return
	}
	td.running = true
	td.mutex.unlock()
	td.receiver = go td.receiver_loop()
}

fn (mut td TDLib) receiver_loop() {
	for {
		td.mutex.lock()
		running := td.running
		td.mutex.unlock()
		if !running {
			break
		}
		raw := cstr_to_string(C.td_receive(0.050))
		if raw == '' {
			continue
		}
		event := json2.decode[json2.Any](raw) or { continue }
		m := event.as_map()

		extra := if v := m['@extra'] { v.str() } else { '' }
		typ := if v := m['@type'] { v.str() } else { '' }
		client_id := int(any_to_i64(if v := m['@client_id'] {
			v
		} else {
			json2.Any(int(0))
		}))

		// 1. Route to one-shot response channel (keyed by @extra)
		if extra != '' {
			td.mutex.lock()
			if extra in td.response_chans {
				ch := td.response_chans[extra]
				td.response_chans.delete(extra)
				td.mutex.unlock()
				ch <- event
				ch.close()
				continue
			}
			td.mutex.unlock()
		}

		// 2. Route by @client_id to session handler or update channel
		if typ != '' && client_id > 0 {
			key := handler_key(client_id, typ)
			td.mutex.lock()
			if key in td.session_handlers {
				handler := td.session_handlers[key]
				td.mutex.unlock()
				go handler(event)
				continue
			}
			if client_id in td.session_updates {
				ch := td.session_updates[client_id]
				td.mutex.unlock()
				select {
					ch <- event {}
					else {}
				}
				continue
			}
			td.mutex.unlock()
		}
	}
}

// --- types.v ---

// --- Channel ID helper ---

// channel_id_to_chat_id converts a bare channel/supergroup ID (as returned in
// chatTypeSupergroup.supergroup_id) into the full chat ID used by all API calls.
//
// TDLib uses two different ID representations for channels and supergroups:
//
//   supergroup_id  -- a bare positive integer used by object-level methods such as
//                    getSupergroup, getSupergroupFullInfo, getSupergroupMembers.
//                    This is what Chat.supergroup_id() returns.
//
//   chat_id        -- the negative identifier required by every message/send/forward
//                    API call (sendMessage, forwardMessages, getChat, copyMessage, ...).
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
// The previous code returned ?PhotoSize for all thumbnail() methods, but
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
// Do NOT pass this value to message or forwarding API calls -- those require the
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
// Use this -- not supergroup_id() -- when you need to pass a channel or supergroup
// identifier to sendMessage, forwardMessages, copyMessage, getChat, or any other
// method that operates on messages.
//
//   // WRONG -- bare supergroup_id will be rejected or silently misrouted:
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

// --- builder.v ---

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
// The previous implementation omitted the required 'entities' field.
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

// =============================================================================
// SECTION 2: Utilities & Helpers
// Formatting, string escaping, text helpers, bot command parsing, time
// utilities, Telegram-specific helpers, fuzzy matching, and rate limiting.
// =============================================================================

// --- tools.v ---

// --- Human-readable formatting ---

// fmt_bytes formats a byte count as a human-readable string with B / KB / MB / GB.
pub fn fmt_bytes(n i64) string {
	gb := i64(1024) * 1024 * 1024
	mb := i64(1024) * 1024
	kb := i64(1024)
	if n >= gb {
		return '${n / gb} GB'
	}
	if n >= mb {
		return '${n / mb} MB'
	}
	if n >= kb {
		return '${n / kb} KB'
	}
	return '${n} B'
}

// fmt_bytes_precise formats a byte count with one decimal place of precision.
// Examples: fmt_bytes_precise(1536) -> "1.5 KB",  fmt_bytes_precise(2684354560) -> "2.5 GB".
pub fn fmt_bytes_precise(n i64) string {
	gb := i64(1024) * 1024 * 1024
	mb := i64(1024) * 1024
	kb := i64(1024)
	if n >= gb {
		whole := n / gb
		frac := (n % gb) * 10 / gb
		if frac == 0 {
			return '${whole} GB'
		}
		return '${whole}.${frac} GB'
	}
	if n >= mb {
		whole := n / mb
		frac := (n % mb) * 10 / mb
		if frac == 0 {
			return '${whole} MB'
		}
		return '${whole}.${frac} MB'
	}
	if n >= kb {
		whole := n / kb
		frac := (n % kb) * 10 / kb
		if frac == 0 {
			return '${whole} KB'
		}
		return '${whole}.${frac} KB'
	}
	return '${n} B'
}

// fmt_duration formats a number of seconds as a human-readable string.
// Examples: fmt_duration(90) -> "1m 30s", fmt_duration(3661) -> "1h 1m 1s".
pub fn fmt_duration(seconds i64) string {
	if seconds <= 0 {
		return '0s'
	}
	h := seconds / 3600
	m := (seconds % 3600) / 60
	s := seconds % 60
	mut parts := []string{}
	if h > 0 {
		parts << '${h}h'
	}
	if m > 0 {
		parts << '${m}m'
	}
	if s > 0 || parts.len == 0 {
		parts << '${s}s'
	}
	return parts.join(' ')
}

// fmt_count formats a large integer with K / M suffixes.
// Examples: fmt_count(1500) -> "1.5K", fmt_count(2_000_000) -> "2M".
pub fn fmt_count(n i64) string {
	if n >= 1_000_000 {
		whole := n / 1_000_000
		frac := (n % 1_000_000) / 100_000
		if frac == 0 {
			return '${whole}M'
		}
		return '${whole}.${frac}M'
	}
	if n >= 1_000 {
		whole := n / 1_000
		frac := (n % 1_000) / 100
		if frac == 0 {
			return '${whole}K'
		}
		return '${whole}.${frac}K'
	}
	return '${n}'
}

// --- String escaping ---

// escape_html escapes the five HTML special characters so that a plain string
// can be safely embedded inside an HTML-formatted Telegram message.
// Replacements: & -> &amp;  < -> &lt;  > -> &gt;  " -> &quot;  ' -> &#39;
pub fn escape_html(s string) string {
	return s
		.replace('&', '&amp;')
		.replace('<', '&lt;')
		.replace('>', '&gt;')
		.replace('"', '&quot;')
		.replace("'", '&#39;')
}

// escape_markdown escapes all MarkdownV2 reserved characters so that a plain
// string can be safely embedded inside a MarkdownV2-formatted message.
// Reserved: _ * [ ] ( ) ~ ` > # + - = | { } . !
pub fn escape_markdown(s string) string {
	// Backslash must be first so escaping backslashes we add for subsequent characters
	// are never themselves double-escaped.
	reserved := ['\\', '_', '*', '[', ']', '(', ')', '~', '`', '>', '#', '+', '-', '=', '|', '{',
		'}', '.', '!']
	mut result := s
	for ch in reserved {
		result = result.replace(ch, '\\${ch}')
	}
	return result
}

// --- Text helpers ---

// truncate shortens s to at most max_len runes, appending suffix when the
// string is actually cut.  Common suffix: "..." (three ASCII dots).
pub fn truncate(s string, max_len int, suffix string) string {
	runes := s.runes()
	if runes.len <= max_len {
		return s
	}
	suffix_runes := suffix.runes()
	keep := if max_len > suffix_runes.len { max_len - suffix_runes.len } else { 0 }
	return runes[..keep].string() + suffix
}

// smart_truncate truncates s to at most max_len runes at a word boundary, appending suffix.
// Unlike truncate(), it never cuts in the middle of a word.
pub fn smart_truncate(s string, max_len int, suffix string) string {
	runes := s.runes()
	if runes.len <= max_len {
		return s
	}
	suffix_r := suffix.runes()
	keep := if max_len > suffix_r.len { max_len - suffix_r.len } else { 0 }
	// Walk backwards from keep to find a space.
	mut cut := keep
	for cut > 0 && runes[cut] != ` ` {
		cut--
	}
	if cut == 0 {
		// No space found - hard-cut at keep.
		cut = keep
	}
	return runes[..cut].string().trim_right(' ') + suffix
}

// chunks splits s into a slice of substrings each at most max_len bytes long.
// Useful for splitting a long reply that would exceed Telegram's 4096-char limit.
pub fn chunks(s string, max_len int) []string {
	if max_len <= 0 || s.len == 0 {
		return [s]
	}
	mut out := []string{}
	mut i := 0
	for i < s.len {
		end := if i + max_len < s.len { i + max_len } else { s.len }
		out << s[i..end]
		i = end
	}
	return out
}

// chunks_runes splits s into substrings each at most max_len RUNES long.
// Unlike chunks(), this is safe for multi-byte (e.g. emoji, CJK) text.
pub fn chunks_runes(s string, max_len int) []string {
	if max_len <= 0 || s.len == 0 {
		return [s]
	}
	runes := s.runes()
	mut out := []string{}
	mut i := 0
	for i < runes.len {
		end := if i + max_len < runes.len { i + max_len } else { runes.len }
		out << runes[i..end].string()
		i = end
	}
	return out
}

// word_wrap splits text into lines of at most max_width characters, breaking
// on word boundaries where possible.
pub fn word_wrap(text string, max_width int) []string {
	if max_width <= 0 {
		return [text]
	}
	words := text.split(' ')
	mut lines := []string{}
	mut line := ''
	for word in words {
		if line.len == 0 {
			line = word
		} else if line.len + 1 + word.len <= max_width {
			line = '${line} ${word}'
		} else {
			lines << line
			line = word
		}
	}
	if line.len > 0 {
		lines << line
	}
	return lines
}

// strip_html removes all HTML tags from s, returning plain text.
// Useful for converting HTML-formatted Telegram messages to plain strings.
pub fn strip_html(s string) string {
	mut result := []u8{}
	mut inside := false
	for ch in s.bytes() {
		if ch == u8(`<`) {
			inside = true
			continue
		}
		if ch == u8(`>`) {
			inside = false
			continue
		}
		if !inside {
			result << ch
		}
	}
	return result.bytestr()
}

// --- Bot command parsing ---

// CommandArgs holds the parsed result of a bot command message.
pub struct CommandArgs {
pub:
	// command is the command keyword without the leading slash, lowercased.
	// For "/Start@mybot arg1" -> "start"
	command string
	// args contains the whitespace-separated arguments after the command.
	// For "/echo hello world" -> ["hello", "world"]
	args []string
	// raw_args is the full argument string after the command.
	raw_args string
}

// parse_command splits a bot message text into a CommandArgs.
// Returns none when the text does not start with '/'.
// Strips the optional @botname suffix from the command.
pub fn parse_command(text string) ?CommandArgs {
	if text.len == 0 || text[0] != u8(`/`) {
		return none
	}
	rest := text[1..]
	space_idx := rest.index(' ') or { -1 }
	raw_cmd := if space_idx >= 0 { rest[..space_idx] } else { rest }
	raw_args := if space_idx >= 0 { rest[space_idx + 1..].trim_space() } else { '' }
	at_idx := raw_cmd.index('@') or { -1 }
	cmd_str := (if at_idx >= 0 { raw_cmd[..at_idx] } else { raw_cmd }).to_lower()
	args := if raw_args.len > 0 {
		raw_args.split(' ').filter(it.len > 0)
	} else {
		[]string{}
	}
	return CommandArgs{
		command:  cmd_str
		args:     args
		raw_args: raw_args
	}
}

// --- Time helpers ---

// unix_now returns the current Unix timestamp as i64.
pub fn unix_now() i64 {
	return time.now().unix()
}

// unix_to_date formats a Unix timestamp as "YYYY-MM-DD HH:MM:SS" in UTC.
pub fn unix_to_date(ts i64) string {
	return time.unix(ts).format_ss()
}

// relative_time returns a human-readable relative time string for a Unix timestamp,
// measured from the current time.
// Examples: "just now", "3 minutes ago", "2 hours ago", "yesterday", "5 days ago".
pub fn relative_time(ts i64) string {
	diff := unix_now() - ts
	if diff < 0 {
		return 'in the future'
	}
	if diff < 60 {
		return 'just now'
	}
	if diff < 3600 {
		m := diff / 60
		return if m == 1 { '1 minute ago' } else { '${m} minutes ago' }
	}
	if diff < 86400 {
		h := diff / 3600
		return if h == 1 { '1 hour ago' } else { '${h} hours ago' }
	}
	if diff < 172800 {
		return 'yesterday'
	}
	d := diff / 86400
	return '${d} days ago'
}

// plural returns word with the correct suffix for count.
// Examples: plural(1, "item", "items") -> "1 item",  plural(5, "item", "items") -> "5 items".
pub fn plural(count i64, singular string, plural_form string) string {
	return if count == 1 { '${count} ${singular}' } else { '${count} ${plural_form}' }
}

// --- Telegram-specific text helpers ---

// normalize_mention strips a leading '@' from a username string.
// "@mybot" -> "mybot",  "mybot" -> "mybot".
pub fn normalize_mention(username string) string {
	return if username.starts_with('@') { username[1..] } else { username }
}

// extract_mentions returns all @username tokens found in text, without the '@'.
// Only ASCII-alphanumeric usernames and underscores are matched.
pub fn extract_mentions(text string) []string {
	mut out := []string{}
	mut i := 0
	bytes := text.bytes()
	for i < bytes.len {
		if bytes[i] == u8(`@`) {
			i++
			mut j := i
			for j < bytes.len {
				b := bytes[j]
				if (b >= u8(`a`) && b <= u8(`z`)) || (b >= u8(`A`) && b <= u8(`Z`))
					|| (b >= u8(`0`) && b <= u8(`9`)) || b == u8(`_`) {
					j++
				} else {
					break
				}
			}
			if j > i {
				out << text[i..j]
				i = j
			}
		} else {
			i++
		}
	}
	return out
}

// extract_hashtags returns all #tag tokens found in text, without the '#'.
pub fn extract_hashtags(text string) []string {
	mut out := []string{}
	mut i := 0
	bytes := text.bytes()
	for i < bytes.len {
		if bytes[i] == u8(`#`) {
			i++
			mut j := i
			for j < bytes.len {
				b := bytes[j]
				if (b >= u8(`a`) && b <= u8(`z`)) || (b >= u8(`A`) && b <= u8(`Z`))
					|| (b >= u8(`0`) && b <= u8(`9`)) || b == u8(`_`) {
					j++
				} else {
					break
				}
			}
			if j > i {
				out << text[i..j]
				i = j
			}
		} else {
			i++
		}
	}
	return out
}

// is_valid_username checks whether s is a valid Telegram username.
// Rules: 5-32 chars, only letters/digits/underscores, cannot start/end with underscore.
pub fn is_valid_username(s string) bool {
	clean := normalize_mention(s)
	if clean.len < 5 || clean.len > 32 {
		return false
	}
	if clean.starts_with('_') || clean.ends_with('_') {
		return false
	}
	for b in clean.bytes() {
		if !((b >= u8(`a`) && b <= u8(`z`)) || (b >= u8(`A`) && b <= u8(`Z`))
			|| (b >= u8(`0`) && b <= u8(`9`)) || b == u8(`_`)) {
			return false
		}
	}
	return true
}

// is_valid_command checks whether s is a valid BotFather command keyword.
// Rules: 1-32 chars, only lowercase letters, digits, and underscores.
pub fn is_valid_command(s string) bool {
	cmd := if s.starts_with('/') { s[1..] } else { s }
	if cmd.len == 0 || cmd.len > 32 {
		return false
	}
	for b in cmd.bytes() {
		if !((b >= u8(`a`) && b <= u8(`z`)) || (b >= u8(`0`) && b <= u8(`9`)) || b == u8(`_`)) {
			return false
		}
	}
	return true
}

// --- Fuzzy command matching ---

// levenshtein returns the edit distance between strings a and b.
// Useful for suggesting the closest command when the user mistyped.
pub fn levenshtein(a string, b string) int {
	ar := a.runes()
	br := b.runes()
	m := ar.len
	n := br.len
	mut dp := [][]int{len: m + 1, init: []int{len: n + 1}}
	for i := 0; i <= m; i++ {
		dp[i][0] = i
	}
	for j := 0; j <= n; j++ {
		dp[0][j] = j
	}
	for i := 1; i <= m; i++ {
		for j := 1; j <= n; j++ {
			cost := if ar[i - 1] == br[j - 1] { 0 } else { 1 }
			mut best := dp[i - 1][j] + 1
			if dp[i][j - 1] + 1 < best {
				best = dp[i][j - 1] + 1
			}
			if dp[i - 1][j - 1] + cost < best {
				best = dp[i - 1][j - 1] + cost
			}
			dp[i][j] = best
		}
	}
	return dp[m][n]
}

// closest_command finds the command in candidates whose name is closest to input.
// Returns none if candidates is empty or if the best distance exceeds max_dist.
// Typical max_dist: 2 (allows one insertion + one substitution).
pub fn closest_command(input string, candidates []string, max_dist int) ?string {
	clean := if input.starts_with('/') { input[1..] } else { input }
	mut best_dist := max_dist + 1
	mut best := ''
	for c in candidates {
		clean_c := if c.starts_with('/') { c[1..] } else { c }
		d := levenshtein(clean, clean_c)
		if d < best_dist {
			best_dist = d
			best = c
		}
	}
	return if best_dist <= max_dist { best } else { none }
}

// --- Misc ---

// clamp restricts v to the closed interval [lo, hi].
pub fn clamp[T](v T, lo T, hi T) T {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// contains_any returns true if s contains at least one of the given substrings.
pub fn contains_any(s string, needles []string) bool {
	for n in needles {
		if s.contains(n) {
			return true
		}
	}
	return false
}

// --- Rate limiting ---

// RateLimiter enforces a maximum of max_calls per window_seconds for any key
// (typically a user_id or chat_id cast to string).  Thread-safe.
//
// USAGE - always allocate via RateLimiter.new() and keep as a pointer so the
// internal sync.Mutex is never copied:
//
//   mut rl := tdlib.RateLimiter.new(3, 10)  // 3 calls per 10 s
//   if rl.allow('${user_id}') {
//       bot.send_text(chat_id, reply) or {}
//   } else {
//       bot.send_text(chat_id, 'Slow down!') or {}
//   }
pub struct RateLimiter {
pub mut:
	max_calls      int
	window_seconds i64
	mu             sync.Mutex
	buckets        map[string][]i64 // key -> list of call timestamps
}

// RateLimiter.new creates a rate limiter allowing max_calls per window_seconds.
// Returns a heap-allocated pointer so the internal mutex is never implicitly copied.
pub fn RateLimiter.new(max_calls int, window_seconds i64) &RateLimiter {
	return &RateLimiter{
		max_calls:      max_calls
		window_seconds: window_seconds
		buckets:        map[string][]i64{}
	}
}

// allow returns true and records a call if key has not exceeded the limit.
// Returns false (without recording) if the limit has been reached.
pub fn (mut rl RateLimiter) allow(key string) bool {
	rl.mu.lock()
	defer { rl.mu.unlock() }
	now := unix_now()
	cutoff := now - rl.window_seconds
	mut calls := rl.buckets[key] or { []i64{} }
	// Drop timestamps outside the window.
	calls = calls.filter(it > cutoff)
	if calls.len >= rl.max_calls {
		rl.buckets[key] = calls
		return false
	}
	calls << now
	rl.buckets[key] = calls
	return true
}

// reset clears the call history for key (e.g. after a ban is lifted).
pub fn (mut rl RateLimiter) reset(key string) {
	rl.mu.lock()
	defer { rl.mu.unlock() }
	rl.buckets.delete(key)
}

// remaining returns how many calls key can still make in the current window.
pub fn (mut rl RateLimiter) remaining(key string) int {
	rl.mu.lock()
	defer { rl.mu.unlock() }
	now := unix_now()
	cutoff := now - rl.window_seconds
	calls := (rl.buckets[key] or { []i64{} }).filter(it > cutoff)
	r := rl.max_calls - calls.len
	return if r < 0 { 0 } else { r }
}

// =============================================================================
// SECTION 3: User Account
// Authentication state machines, shared API implementations, extra content
// types, file management, proxy, chat folders, scheduling, forum topics,
// translation, and the UserAccount struct with all its public methods.
// =============================================================================

// --- auth.v ---

// --- Custom auth handler types ---

// UserLoginHandler provides callbacks for each step of the user authorization
// flow.  Only the callbacks your application needs must be assigned; any
// callback left as none (the zero value) falls back to reading from stdin via
// os.input(), which is the same behaviour as login().
//
// Minimum required fields: get_phone (or pass phone to login()), get_code.
// get_password is only needed when the account has 2FA enabled.
// get_email / get_email_code are only needed when Telegram requests them.
// get_first_name is only needed for brand-new accounts (registration).
pub struct UserLoginHandler {
pub:
	// get_phone returns the phone number string (with country code, e.g. "+12025550100").
	// Called when authorizationStateWaitPhoneNumber is received.
	// A none value falls back to an os.input() prompt.
	get_phone ?fn () string
	// get_email returns the email address when Telegram requests it.
	// A none value falls back to an os.input() prompt.
	get_email ?fn () string
	// get_email_code returns the verification code received at the email address.
	// A none value falls back to an os.input() prompt.
	get_email_code ?fn () string
	// get_code returns the OTP/SMS/Telegram authentication code.
	// A none value falls back to an os.input() prompt.
	get_code ?fn () string
	// get_password returns the 2FA cloud password.
	// A none value falls back to an os.input() prompt.
	get_password ?fn () string
	// get_first_name returns the first name to use when registering a new account.
	// A none value falls back to an os.input() prompt.
	get_first_name ?fn () string
	// get_last_name returns the last name to use when registering a new account
	// (may return '' to omit the last name).
	// A none value falls back to an os.input() prompt.
	get_last_name ?fn () string
	// on_qr_link is called when authorizationStateWaitOtherDeviceConfirmation is
	// received.  The link parameter is the tg:// URL that should be displayed as a
	// QR code or opened on another logged-in device.
	// A none value falls back to printing the link to stdout.
	on_qr_link ?fn (link string)
}

// BotLoginHandler provides a custom callback for supplying the bot token during
// the bot authentication flow.  Assign get_token to read the token from any
// source (environment variable, config file, secrets manager, etc.).
//
// A none get_token falls back to reading from stdin.
pub struct BotLoginHandler {
pub:
	// get_token returns the bot token string (e.g. "123456789:ABC-DEF1234...").
	// Called when authorizationStateWaitPhoneNumber is received for a bot session.
	// A none value falls back to an os.input() prompt.
	get_token ?fn () string
}

// --- Public auth entry points ---

// run_user_auth drives the authorization state machine for a phone-number user
// account.  phone is optional: when provided it is used automatically; when
// none the user is prompted via stdin.  Blocks until authorizationStateReady
// or error.  Called by UserAccount.login().
//
// phone is now ?string so that login() can be called with or without
// a pre-known phone number, removing the forced stdin prompt for callers that
// already have the phone number at login time.
fn run_user_auth(session Session, mut td TDLib, phone ?string) ! {
	handler := if p := phone {
		UserLoginHandler{
			get_phone: fn [p] () string {
				return p
			}
		}
	} else {
		UserLoginHandler{}
	}
	run_user_auth_with_handler(session, mut td, handler)!
}

// run_user_auth_with_handler drives the authorization state machine using the
// callbacks in handler.  Any none callback falls back to os.input().
// Blocks until authorizationStateReady or error.
// Called directly by UserAccount.login_custom().
fn run_user_auth_with_handler(session Session, mut td TDLib, handler UserLoginHandler) ! {
	for {
		update := td.get_update(session.id)
		m := update.as_map()
		typ := map_str(m, '@type')
		// Detect hub shutdown sentinel or closed-channel zero value.
		if typ == 'tdlibShutdown' || typ == '' {
			return error('TDLib hub shut down during authentication')
		}
		if typ != 'updateAuthorizationState' {
			continue
		}
		state := map_obj(m, 'authorization_state')
		match map_str(state, '@type') {
			'authorizationStateWaitTdlibParameters' {
				// Parameters already sent in setup() - nothing to do here.
			}
			'authorizationStateWaitPhoneNumber' {
				// Optional functions (?fn() string) must be unwrapped with
				// an if-let pattern before calling.  The previous code used
				// `handler.get_phone != none` (invalid for V optionals) and then
				// called `handler.get_phone()` directly on the unwrapped optional
				// without unwrapping first.  All handler field accesses below are
				// corrected to use `if f := handler.xxx { f() }`.
				phone := if f := handler.get_phone {
					f()
				} else {
					os.input('Phone number (with country code): ').trim_space()
				}
				if phone == '' {
					return error('no phone number entered')
				}
				send_phone_number(session, mut td, phone)!
			}
			'authorizationStateWaitEmailAddress' {
				email := if f := handler.get_email {
					f()
				} else {
					os.input('Email address for login: ').trim_space()
				}
				send_email_address(session, mut td, email)!
			}
			'authorizationStateWaitEmailCode' {
				code := if f := handler.get_email_code {
					f()
				} else {
					os.input('Email authentication code: ').trim_space()
				}
				send_email_code(session, mut td, code)!
			}
			'authorizationStateWaitOtherDeviceConfirmation' {
				// The user must confirm the login attempt on another logged-in device.
				// TDLib provides a tg:// link that should be displayed as a QR code or
				// opened on the other device.  TDLib transitions automatically once the
				// confirmation is received; no API call is needed here.
				link := map_str(state, 'link')
				if f := handler.on_qr_link {
					f(link)
				} else if link != '' {
					println('Confirm this login on another device by opening: ${link}')
				} else {
					println('Confirm this login on another device (check your Telegram app).')
				}
				// No API call needed; TDLib transitions automatically once confirmed.
			}
			'authorizationStateWaitCode' {
				code := if f := handler.get_code {
					f()
				} else {
					os.input('Authentication code: ').trim_space()
				}
				if code == '' {
					return error('no authentication code entered')
				}
				send_auth_code(session, mut td, code)!
			}
			'authorizationStateWaitRegistration' {
				first := if f := handler.get_first_name {
					f()
				} else {
					os.input('First name: ').trim_space()
				}
				last := if f := handler.get_last_name {
					f()
				} else {
					os.input('Last name (optional): ').trim_space()
				}
				register_user(session, mut td, first, last)!
			}
			'authorizationStateWaitPassword' {
				pass := if f := handler.get_password {
					f()
				} else {
					os.input('2FA password: ').trim_space()
				}
				if pass == '' {
					return error('no 2FA password entered')
				}
				send_auth_password(session, mut td, pass)!
			}
			'authorizationStateReady' {
				return
			}
			'authorizationStateLoggingOut' {
				return error('session is logging out')
			}
			'authorizationStateClosed' {
				return error('TDLib session closed unexpectedly')
			}
			else {}
		}
	}
}

// run_bot_auth drives the authorization state machine for a bot token.
// Blocks until authorizationStateReady or error.
// Called by BotAccount.login().
fn run_bot_auth(session Session, mut td TDLib, token string) ! {
	handler := BotLoginHandler{
		get_token: fn [token] () string {
			return token
		}
	}
	run_bot_auth_with_handler(session, mut td, handler)!
}

// run_bot_auth_with_handler drives the bot authorization state machine using
// the callback in handler.  A none get_token falls back to os.input().
// Blocks until authorizationStateReady or error.
// Called directly by BotAccount.login_custom().
fn run_bot_auth_with_handler(session Session, mut td TDLib, handler BotLoginHandler) ! {
	for {
		update := td.get_update(session.id)
		m := update.as_map()
		typ := map_str(m, '@type')
		// Detect hub shutdown sentinel or closed-channel zero value.
		if typ == 'tdlibShutdown' || typ == '' {
			return error('TDLib hub shut down during authentication')
		}
		if typ != 'updateAuthorizationState' {
			continue
		}
		state := map_obj(m, 'authorization_state')
		match map_str(state, '@type') {
			'authorizationStateWaitTdlibParameters' {
				// Parameters already sent in setup() - nothing to do.
			}
			'authorizationStateWaitPhoneNumber' {
				// TDLib enters this state for bots too; we respond with the bot
				// token (not a phone number) via checkAuthenticationBotToken.
				// unwrap optional function with if-let before calling.
				token := if f := handler.get_token {
					f()
				} else {
					os.input('Bot token: ').trim_space()
				}
				if token == '' {
					return error('no bot token provided')
				}
				send_bot_token(session, mut td, token)!
			}
			'authorizationStateReady' {
				return
			}
			'authorizationStateLoggingOut' {
				return error('session is logging out')
			}
			'authorizationStateClosed' {
				return error('TDLib session closed unexpectedly')
			}
			'authorizationStateWaitCode', 'authorizationStateWaitPassword',
			'authorizationStateWaitRegistration', 'authorizationStateWaitEmailAddress',
			'authorizationStateWaitEmailCode', 'authorizationStateWaitOtherDeviceConfirmation' {
				return error('unexpected auth state for bot: ${map_str(state, '@type')}')
			}
			else {}
		}
	}
}

// --- Auth sub-step helpers ---

fn send_phone_number(s Session, mut td TDLib, phone string) ! {
	req := new_request('setAuthenticationPhoneNumber').with_str('phone_number', phone).build()!
	s.send_fire(mut td, req)!
}

fn send_bot_token(s Session, mut td TDLib, token string) ! {
	req := new_request('checkAuthenticationBotToken').with_str('token', token).build()!
	s.send_fire(mut td, req)!
}

fn send_auth_code(s Session, mut td TDLib, code string) ! {
	req := new_request('checkAuthenticationCode').with_str('code', code).build()!
	s.send_fire(mut td, req)!
}

fn send_auth_password(s Session, mut td TDLib, password string) ! {
	req := new_request('checkAuthenticationPassword').with_str('password', password).build()!
	s.send_fire(mut td, req)!
}

fn send_email_address(s Session, mut td TDLib, email string) ! {
	req := new_request('setAuthenticationEmailAddress').with_str('email_address', email).build()!
	s.send_fire(mut td, req)!
}

fn send_email_code(s Session, mut td TDLib, code string) ! {
	// TDLib schema: checkAuthenticationEmailCode code:EmailAddressAuthentication
	// emailAddressAuthenticationCode is the typed wrapper for a plain code string.
	req := new_request('checkAuthenticationEmailCode').with_obj('code', {
		'@type': json2.Any('emailAddressAuthenticationCode')
		'code':  json2.Any(code)
	}).build()!
	s.send_fire(mut td, req)!
}

fn register_user(s Session, mut td TDLib, first_name string, last_name string) ! {
	req := new_request('registerUser').with_str('first_name', first_name).with_str('last_name',
		last_name).build()!
	s.send_fire(mut td, req)!
}

// --- common.v ---

// --- TDLib parameters ---

fn setup_parameters(s Session, mut td TDLib, api_id int, api_hash string, data_dir string) !json2.Any {
	req := new_request('setTdlibParameters').with_str('database_directory', data_dir).with_bool('use_message_database', true).with_bool('use_file_database', true).with_bool('use_chat_info_database', true).with_int('api_id',
		api_id).with_str('api_hash', api_hash).with_str('system_language_code', 'en').with_str('device_model',
		'Server').with_str('application_version', '1.0').build()!
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
	req :=
		new_request('getMessage').with_i64('chat_id', chat_id).with_i64('message_id', message_id).build()!
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
	// message_thread_id is the forum topic thread ID for supergroup topics (0 = no topic).
	// Obtain this from ForumTopicInfo.message_thread_id() after calling create_forum_topic()
	// or get_forum_topics().
	message_thread_id i64
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
	return dispatch_send_message(s, mut td, chat_id, content, opts,
		json2.Any(map[string]json2.Any{}))
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
		// inputMessagePhoto requires self_destruct_type:MessageSelfDestructType,
		// which must be a typed object with @type 'messageSelfDestructTypeTimer'.
		// Sending a plain integer for self_destruct_time was rejected by TDLib.
		fields['self_destruct_type'] = typed_obj('messageSelfDestructTypeTimer', {
			'self_destruct_time': json2.Any(opts.ttl)
		})
	}
	return dispatch_send_message(s, mut td, chat_id, obj(fields), opts.send,
		json2.Any(map[string]json2.Any{}))
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
		// Same as send_photo - inputMessageVideo requires self_destruct_type
		// as a typed MessageSelfDestructType object, not a bare integer.
		fields['self_destruct_type'] = typed_obj('messageSelfDestructTypeTimer', {
			'self_destruct_time': json2.Any(opts.ttl)
		})
	}
	return dispatch_send_message(s, mut td, chat_id, obj(fields), opts.send,
		json2.Any(map[string]json2.Any{}))
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
	return dispatch_send_message(s, mut td, chat_id, content, opts.send,
		json2.Any(map[string]json2.Any{}))
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
	return dispatch_send_message(s, mut td, chat_id, obj(fields), opts.send,
		json2.Any(map[string]json2.Any{}))
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
	return dispatch_send_message(s, mut td, chat_id, content, opts.send,
		json2.Any(map[string]json2.Any{}))
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
	return dispatch_send_message(s, mut td, chat_id, content, opts.send,
		json2.Any(map[string]json2.Any{}))
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
	return dispatch_send_message(s, mut td, chat_id, content, opts.send,
		json2.Any(map[string]json2.Any{}))
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
	return dispatch_send_message(s, mut td, chat_id, content, opts,
		json2.Any(map[string]json2.Any{}))
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
	return dispatch_send_message(s, mut td, chat_id, json2.Any(fields), opts.send,
		json2.Any(map[string]json2.Any{}))
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
	return dispatch_send_message(s, mut td, chat_id, content, opts.send,
		json2.Any(map[string]json2.Any{}))
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
				// passing an empty map for targetChatChosen leaves all
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
				// inlineKeyboardButtonTypeCallback.data is declared as `bytes`
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
	req := new_request('editInlineMessageReplyMarkup').with_str('inline_message_id',
		inline_message_id).with('reply_markup', markup).build()!
	return s.send_sync(mut td, req)
}

// edit_inline_message_text replaces the text content of a message that was
// originally sent via an inline query.
// inline_message_id: the string from updateNewInlineCallbackQuery.inline_message_id.
fn edit_inline_message_text(s Session, mut td TDLib, inline_message_id string, formatted json2.Any, markup json2.Any) !json2.Any {
	mut req := new_request('editInlineMessageText').with_str('inline_message_id', inline_message_id).with_obj('input_message_content', {
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
// The location sub-object must carry @type:'location' like all
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
	req := new_request('sendChatAction').with_i64('chat_id', chat_id).with_obj('action', {
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
	req := new_request('downloadFile').with_i64('file_id', file_id).with_int('priority', clamped).with_int('offset', 0).with_int('limit', 0).with_bool('synchronous',
		false).build()!
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
	req := new_request('addProxy').with_str('server', server).with_int('port', port).with_bool('enable', true).with_obj('type', {
		'@type':    json2.Any('proxyTypeSocks5')
		'username': json2.Any(username)
		'password': json2.Any(password)
	}).build()!
	return s.send_sync(mut td, req)
}

fn add_http_proxy(s Session, mut td TDLib, server string, port int, username string, password string) !json2.Any {
	req := new_request('addProxy').with_str('server', server).with_int('port', port).with_bool('enable', true).with_obj('type', {
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
	if opts.message_thread_id != 0 {
		req = req.with_i64('message_thread_id', opts.message_thread_id)
	}
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

// --- extras.v ---

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
// The previous implementation omitted the required banned_until_date field.
// TDLib's banChatMember signature:
//   banChatMember chat_id member_id banned_until_date:int32 revoke_messages:bool
// banned_until_date is a Unix timestamp; 0 means the ban never expires (permanent).
fn ban_chat_member(s Session, mut td TDLib, chat_id i64, user_id i64, revoke_messages bool) !json2.Any {
	req := new_request('banChatMember').with_i64('chat_id', chat_id).with_obj('member_id', {
		'@type':   json2.Any('messageSenderUser')
		'user_id': json2.Any(user_id)
	}).with_int('banned_until_date', 0).with_bool('revoke_messages', revoke_messages).build()!
	return s.send_sync(mut td, req)
}

// unban_chat_member lifts a ban, allowing the user to re-join.
fn unban_chat_member(s Session, mut td TDLib, chat_id i64, user_id i64) !json2.Any {
	req := new_request('setChatMemberStatus').with_i64('chat_id', chat_id).with_obj('member_id', {
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
	req := new_request('setChatMemberStatus').with_i64('chat_id', chat_id).with_obj('member_id', {
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
	req := new_request('setChatMemberStatus').with_i64('chat_id', chat_id).with_obj('member_id', {
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
// The previous implementation called map_int(resp.raw, 'member_count') on a
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
		req :=
			new_request('getSupergroupFullInfo').with_i64('supergroup_id', chat.supergroup_id()).build()!
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
	req := new_request('getChatMember').with_i64('chat_id', chat_id).with_obj('member_id', {
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
	req := new_request('getSupergroupMembers').with_i64('supergroup_id', supergroup_id).with_obj('filter', {
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
	req :=
		new_request('setChatTitle').with_i64('chat_id', chat_id).with_str('title', title).build()!
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
// The previous implementation used '@type': 'inputChatPhotoLocal', which
// does not exist in TDLib. The correct type is 'inputChatPhotoStatic'.
fn set_chat_photo(s Session, mut td TDLib, chat_id i64, local_path string) !json2.Any {
	req := new_request('setChatPhoto').with_i64('chat_id', chat_id).with_obj('photo', {
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
	req := new_request('viewMessages').with_i64('chat_id', chat_id).with_obj('source', {
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
	return dispatch_send_message(s, mut td, chat_id, content, opts,
		json2.Any(map[string]json2.Any{}))
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
	return dispatch_send_message(s, mut td, chat_id, obj(fields), opts.send,
		json2.Any(map[string]json2.Any{}))
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
	return dispatch_send_message(s, mut td, chat_id, obj(poll_fields), opts.send,
		json2.Any(map[string]json2.Any{}))
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
	req :=
		new_request('stopPoll').with_i64('chat_id', chat_id).with_i64('message_id', message_id).build()!
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
	return dispatch_send_message(s, mut td, chat_id, content, opts,
		json2.Any(map[string]json2.Any{}))
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
// The previous implementation omitted the required 'filter' parameter.
// TDLib's searchChatMessages schema:
//   searchChatMessages chat_id from_message_id offset limit query
//     sender_id:MessageSender? filter:SearchMessagesFilter message_thread_id
// Omitting 'filter' caused TDLib to reject the request.  Pass
// searchMessagesFilterEmpty to search all message types.
fn search_messages_in_chat(s Session, mut td TDLib, chat_id i64, query string, from_message_id i64, limit int) ![]Message {
	req := new_request('searchChatMessages').with_i64('chat_id', chat_id).with_str('query', query).with_i64('from_message_id',
		from_message_id).with_int('offset', 0).with_int('limit', limit).with_obj('filter', {
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
	req := new_request('getUserProfilePhotos').with_i64('user_id', user_id).with_int('offset', 0).with_int('limit',
		limit).build()!
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
		from_chat_id).with('message_ids', arr_of_i64([message_id])).with_bool('send_copy', true).with_bool('remove_caption',
		remove_caption)
	if opts.silent || opts.protect_content {
		req = req.with_obj('options', {
			'@type':                json2.Any('messageSendOptions')
			'disable_notification': json2.Any(opts.silent)
			'protect_content':      json2.Any(opts.protect_content)
		})
	}
	// reply_to_message_id from SendOptions was silently ignored.
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
	req := new_request('setChatMemberStatus').with_i64('chat_id', chat_id).with_obj('member_id', {
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
	req := new_request('setChatMemberStatus').with_i64('chat_id', chat_id).with_obj('member_id', {
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

// --- filemanager.v ---

// --- File type constants ---
// Pass these to upload_file() to tell TDLib how to classify the upload.

pub const file_type_photo = 'fileTypePhoto'
pub const file_type_video = 'fileTypeVideo'
pub const file_type_audio = 'fileTypeAudio'
pub const file_type_voice = 'fileTypeVoiceNote'
pub const file_type_video_note = 'fileTypeVideoNote'
pub const file_type_document = 'fileTypeDocument'
pub const file_type_sticker = 'fileTypeSticker'
pub const file_type_animation = 'fileTypeAnimation'

// --- Synchronous download ---

// download_file_sync downloads a file and BLOCKS until TDLib reports it is
// fully on disk.  Returns a TDFile with local_path() set.
//
// Unlike download_file(), no 'updateFile' handler is needed.  TDLib handles
// the blocking internally via the synchronous flag.
//
// priority: 1 (lowest) .. 32 (highest).  Files at priority 32 jump ahead of
// any background downloads already queued.
fn download_file_sync(s Session, mut td TDLib, file_id i64, priority int) !TDFile {
	clamped := if priority < 1 {
		1
	} else if priority > 32 {
		32
	} else {
		priority
	}
	req :=
		new_request('downloadFile').with_i64('file_id', file_id).with_int('priority', clamped).with_int('offset', 0).with_int('limit', 0).with_bool('synchronous', true).build()!
	resp := s.send_sync(mut td, req)!
	return TDFile.from(resp.as_map())
}

// --- Preliminary upload ---

// preliminary_upload_file pre-uploads a local file to Telegram without
// sending it anywhere.  Returns a TDFile whose remote_id() can be used in
// subsequent input_remote() calls to send the same file to many recipients
// without re-uploading.
//
// file_type: one of the file_type_* constants, e.g. file_type_photo.
// progress:  register an 'updateFile' handler to track upload progress.
//            Once the upload completes f.is_downloaded() stays false, but
//            f.remote_id() becomes non-empty - that is your reuse token.
//
// Typical bot pattern (send the same image to 1000 users):
//
//   f := bot.upload_file('/tmp/promo.jpg', tdlib.file_type_photo)!
//   // watch updateFile for f.id() until remote_unique_id is set, then:
//   for user_id in user_ids {
//       bot.send_photo(user_id, tdlib.input_remote(f.remote_id()), tdlib.PhotoSendOptions{})!
//   }
fn preliminary_upload_file(s Session, mut td TDLib, local_path string, file_type string) !TDFile {
	req := new_request('preliminaryUploadFile').with('file', input_local(local_path)).with_obj('file_type', {
		'@type': json2.Any(file_type)
	}).with_int('priority', 1).build()!
	resp := s.send_sync(mut td, req)!
	return TDFile.from(resp.as_map())
}

// cancel_preliminary_upload cancels an in-progress preliminary upload started
// by upload_file().  file_id is the TDFile.id() returned from that call.
// Has no effect if the upload has already completed.
fn cancel_preliminary_upload(s Session, mut td TDLib, file_id i64) !json2.Any {
	req := new_request('cancelPreliminaryUploadFile').with_i64('file_id', file_id).build()!
	return s.send_sync(mut td, req)
}

// --- proxy.v ---

// --- Proxy type ---

// Proxy wraps a TDLib proxy object returned by getProxies / addProxy.
pub struct Proxy {
pub:
	raw map[string]json2.Any
}

pub fn Proxy.from(m map[string]json2.Any) Proxy {
	return Proxy{
		raw: m
	}
}

// id returns the TDLib integer proxy ID used in enable_proxy / remove_proxy.
pub fn (p Proxy) id() int {
	return map_int(p.raw, 'id')
}

// server returns the proxy server hostname or IP address.
pub fn (p Proxy) server() string {
	return map_str(p.raw, 'server')
}

// port returns the proxy port number.
pub fn (p Proxy) port() int {
	return map_int(p.raw, 'port')
}

// is_enabled returns true if this proxy is the currently active one.
pub fn (p Proxy) is_enabled() bool {
	return map_bool(p.raw, 'is_enabled')
}

// last_used_date returns the Unix timestamp of when this proxy was last used,
// or 0 if it has never been used.
pub fn (p Proxy) last_used_date() i64 {
	return map_i64(p.raw, 'last_used_date')
}

// proxy_type returns the @type string of the proxy's type object:
//   "proxyTypeSocks5", "proxyTypeHttp", or "proxyTypeMtproto".
pub fn (p Proxy) proxy_type() string {
	return map_type(p.raw, 'type')
}

// --- ProxyPingResult ---

// ProxyPingResult pairs a Proxy with its measured round-trip latency.
// Returned by get_proxies_sorted_by_ping().
pub struct ProxyPingResult {
pub:
	proxy   Proxy
	ping_ms f64
}

// --- Implementation ---

// add_mtproto_proxy adds a Telegram MTProto proxy and immediately enables it.
// secret: the proxy secret string provided by the proxy operator (hex or
//         base64-url encoded, depending on the proxy).
// Returns a typed Proxy object so you can immediately read its id().
fn add_mtproto_proxy(s Session, mut td TDLib, server string, port int, secret string) !Proxy {
	req := new_request('addProxy').with_str('server', server).with_int('port', port).with_bool('enable', true).with_obj('type', {
		'@type':  json2.Any('proxyTypeMtproto')
		'secret': json2.Any(secret)
	}).build()!
	resp := s.send_sync(mut td, req)!
	return Proxy.from(resp.as_map())
}

// get_proxies returns all proxies currently stored by TDLib for this session.
fn get_proxies(s Session, mut td TDLib) ![]Proxy {
	req := new_request('getProxies').build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'proxies')
	mut out := []Proxy{cap: raw_arr.len}
	for item in raw_arr {
		out << Proxy.from(item.as_map())
	}
	return out
}

// remove_proxy permanently removes a proxy by its TDLib integer ID.
// The proxy must not be in use; call disable_proxy() first if necessary.
fn remove_proxy(s Session, mut td TDLib, proxy_id int) !json2.Any {
	req := new_request('removeProxy').with_int('proxy_id', proxy_id).build()!
	return s.send_sync(mut td, req)
}

// enable_proxy enables a specific proxy by ID and makes it the active proxy.
// TDLib will route all traffic through it.
fn enable_proxy(s Session, mut td TDLib, proxy_id int) !json2.Any {
	req := new_request('enableProxy').with_int('proxy_id', proxy_id).build()!
	return s.send_sync(mut td, req)
}

// disable_proxy disables the currently active proxy.
// TDLib will connect directly to Telegram after this call.
fn disable_proxy(s Session, mut td TDLib) !json2.Any {
	req := new_request('disableProxy').build()!
	return s.send_sync(mut td, req)
}

// ping_proxy measures the round-trip latency to a proxy in milliseconds.
// Returns an error if the proxy is unreachable within TDLib's timeout.
// proxy_id: the Proxy.id() from get_proxies() or add_*_proxy().
fn ping_proxy(s Session, mut td TDLib, proxy_id int) !f64 {
	req := new_request('pingProxy').with_int('proxy_id', proxy_id).build()!
	resp := s.send_sync(mut td, req)!
	m := resp.as_map()
	// TDLib returns {"@type":"seconds","seconds":0.123}
	v := m['seconds'] or { return 0.0 }
	seconds := if v is f64 {
		f64(v)
	} else {
		v.str().f64()
	}
	return seconds * 1000.0
}

// get_proxies_sorted_by_ping pings every stored proxy and returns the
// reachable ones sorted by latency, fastest first.
// Proxies that time out or return an error are silently omitted.
//
// Use this to automatically select the best available proxy:
//
//   sorted := bot.get_proxies_sorted_by_ping()!
//   if sorted.len > 0 {
//       bot.enable_proxy(sorted[0].proxy.id())!
//   }
fn get_proxies_sorted_by_ping(s Session, mut td TDLib) ![]ProxyPingResult {
	proxies := get_proxies(s, mut td)!
	mut results := []ProxyPingResult{}
	for p in proxies {
		ms := ping_proxy(s, mut td, p.id()) or { continue }
		results << ProxyPingResult{
			proxy:   p
			ping_ms: ms
		}
	}
	results.sort(a.ping_ms < b.ping_ms)
	return results
}

// --- folders.v ---

// --- ChatFolderOptions ---

// ChatFolderOptions holds the parameters for creating or editing a chat folder.
// Fields map directly to the TDLib chatFolder object.
// All boolean fields default to false.
pub struct ChatFolderOptions {
pub:
	// icon_name sets the folder icon.  Pass '' to use the default icon.
	// Recognised values: "All", "Unread", "Unmuted", "Bots", "Channels",
	// "Groups", "Private", "Custom", "Setup", "Cat", "Crown", "Favorite",
	// "Flower", "Game", "Home", "Love", "Mask", "Party", "Sport", "Study",
	// "Trade", "Travel", "Work", "Airplane", "Book", "Light", "Like",
	// "Money", "Note", "Palette".
	icon_name string
	// pinned_chat_ids lists chats that will be pinned inside the folder.
	pinned_chat_ids []i64
	// included_chat_ids lists specific chats always shown in the folder.
	included_chat_ids []i64
	// excluded_chat_ids lists specific chats always hidden from the folder.
	excluded_chat_ids    []i64
	exclude_muted        bool
	exclude_read         bool
	exclude_archived     bool
	include_contacts     bool
	include_non_contacts bool
	include_bots         bool
	include_groups       bool
	include_channels     bool
	// is_shareable controls whether an invite link can be created for this folder.
	is_shareable bool
}

// chat_folder_obj builds the chatFolder JSON object for createChatFolder /
// editChatFolder from a name string and a ChatFolderOptions value.
fn chat_folder_obj(name string, opts ChatFolderOptions) map[string]json2.Any {
	mut pinned := []json2.Any{cap: opts.pinned_chat_ids.len}
	for id in opts.pinned_chat_ids {
		pinned << json2.Any(id)
	}
	mut included := []json2.Any{cap: opts.included_chat_ids.len}
	for id in opts.included_chat_ids {
		included << json2.Any(id)
	}
	mut excluded := []json2.Any{cap: opts.excluded_chat_ids.len}
	for id in opts.excluded_chat_ids {
		excluded << json2.Any(id)
	}
	mut m := map[string]json2.Any{}
	m['@type'] = json2.Any('chatFolder')
	m['name'] = json2.Any({
		'@type': json2.Any('chatFolderName')
		'text':  json2.Any(name)
	})
	if opts.icon_name != '' {
		m['icon'] = json2.Any({
			'@type': json2.Any('chatFolderIcon')
			'name':  json2.Any(opts.icon_name)
		})
	}
	m['is_shareable'] = json2.Any(opts.is_shareable)
	m['pinned_chat_ids'] = json2.Any(pinned)
	m['included_chat_ids'] = json2.Any(included)
	m['excluded_chat_ids'] = json2.Any(excluded)
	m['exclude_muted'] = json2.Any(opts.exclude_muted)
	m['exclude_read'] = json2.Any(opts.exclude_read)
	m['exclude_archived'] = json2.Any(opts.exclude_archived)
	m['include_contacts'] = json2.Any(opts.include_contacts)
	m['include_non_contacts'] = json2.Any(opts.include_non_contacts)
	m['include_bots'] = json2.Any(opts.include_bots)
	m['include_groups'] = json2.Any(opts.include_groups)
	m['include_channels'] = json2.Any(opts.include_channels)
	return m
}

// --- Folder queries ---

// get_chat_folder returns the full chatFolder configuration for a folder ID.
// Use the ID from ChatFolderInfo.id() or from get_chat_folders().
fn get_chat_folder(s Session, mut td TDLib, chat_folder_id int) !ChatFolder {
	req := new_request('getChatFolder').with_int('chat_folder_id', chat_folder_id).build()!
	resp := s.send_sync(mut td, req)!
	return ChatFolder.from(resp.as_map())
}

// get_chat_folders returns the list of all chat folders for this account.
// Each ChatFolderInfo contains the folder ID, name, icon, and share state.
// To get the full filter configuration, call get_chat_folder() with the ID.
//
// TDLib method: getChatFolders -> chatFolders{ folders:vector<chatFolderInfo> }
fn get_chat_folders(s Session, mut td TDLib) ![]ChatFolderInfo {
	req := new_request('getChatFolders').build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'folders')
	mut out := []ChatFolderInfo{cap: raw_arr.len}
	for item in raw_arr {
		out << ChatFolderInfo.from(item.as_map())
	}
	return out
}

// get_chats_in_folder returns the first limit chat IDs from a folder, sorted by
// last activity (most recent first).
// Call get_chat() on each returned ID for full chat details.
//
// TDLib method: getChats chat_list:chatListFolder limit:int32 -> chats{ chat_ids }
fn get_chats_in_folder(s Session, mut td TDLib, chat_folder_id int, limit int) ![]i64 {
	req := new_request('getChats').with_obj('chat_list', {
		'@type':          json2.Any('chatListFolder')
		'chat_folder_id': json2.Any(chat_folder_id)
	}).with_int('limit', limit).build()!
	resp := s.send_sync(mut td, req)!
	raw_ids := map_arr(resp.as_map(), 'chat_ids')
	mut ids := []i64{cap: raw_ids.len}
	for v in raw_ids {
		ids << any_to_i64(v)
	}
	return ids
}

// --- Folder creation and deletion ---

// create_chat_folder creates a new chat folder with the given name and options.
// Returns the ID of the newly created folder on success.
// The folder immediately appears in get_chat_folders() results.
//
// TDLib method: createChatFolder folder:chatFolder -> chatFolderInfo
fn create_chat_folder(s Session, mut td TDLib, name string, opts ChatFolderOptions) !int {
	folder := chat_folder_obj(name, opts)
	req := new_request('createChatFolder').with_obj('folder', folder).build()!
	resp := s.send_sync(mut td, req)!
	return map_int(resp.as_map(), 'id')
}

// edit_chat_folder replaces the configuration of an existing folder.
// Use get_chat_folder() first to read the current settings, modify them,
// and pass the result back here.
//
// TDLib method: editChatFolder chat_folder_id:Int32 folder:chatFolder -> chatFolderInfo
fn edit_chat_folder(s Session, mut td TDLib, chat_folder_id int, name string, opts ChatFolderOptions) !ChatFolderInfo {
	folder := chat_folder_obj(name, opts)
	req := new_request('editChatFolder').with_int('chat_folder_id', chat_folder_id).with_obj('folder',
		folder).build()!
	resp := s.send_sync(mut td, req)!
	return ChatFolderInfo.from(resp.as_map())
}

// delete_chat_folder removes a folder from the account.
// leave_chat_ids: chat IDs to leave when the folder is deleted.
// Pass an empty slice to keep all chats and simply remove the folder.
//
// TDLib method: deleteChatFolder chat_folder_id:Int32 leave_chat_ids:vector<Int53>
fn delete_chat_folder(s Session, mut td TDLib, chat_folder_id int, leave_chat_ids []i64) !json2.Any {
	mut ids := []json2.Any{cap: leave_chat_ids.len}
	for id in leave_chat_ids {
		ids << json2.Any(id)
	}
	req :=
		new_request('deleteChatFolder').with_int('chat_folder_id', chat_folder_id).with_arr('leave_chat_ids', ids).build()!
	return s.send_sync(mut td, req)
}

// --- Adding and removing chats ---

// add_chat_to_folder adds chat_id to the folder identified by chat_folder_id.
// The folder must already exist (use create_chat_folder() or get_chat_folders()
// to find its ID).
//
// TDLib method: addChatToList chat_id:Int53 chat_list:chatListFolder
fn add_chat_to_folder(s Session, mut td TDLib, chat_id i64, chat_folder_id int) !json2.Any {
	req := new_request('addChatToList').with_i64('chat_id', chat_id).with_obj('chat_list', {
		'@type':          json2.Any('chatListFolder')
		'chat_folder_id': json2.Any(chat_folder_id)
	}).build()!
	return s.send_sync(mut td, req)
}

// remove_chat_from_folder removes chat_id from the folder identified by
// chat_folder_id.  The chat itself is not deleted or left; it is only removed
// from the folder's explicit include list.
//
// This is implemented by reading the current folder configuration with
// getChatFolder, removing the chat from the included_chat_ids list and adding
// it to excluded_chat_ids, then calling editChatFolder with the updated config.
fn remove_chat_from_folder(s Session, mut td TDLib, chat_id i64, chat_folder_id int) !json2.Any {
	// Fetch current folder configuration.
	get_req := new_request('getChatFolder').with_int('chat_folder_id', chat_folder_id).build()!
	get_resp := s.send_sync(mut td, get_req)!
	folder_raw := get_resp.as_map()

	// Rebuild included list without chat_id.
	old_included := map_arr(folder_raw, 'included_chat_ids')
	mut new_included := []json2.Any{cap: old_included.len}
	for v in old_included {
		if any_to_i64(v) != chat_id {
			new_included << v
		}
	}

	// Rebuild pinned list without chat_id.
	old_pinned := map_arr(folder_raw, 'pinned_chat_ids')
	mut new_pinned := []json2.Any{cap: old_pinned.len}
	for v in old_pinned {
		if any_to_i64(v) != chat_id {
			new_pinned << v
		}
	}

	// Add chat_id to the excluded list so it does not reappear via a filter rule.
	old_excluded := map_arr(folder_raw, 'excluded_chat_ids')
	mut new_excluded := []json2.Any{cap: old_excluded.len + 1}
	for v in old_excluded {
		new_excluded << v
	}
	// Only add to excluded if not already there.
	mut already_excluded := false
	for v in old_excluded {
		if any_to_i64(v) == chat_id {
			already_excluded = true
			break
		}
	}
	if !already_excluded {
		new_excluded << json2.Any(chat_id)
	}

	// Clone the folder map and patch the three lists.
	mut updated := folder_raw.clone()
	updated['included_chat_ids'] = json2.Any(new_included)
	updated['pinned_chat_ids'] = json2.Any(new_pinned)
	updated['excluded_chat_ids'] = json2.Any(new_excluded)

	edit_req := new_request('editChatFolder').with_int('chat_folder_id', chat_folder_id).with_obj('folder',
		updated).build()!
	return s.send_sync(mut td, edit_req)
}

// --- Folder invite links ---

// join_chat_folder_by_link accepts a folder invite link and subscribes the
// account to all chats referenced by that link.
// invite_link: the t.me/addlist/... URL shared by another user.
//
// TDLib method: addChatFolderByInviteLink invite_link:String
//   chat_ids:vector<Int53>
// chat_ids may be empty to join all chats in the folder link, or a subset to
// join only specific chats.  Pass an empty slice to join all.
fn join_chat_folder_by_link(s Session, mut td TDLib, invite_link string, chat_ids []i64) !json2.Any {
	mut ids := []json2.Any{cap: chat_ids.len}
	for id in chat_ids {
		ids << json2.Any(id)
	}
	req :=
		new_request('addChatFolderByInviteLink').with_str('invite_link', invite_link).with_arr('chat_ids', ids).build()!
	return s.send_sync(mut td, req)
}

// check_chat_folder_invite_link returns information about a folder invite link
// before the user decides to join it.  The returned raw json2.Any map contains
// the fields defined by TDLib's chatFolderInviteLinkInfo type:
//
//   chat_folder_info:chatFolderInfo   - summary of the folder being shared
//   missing_chat_ids:vector<Int53>    - chats not yet in the account's folder list
//   added_chat_ids:vector<Int53>      - chats already present
//
// TDLib method: checkChatFolderInviteLink invite_link:String
fn check_chat_folder_invite_link(s Session, mut td TDLib, invite_link string) !json2.Any {
	req := new_request('checkChatFolderInviteLink').with_str('invite_link', invite_link).build()!
	return s.send_sync(mut td, req)
}

// create_chat_folder_invite_link creates a shareable invite link for a folder.
// chat_folder_id: the ID of the folder to share.
// name:           a label for the link (can be '').
// chat_ids:       subset of the folder's chats to include in the link.
//                 Pass an empty slice to include all shareable chats.
// Returns the URL of the newly created invite link.
//
// TDLib method: createChatFolderInviteLink chat_folder_id:Int32 name:String
//   chat_ids:vector<Int53> -> chatFolderInviteLink{ invite_link:String ... }
fn create_chat_folder_invite_link(s Session, mut td TDLib, chat_folder_id int, name string, chat_ids []i64) !string {
	mut ids := []json2.Any{cap: chat_ids.len}
	for id in chat_ids {
		ids << json2.Any(id)
	}
	req :=
		new_request('createChatFolderInviteLink').with_int('chat_folder_id', chat_folder_id).with_str('name', name).with_arr('chat_ids', ids).build()!
	resp := s.send_sync(mut td, req)!
	return map_str(resp.as_map(), 'invite_link')
}

// --- schedule.v ---

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
		content).with('options', scheduled_send_options(send_date, opts.silent,
		opts.protect_content))
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
	return dispatch_send_scheduled(s, mut td, chat_id, content, send_date, opts,
		json2.Any(map[string]json2.Any{}))
}

// send_scheduled_html schedules an HTML-formatted message for delivery at send_date.
fn send_scheduled_html(s Session, mut td TDLib, chat_id i64, html string, send_date i64, opts SendOptions) !json2.Any {
	formatted := html_text(html)!
	content := typed_obj('inputMessageText', {
		'text': formatted
	})
	return dispatch_send_scheduled(s, mut td, chat_id, content, send_date, opts,
		json2.Any(map[string]json2.Any{}))
}

// send_scheduled_markdown schedules a MarkdownV2-formatted message for delivery at send_date.
fn send_scheduled_markdown(s Session, mut td TDLib, chat_id i64, md string, send_date i64, opts SendOptions) !json2.Any {
	formatted := markdown_text(md)!
	content := typed_obj('inputMessageText', {
		'text': formatted
	})
	return dispatch_send_scheduled(s, mut td, chat_id, content, send_date, opts,
		json2.Any(map[string]json2.Any{}))
}

// send_scheduled_photo schedules a photo message for delivery at send_date.
fn send_scheduled_photo(s Session, mut td TDLib, chat_id i64, input_file json2.Any, caption string, send_date i64, opts SendOptions) !json2.Any {
	content := obj({
		'@type':   json2.Any('inputMessagePhoto')
		'photo':   input_file
		'caption': plain_text(caption)
	})
	return dispatch_send_scheduled(s, mut td, chat_id, content, send_date, opts,
		json2.Any(map[string]json2.Any{}))
}

// send_scheduled_document schedules a document message for delivery at send_date.
fn send_scheduled_document(s Session, mut td TDLib, chat_id i64, input_file json2.Any, caption string, send_date i64, opts SendOptions) !json2.Any {
	content := obj({
		'@type':    json2.Any('inputMessageDocument')
		'document': input_file
		'caption':  plain_text(caption)
	})
	return dispatch_send_scheduled(s, mut td, chat_id, content, send_date, opts,
		json2.Any(map[string]json2.Any{}))
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
	req := new_request('sendScheduledMessages').with_i64('chat_id', chat_id).with('message_ids', arr_of_i64([
		message_id,
	])).build()!
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
	req := new_request('deleteScheduledMessages').with_i64('chat_id', chat_id).with('message_ids',
		arr_of_i64(message_ids)).build()!
	return s.send_sync(mut td, req)
}

// --- topics.v ---

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
	req :=
		new_request('createForumTopic').with_i64('chat_id', chat_id).with_str('name', name).with_obj('icon', icon).build()!
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
	req := new_request('getForumTopics').with_i64('chat_id', chat_id).with_str('query', query).with_i64('offset_date',
		offset_date).with_i64('offset_message_id', offset_message_id).with_i64('offset_message_thread_id',
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
		message_thread_id).with_i64('from_message_id', from_message_id).with_int('offset', 0).with_int('limit',
		limit).build()!
	resp := s.send_sync(mut td, req)!
	raw_arr := map_arr(resp.as_map(), 'messages')
	mut out := []Message{cap: raw_arr.len}
	for rm in raw_arr {
		out << Message.from(rm.as_map())
	}
	return out
}

// --- translate.v ---

// TranslatedText wraps the TDLib formattedText result returned by translation
// methods.  Both text() and entities() are available for rich formatting.
pub struct TranslatedText {
pub:
	raw map[string]json2.Any
}

pub fn TranslatedText.from(m map[string]json2.Any) TranslatedText {
	return TranslatedText{
		raw: m
	}
}

// text returns the plain translated text.
pub fn (t TranslatedText) text() string {
	return map_str(t.raw, 'text')
}

// has_entities returns true when the translation result contains formatting
// entities (bold, italic, links, etc.).
pub fn (t TranslatedText) has_entities() bool {
	return map_arr(t.raw, 'entities').len > 0
}

// entities_raw returns the raw JSON array of textEntity objects.
// Each element has type:TextEntityType and offset/length fields.
pub fn (t TranslatedText) entities_raw() []json2.Any {
	return map_arr(t.raw, 'entities')
}

// --- Implementation ---

// translate_text translates a plain string to the given target language.
// to_language_code: IETF BCP 47 code of the target language (e.g. 'en', 'fr').
// Returns the translated text as a TranslatedText.
//
// TDLib calls this with a formattedText containing the source string.
// Language detection is automatic; no source language is required.
fn translate_text(s Session, mut td TDLib, text string, to_language_code string) !TranslatedText {
	req := new_request('translateText').with('text', plain_text(text)).with_str('to_language_code',
		to_language_code).build()!
	resp := s.send_sync(mut td, req)!
	return TranslatedText.from(resp.as_map())
}

// translate_message translates the text content of an existing message.
// chat_id and message_id identify the message; to_language_code is the
// target language in IETF BCP 47 format.
//
// TDLib schema: translateMessageText chat_id:int53 message_id:int53
//   to_language_code:string
fn translate_message(s Session, mut td TDLib, chat_id i64, message_id i64, to_language_code string) !TranslatedText {
	req := new_request('translateMessageText').with_i64('chat_id', chat_id).with_i64('message_id',
		message_id).with_str('to_language_code', to_language_code).build()!
	resp := s.send_sync(mut td, req)!
	return TranslatedText.from(resp.as_map())
}

// --- account.v ---

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
	return send_venue(u.session, mut *u.td, chat_id, latitude, longitude, title, address, provider,
		provider_id, opts)
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
	return add_message_reaction(u.session, mut *u.td, chat_id, message_id, emoji, is_big, true)
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
	return forward_message_with_markup(u.session, mut *u.td, to_chat_id, from_chat_id, message_id)
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
	return edit_inline_message_text(u.session, mut *u.td, inline_message_id, formatted, markup)
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
	return edit_inline_message_text(u.session, mut *u.td, inline_message_id, formatted, markup)
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
// The previous implementation used '@type': 'inputChatPhotoLocal', which
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
	return get_supergroup_members(u.session, mut *u.td, supergroup_id, filter, offset, limit)
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
	return search_messages_in_chat(u.session, mut *u.td, chat_id, query, from_message_id, limit)
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
	return create_chat_folder_invite_link(u.session, mut *u.td, chat_folder_id, name, chat_ids)
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
	return send_scheduled_photo(u.session, mut *u.td, chat_id, input_file, caption, send_date, opts)
}

// send_scheduled_document schedules a document message for delivery at send_date.
pub fn (mut u UserAccount) send_scheduled_document(chat_id i64, input_file json2.Any, caption string, send_date i64, opts SendOptions) !json2.Any {
	return send_scheduled_document(u.session, mut *u.td, chat_id, input_file, caption, send_date,
		opts)
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
	return edit_forum_topic(u.session, mut *u.td, chat_id, message_thread_id, name,
		icon_custom_emoji_id)
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
	return get_forum_topic_history(u.session, mut *u.td, chat_id, message_thread_id,
		from_message_id, limit)
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

// =============================================================================
// SECTION 4: Bot Account
// Bot-only API (commands, profile, inline/callback queries, menu buttons),
// inline query result constructors, and the BotAccount struct with all its
// public methods.
// =============================================================================

// --- botapi.v ---

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
	// The previous implementation omitted the required scope and language_code
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
	// The previous implementation called 'getMyCommands', which does not exist
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
// The previous implementation called 'setName', which is the method for
// changing a user account's first/last name and accepts first_name + last_name.
// The correct method for bots is 'setBotName', which requires:
//   bot_user_id: pass 0 to edit the current bot's own name.
//   name:        the new display name string.
//   language_code: '' to set the default name for all languages.
fn bot_set_name(s Session, mut td TDLib, name string) !json2.Any {
	req :=
		new_request('setBotName').with_i64('bot_user_id', 0).with_str('name', name).with_str('language_code', '').build()!
	return s.send_sync(mut td, req)
}

// bot_set_description sets the bot's description (shown to users who have
// never started a chat with it).
//
// The previous implementation omitted the required bot_user_id and
// language_code parameters. TDLib requires both even if they are zero/empty.
//   bot_user_id:   0 to edit the current bot's description.
//   language_code: '' to set the default description for all languages.
fn bot_set_description(s Session, mut td TDLib, description string) !json2.Any {
	req := new_request('setBotInfoDescription').with_i64('bot_user_id', 0).with_str('language_code', '').with_str('description',
		description).build()!
	return s.send_sync(mut td, req)
}

// bot_set_short_description sets the bot's short description (shown on the
// profile page and in share dialogs).
//
// Same as bot_set_description - bot_user_id and language_code were
// missing from the previous implementation.
fn bot_set_short_description(s Session, mut td TDLib, short_description string) !json2.Any {
	req := new_request('setBotInfoShortDescription').with_i64('bot_user_id', 0).with_str('language_code', '').with_str('short_description',
		short_description).build()!
	return s.send_sync(mut td, req)
}

// bot_set_profile_photo uploads a new profile photo for the bot from a local file.
//
// The previous implementation used '@type': 'inputChatPhotoLocal', which
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
// The previous implementation declared inline_query_id as string and used
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
	req := new_request('answerCallbackQuery').with_i64('callback_query_id', callback_query_id).with_str('text', text).with_bool('show_alert',
		show_alert).with_str('url', url).with_int('cache_time', cache_time).build()!
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
	req :=
		new_request('getBotInfo').with_i64('bot_user_id', 0).with_str('language_code', '').build()!
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
	req := new_request('setBotMenuButton').with_i64('user_id', user_id).with_obj('menu_button', {
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
	req := new_request('setBotMenuButton').with_i64('user_id', user_id).with_obj('menu_button', {
		'@type': json2.Any('botMenuButtonDefault')
	}).build()!
	return s.send_sync(mut td, req)
}

// --- inline.v ---

// inline_result_article builds an inputInlineQueryResultArticle.
// This is the most common result type: shows a title + description in the picker
// and sends a text message when selected.
//
//   bot.answer_inline_query(query_id, [
//       tdlib.inline_result_article('id1', 'Hello', 'Sends a greeting',
//           tdlib.typed_obj('inputMessageText', {'text': tdlib.plain_text('Hello!')}),
//           json2.Any(map[string]json2.Any{})),
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
	return inline_result_photo(id, title, description, photo_url, thumb_url, 0, 0,
		json2.Any(map[string]json2.Any{}), json2.Any(map[string]json2.Any{}))
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
// The previous version used 'gif_url' which is the Bot API field name.
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
	return inline_result_gif(id, title, animation_url, thumbnail_url, thumbnail_mime_type, 0, 0, 0,
		json2.Any(map[string]json2.Any{}), json2.Any(map[string]json2.Any{}))
}

// --- botaccount.v ---

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
	return send_venue(b.session, mut *b.td, chat_id, latitude, longitude, title, address, provider,
		provider_id, opts)
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
	return add_message_reaction(b.session, mut *b.td, chat_id, message_id, emoji, is_big, true)
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
	return forward_message_with_markup(b.session, mut *b.td, to_chat_id, from_chat_id, message_id)
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
	return edit_inline_message_text(b.session, mut *b.td, inline_message_id, formatted, markup)
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
	return edit_inline_message_text(b.session, mut *b.td, inline_message_id, formatted, markup)
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
	return get_supergroup_members(b.session, mut *b.td, supergroup_id, filter, offset, limit)
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
	return search_messages_in_chat(b.session, mut *b.td, chat_id, query, from_message_id, limit)
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

// --- Scheduled messages ---

// send_scheduled_text schedules a plain-text message for delivery at send_date (Unix timestamp).
pub fn (mut b BotAccount) send_scheduled_text(chat_id i64, text string, send_date i64, opts SendOptions) !json2.Any {
	return send_scheduled_text(b.session, mut *b.td, chat_id, text, send_date, opts)
}

// send_scheduled_html schedules an HTML-formatted message for delivery at send_date.
pub fn (mut b BotAccount) send_scheduled_html(chat_id i64, html string, send_date i64, opts SendOptions) !json2.Any {
	return send_scheduled_html(b.session, mut *b.td, chat_id, html, send_date, opts)
}

// send_scheduled_markdown schedules a MarkdownV2-formatted message for delivery at send_date.
pub fn (mut b BotAccount) send_scheduled_markdown(chat_id i64, md string, send_date i64, opts SendOptions) !json2.Any {
	return send_scheduled_markdown(b.session, mut *b.td, chat_id, md, send_date, opts)
}

// send_scheduled_photo schedules a photo message for delivery at send_date.
pub fn (mut b BotAccount) send_scheduled_photo(chat_id i64, input_file json2.Any, caption string, send_date i64, opts SendOptions) !json2.Any {
	return send_scheduled_photo(b.session, mut *b.td, chat_id, input_file, caption, send_date, opts)
}

// send_scheduled_document schedules a document message for delivery at send_date.
pub fn (mut b BotAccount) send_scheduled_document(chat_id i64, input_file json2.Any, caption string, send_date i64, opts SendOptions) !json2.Any {
	return send_scheduled_document(b.session, mut *b.td, chat_id, input_file, caption, send_date,
		opts)
}

// get_scheduled_messages returns all pending scheduled messages in a chat.
pub fn (mut b BotAccount) get_scheduled_messages(chat_id i64) ![]Message {
	return get_scheduled_messages(b.session, mut *b.td, chat_id)
}

// send_scheduled_message_now delivers a scheduled message immediately.
pub fn (mut b BotAccount) send_scheduled_message_now(chat_id i64, message_id i64) !json2.Any {
	return send_scheduled_message_now(b.session, mut *b.td, chat_id, message_id)
}

// send_all_scheduled_now delivers all pending scheduled messages in a chat immediately.
pub fn (mut b BotAccount) send_all_scheduled_now(chat_id i64) ! {
	send_all_scheduled_now(b.session, mut *b.td, chat_id)!
}

// delete_scheduled_messages cancels scheduled messages without sending them.
pub fn (mut b BotAccount) delete_scheduled_messages(chat_id i64, message_ids []i64) !json2.Any {
	return delete_scheduled_messages(b.session, mut *b.td, chat_id, message_ids)
}

// --- Forum topics ---

// create_forum_topic creates a new topic in a forum supergroup.
// Returns ForumTopicInfo; use .message_thread_id() to send messages to the topic.
pub fn (mut b BotAccount) create_forum_topic(chat_id i64, name string, icon_color int, icon_custom_emoji_id string) !ForumTopicInfo {
	return create_forum_topic(b.session, mut *b.td, chat_id, name, icon_color, icon_custom_emoji_id)
}

// edit_forum_topic changes the name and/or icon of an existing topic.
pub fn (mut b BotAccount) edit_forum_topic(chat_id i64, message_thread_id i64, name string, icon_custom_emoji_id string) !json2.Any {
	return edit_forum_topic(b.session, mut *b.td, chat_id, message_thread_id, name,
		icon_custom_emoji_id)
}

// close_forum_topic archives a topic so no new messages can be posted.
pub fn (mut b BotAccount) close_forum_topic(chat_id i64, message_thread_id i64) !json2.Any {
	return close_forum_topic(b.session, mut *b.td, chat_id, message_thread_id)
}

// reopen_forum_topic re-opens a previously closed topic.
pub fn (mut b BotAccount) reopen_forum_topic(chat_id i64, message_thread_id i64) !json2.Any {
	return reopen_forum_topic(b.session, mut *b.td, chat_id, message_thread_id)
}

// delete_forum_topic permanently deletes a topic and all of its messages.
pub fn (mut b BotAccount) delete_forum_topic(chat_id i64, message_thread_id i64) !json2.Any {
	return delete_forum_topic(b.session, mut *b.td, chat_id, message_thread_id)
}

// pin_forum_topic pins or unpins a topic in the forum list.
pub fn (mut b BotAccount) pin_forum_topic(chat_id i64, message_thread_id i64, is_pinned bool) !json2.Any {
	return pin_forum_topic(b.session, mut *b.td, chat_id, message_thread_id, is_pinned)
}

// get_forum_topics returns a paginated list of topics in a forum supergroup.
// Pass all offset arguments as 0 for the first page.
pub fn (mut b BotAccount) get_forum_topics(chat_id i64, query string, offset_date i64, offset_message_id i64, offset_message_thread_id i64, limit int) ![]ForumTopic {
	return get_forum_topics(b.session, mut *b.td, chat_id, query, offset_date, offset_message_id,
		offset_message_thread_id, limit)
}

// get_forum_topic returns the details of a single topic by its thread ID.
pub fn (mut b BotAccount) get_forum_topic(chat_id i64, message_thread_id i64) !ForumTopic {
	return get_forum_topic(b.session, mut *b.td, chat_id, message_thread_id)
}

// get_forum_topic_history returns messages from a specific forum topic.
// from_message_id: 0 to start from the most recent message.
pub fn (mut b BotAccount) get_forum_topic_history(chat_id i64, message_thread_id i64, from_message_id i64, limit int) ![]Message {
	return get_forum_topic_history(b.session, mut *b.td, chat_id, message_thread_id,
		from_message_id, limit)
}

// --- Translation ---

// translate_text translates a plain string to the target language.
// to_language_code: IETF BCP 47 code (e.g. 'en', 'fr', 'de', 'ja').
pub fn (mut b BotAccount) translate_text(text string, to_language_code string) !TranslatedText {
	return translate_text(b.session, mut *b.td, text, to_language_code)
}

// translate_message translates the text of an existing message to the target language.
pub fn (mut b BotAccount) translate_message(chat_id i64, message_id i64, to_language_code string) !TranslatedText {
	return translate_message(b.session, mut *b.td, chat_id, message_id, to_language_code)
}

// =============================================================================
// SECTION 5: Account Manager
// Manages multiple UserAccounts and BotAccounts over a single shared TDLib hub.
// =============================================================================

// --- manager.v ---

// AccountManager owns a shared TDLib hub and any number of accounts.
pub struct AccountManager {
pub mut:
	td    &TDLib
	users map[string]&UserAccount
	bots  map[string]&BotAccount
}

// AccountManager.new creates a manager with a fresh shared TDLib hub.
pub fn AccountManager.new() &AccountManager {
	return &AccountManager{
		td:    new()
		users: map[string]&UserAccount{}
		bots:  map[string]&BotAccount{}
	}
}

// add_user creates a new UserAccount under the shared hub and registers it by name.
// Returns the UserAccount so you can chain setup/login calls.
pub fn (mut mgr AccountManager) add_user(name string) &UserAccount {
	acc := UserAccount.new_shared(mut *mgr.td)
	mgr.users[name] = acc
	return acc
}

// add_bot creates a new BotAccount under the shared hub and registers it by name.
// Returns the BotAccount so you can chain setup/login calls.
pub fn (mut mgr AccountManager) add_bot(name string) &BotAccount {
	bot := BotAccount.new_shared(mut *mgr.td)
	mgr.bots[name] = bot
	return bot
}

// user returns a registered UserAccount by name, or an error if not found.
pub fn (mgr &AccountManager) user(name string) !&UserAccount {
	return mgr.users[name] or { error('UserAccount "${name}" not registered') }
}

// bot returns a registered BotAccount by name, or an error if not found.
pub fn (mgr &AccountManager) bot(name string) !&BotAccount {
	return mgr.bots[name] or { error('BotAccount "${name}" not registered') }
}

// user_names returns all registered UserAccount names.
pub fn (mgr &AccountManager) user_names() []string {
	return mgr.users.keys()
}

// bot_names returns all registered BotAccount names.
pub fn (mgr &AccountManager) bot_names() []string {
	return mgr.bots.keys()
}

// shutdown stops the shared TDLib hub and all associated sessions.
pub fn (mut mgr AccountManager) shutdown() {
	mgr.td.shutdown()
}
