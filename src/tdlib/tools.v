// tdlib/tools.v
// Utility functions that are not directly related to TDLib but are useful
// to have alongside a bot or userbot:
//   - Human-readable formatting  (fmt_bytes, fmt_bytes_precise, fmt_duration, fmt_count)
//   - Relative time              (relative_time, plural)
//   - String escaping            (escape_html, escape_markdown)
//   - Text helpers               (truncate, smart_truncate, word_wrap, chunks, chunks_runes, strip_html)
//   - Telegram text helpers      (normalize_mention, extract_mentions, extract_hashtags)
//   - Validation                 (is_valid_username, is_valid_command)
//   - Fuzzy matching             (levenshtein, closest_command)
//   - Rate limiting              (RateLimiter)
//   - Bot command parsing        (parse_command, CommandArgs)
//   - Time helpers               (unix_now, unix_to_date)
//   - Misc                       (clamp, contains_any)
module tdlib

import time
import sync

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
	return if d == 1 { '1 day ago' } else { '${d} days ago' }
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
