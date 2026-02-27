// examples/02_commands_and_keyboards.v
//
// A bot that responds to slash commands and uses inline keyboards.
// This example covers:
//
//   - Parsing commands with parse_command()
//   - Sending HTML-formatted replies
//   - Attaching an inline keyboard to a message
//   - Handling callback queries from button presses
//   - Answering callback queries to dismiss the loading indicator
//   - Fuzzy command suggestions via closest_command()
//
// Supported commands:
//   /start     - welcome message
//   /help      - list commands
//   /ping      - reply "Pong!"
//   /vote      - send a Yes / No inline keyboard
import tdlib
import x.json2
import encoding.base64

const api_id = 
const api_hash = ''
const bot_token = ''

const data_dir = './database'

// The commands this bot understands, used for fuzzy-match suggestions.
const known_commands = ['start', 'help', 'ping', 'vote']

fn main() {
	tdlib.set_log_verbosity(1)!

	mut bot := tdlib.BotAccount.new()!
	defer { bot.shutdown() }

	bot.setup(api_id, api_hash, data_dir)!
	bot.login(bot_token)!

	me := bot.get_me()!
	println('Logged in as @${me.username()}')

	// --- Message handler -----------------------------------------
	bot.on('updateNewMessage', fn [mut bot] (upd json2.Any) {
		msg := tdlib.Message.from(tdlib.map_obj(upd.as_map(), 'message'))
		if msg.is_outgoing() {
			return
		}

		text := msg.content().text()
		if text == '' {
			return
		}

		// parse_command() returns none for non-command messages.
		cmd := tdlib.parse_command(text) or { return }

		chat_id := msg.chat_id()

		match cmd.command {
			'start' {
				bot.send_html(chat_id, '<b>Welcome!</b> Send /help to see what I can do.') or {}
			}
			'help' {
				bot.send_html(chat_id, '<b>Commands:</b>\n' + '/ping  — latency check\n' +
					'/vote  — cast a yes/no vote\n' + '/help  — this message') or {}
			}
			'ping' {
				bot.reply_text(chat_id, msg.id(), 'Pong! 🏓') or {}
			}
			'vote' {
				// Build a 1*2 inline keyboard.
				// callback_data is any string you want; you receive it back in
				// updateNewCallbackQuery.  Keep it short (<= 64 bytes recommended).
				markup := tdlib.inline_keyboard_markup([
					[
						tdlib.InlineButton{
                                                        text: '👍 Yes',
                                                        callback_data: 'vote:yes'
                                                },

						tdlib.InlineButton{
							text:          '👎 No'
							callback_data: 'vote:no'
						},
					],
				])
				bot.send_text_keyboard(chat_id, 'Cast your vote:', markup, tdlib.SendOptions{}) or {}
			}
			else {
				// Unknown command — suggest the closest known one.
				suggestion := tdlib.closest_command(cmd.command, known_commands, 2) or { '' }
				mut reply := 'Unknown command /${cmd.command}.'
				if suggestion != '' {
					reply += ' Did you mean /${suggestion}?'
				}
				bot.send_text(chat_id, reply) or {}
			}
		}
	})

	// --- Callback query handler ---------------------------------------
	// Fired when a user presses a button on an inline keyboard.
	bot.on('updateNewCallbackQuery', fn [mut bot] (upd json2.Any) {
		m := upd.as_map()

		// The query ID must be answered to dismiss Telegram's loading spinner.
		query_id := tdlib.map_i64(m, 'id')
		chat_id := tdlib.map_i64(m, 'chat_id')
		msg_id := tdlib.map_i64(m, 'message_id')

		// callback_data was base64-encoded by the library when the button was
		// created; we need to decode it back to the original string here.
		payload_m := tdlib.map_obj(m, 'payload')
		data := base64.decode_str(tdlib.map_str(payload_m, 'data'))

		match data {
			'vote:yes' {
				// show_alert: false -> small toast notification (not a dialog).
				bot.answer_callback_query(query_id, 'You voted Yes! 👍', false, '', 0) or {}
			}
			'vote:no' {
				bot.answer_callback_query(query_id, 'You voted No! 👎', false, '', 0) or {}
			}
			else {
				// Always answer, even for unrecognised data, to clear the spinner.
				bot.answer_callback_query(query_id, '', false, '', 0) or {}
			}
		}

		// Edit the original message to remove the keyboard after voting.
		markup := tdlib.inline_keyboard_markup([])
		bot.edit_reply_markup(chat_id, msg_id, markup) or {}
	})

	println('Commands bot is running. Press Ctrl+C to stop.')
	for {
		_ := bot.get_update()
	}
}
