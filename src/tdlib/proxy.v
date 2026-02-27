// tdlib/proxy.v
// Full proxy management: add, list, remove, enable/disable, ping, and sort.
//
// Supported proxy types:
//   SOCKS5  - add_socks5_proxy()   (in common.v)
//   HTTP    - add_http_proxy()     (in common.v)
//   MTProto - add_mtproto_proxy()  (this file, most common for Telegram)
//
// --- Typical workflow ---
//
//   p := bot.add_mtproto_proxy('proxy.example.com', 443, 'ee0000...')!
//   println('Added proxy id=${p.id()}')
//
//   // List and ping all configured proxies, sorted fastest first.
//   sorted := bot.get_proxies_sorted_by_ping()!
//   for r in sorted {
//       println('${r.proxy.server()}:${r.proxy.port()}  ping=${r.ping_ms:.1f}ms')
//   }
//
//   // Switch to a specific proxy.
//   bot.enable_proxy(sorted[0].proxy.id())!
//
//   // Disable proxy usage entirely.
//   bot.disable_proxy()!
//
//   // Clean up a proxy that is no longer needed.
//   bot.remove_proxy(p.id())!
module tdlib

import x.json2

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
	req := new_request('addProxy').with_str('server', server).with_int('port', port).with_bool('enable',
		true).with_obj('type', {
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
