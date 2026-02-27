// tdlib/tdlib.v
// Central hub: C interop, session management, update routing.
//
// --- Architecture ---
//
//  TDLib (hub)          - one shared receiver goroutine
//  +-- Session          - thin int wrapper (one TDLib client_id per account)
//  +-- UserAccount      - user authenticated with a phone number
//  +-- BotAccount       - bot authenticated with a bot token
//
// Each account owns exactly one Session and registers its handlers with the
// hub using its session ID.  The receiver goroutine reads "@client_id" from
// every TDLib event to route it to the correct account's handlers.
//
// --- Handler safety ---
//
// Every registered handler is called in its own goroutine so handlers can
// safely call any synchronous API method without deadlocking the receiver.
//
// --- Response tracking ---
//
// send_sync() tags each request with a UUID in @extra.  The receiver matches
// incoming responses by @extra and delivers them through a one-shot channel.
// This lets many goroutines issue concurrent requests safely.
module tdlib

import x.json2
import rand
import sync

// --- C interop ---

#flag -ltdjson
#include <td/telegram/td_json_client.h>

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
