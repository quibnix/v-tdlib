// examples/03_userbot_basics.v
//
// A user account (userbot) that logs in with a phone number and demonstrates
// the features only available to regular user sessions:
//
//   - Phone-number authentication flow
//   - Listing recent chats
//   - Fetching chat history
//   - Sending messages with formatting options
//   - Reading extended user / supergroup info
//   - Reacting to incoming messages
//
// Unlike bots, user accounts can access any chat they are a member of,
// read full history, and use the complete Telegram client API.
//
// WARNING: Automating a real user account may violate Telegram's Terms of
// Service. Use a dedicated test account for development and experimentation.
import tdlib

const api_id = 
const api_hash = ''
const bot_token = ''
const data_dir = './database'

fn main() {
	tdlib.set_log_verbosity(1)!

	// Create a standalone user account.
	mut user := tdlib.UserAccount.new()!
	defer { user.shutdown() }

	user.setup(api_id, api_hash, data_dir)!

	// Pass none to be prompted on stdin, or a phone number to skip the prompt.
	// The library will also prompt for the OTP and 2FA password (if set) on stdin.
        user.login(none)!

	me := user.get_me()!
	println('Logged in as ${me.full_name()} (@${me.username()})')

	// --- List the 10 most-recently-active chats -----------------------------
	println('\n---Recent chats ---')
	chat_ids := user.get_chats(10)!
	for chat_id in chat_ids {
		chat := user.get_chat(chat_id)!
		kind := if chat.is_private()     { 'DM'      }
		        else if chat.is_group()  { 'Group'   }
		        else if chat.is_channel(){ 'Channel' }
		        else                     { 'Super'   }
		unread := chat.unread_count()
		suffix := if unread > 0 { '  [${unread} unread]' } else { '' }
		println('  [${kind}] ${chat.title()}${suffix}')
	}

	// --- Fetch the last 5 messages from the first chat ----------------------
	if chat_ids.len > 0 {
		target_id := chat_ids[0]
		chat := user.get_chat(target_id)!
		println('\n--- Last 5 messages in "${chat.title()}" ---')

		// from_message_id = 0 means "start from the newest message".
		messages := user.get_chat_history(target_id, 0, 5)!
		for msg in messages {
			sender := if msg.sender_user_id() != 0 {
				u := user.get_user(msg.sender_user_id()) or { tdlib.User{} }
				u.full_name()
			} else {
				'[channel]'
			}
			text := msg.content().text()
			cap  := msg.content().caption()
			body := if text != '' { text } else if cap != '' { '[media] ${cap}' } else { '[${msg.content().content_type()}]' }
			println('  ${sender}: ${tdlib.truncate(body, 60, "...")}')
		}

		// --- Send a silent test message --------------------------------------
		// SendOptions lets you reply, suppress notifications, or protect content.
       //         me := user.get_me() or {}
		user.send_text_opts(me.id(), 'Hello from the userbot example!',
			tdlib.SendOptions{ silent: true })!
		println('\nSent a silent message to "Saved Messages".')
	}

	// --- Extended supergroup info -------------------------------------------------
	// get_supergroup_full_info() requires the bare supergroup_id, not the chat_id.
	for chat_id in chat_ids {
		chat := user.get_chat(chat_id)!
		if chat.is_supergroup() || chat.is_channel() {
			info := user.get_supergroup_full_info(chat.supergroup_id())!
			println('\n── Supergroup info: ${chat.title()} ──')
			println('  Description : ${info.description()}')
			println('  Members     : ${info.member_count()}')
			println('  Invite link : ${info.invite_link_url()}')
			break
		}
	}

	println('\nPress Ctrl+C to stop.')
	for { _ := user.get_update() }
}
