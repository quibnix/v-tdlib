// tdlib/manager.v
// AccountManager: manages multiple UserAccounts and BotAccounts over a
// single shared TDLib hub (one receiver goroutine, many sessions).
//
// --- Example ---
//
//   mut mgr := tdlib.AccountManager.new()
//   defer { mgr.shutdown() }
//
//   alice := mgr.add_user('alice')
//   alice.setup(api_id, api_hash, './db_alice')!
//   alice.login('+1234567890')!
//
//   scanner := mgr.add_bot('scanner')
//   scanner.setup(api_id, api_hash, './db_scanner')!
//   scanner.login(bot_token)!
//
//   scanner.on('updateNewMessage', fn [mut scanner] (upd json2.Any) {
//       msg := tdlib.Message.from(tdlib.map_obj(upd.as_map(), 'message'))
//       scanner.send_text(msg.chat_id(), 'Hello!') or {}
//   })
//
//   for { _ := scanner.get_update() }
//
// --- Update isolation ---
//
// Each account registered under an AccountManager has its own handler map and
// update channel, routed by the TDLib @client_id field.  Handlers registered
// on alice never fire for scanner's updates and vice versa.
module tdlib

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
