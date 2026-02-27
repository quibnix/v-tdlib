// examples/01_echo_bot.v
//
// The simplest possible bot: echoes every message it receives back to the
// sender.  This example covers the essential lifecycle:
//
//   1. Create a BotAccount
//   2. Call setup() with your API credentials
//   3. Call login() with your bot token
//   4. Register an 'updateNewMessage' handler
//   5. Block forever pumping unhandled updates
//
// Run:
//   v run 01_echo_bot.v
//
// Prerequisites:
//   - TDLib shared library in your linker path
//   - API_ID and API_HASH from https://my.telegram.org
//   - A bot token from @BotFather
import tdlib
import x.json2

const api_id = 
const api_hash = ''

const bot_token = ''

const data_dir = './database'

fn main() {
	// Reduce TDLib's log noise during development.
	// 0 = fatal only, 1 = errors, 2 = warnings, 3 = info (default), 4 = debug.
	tdlib.set_log_verbosity(1)!

	// Create a standalone bot account with its own TDLib hub.
	mut bot := tdlib.BotAccount.new()!
	defer { bot.shutdown() }

	// setup() sends setTdlibParameters to TDLib.  The data_dir stores the
	// session database so you don't need to authenticate on every restart.
	bot.setup(api_id, api_hash, data_dir)!

	// login() exchanges the bot token for an authorised session.
	// If a valid session already exists in data_dir, this returns immediately.
	bot.login(bot_token)!

	me := bot.get_me()!
	println('Logged in as @${me.username()} (${me.full_name()})')

	// Register a handler for incoming messages.
	// The closure captures `mut bot` so it can call API methods.
	// Handlers run in a new goroutine per update, so they are safe to block.
	bot.on('updateNewMessage', fn [mut bot] (upd json2.Any) {
		// Extract the Message from the update payload.
		msg := tdlib.Message.from(tdlib.map_obj(upd.as_map(), 'message'))

		// Ignore messages sent by the bot itself.
		if msg.is_outgoing() {
			return
		}

		// Only echo plain text messages.
		text := msg.content().text()
		if text == '' {
			return
		}

		// Reply to the message quoting the original.
		reply := 'You said:\n${text}'
		bot.send_text(msg.chat_id(), reply) or {
			eprintln('send_text error: ${err}')
		}
	})

	println('Echo bot is running. Press Ctrl+C to stop.')

	// Pump updates that have no registered handler (e.g. updateConnectionState).
	// This loop keeps main() alive; registered handlers run in background goroutines.
	for {
		_ := bot.get_update()
	}
}
