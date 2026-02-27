// tdlib/folders.v
// Chat folder (filter) management for user accounts.
//
// TDLib exposes chat folders via the chatFolder / chatFolderInfo family of types
// and a corresponding set of methods.  Use these helpers instead of calling the
// raw TDLib API directly.
//
// Typical workflow:
//
//   // List all folders and their IDs:
//   folders := user.get_chat_folders()!
//   for f in folders {
//       println('${f.id()} ${f.name()}')
//   }
//
//   // Create a new folder that shows only channels:
//   id := user.create_chat_folder('Channels', ChatFolderOptions{ include_channels: true })!
//
//   // Add a specific chat to folder 3:
//   user.add_chat_to_folder(chat_id, 3)!
//
//   // Delete folder 3, leaving all its chats:
//   user.delete_chat_folder(3, [])!
//
//   // Join all chats referenced by a folder invite link:
//   user.join_chat_folder_by_link('https://t.me/addlist/XXXXXXXX')!
//
// Note: chat folder management is only available on user accounts.
// Bots are not members of the Telegram chat list and cannot use folders.
module tdlib

import x.json2

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
	req := new_request('deleteChatFolder').with_int('chat_folder_id', chat_folder_id).with_arr('leave_chat_ids',
		ids).build()!
	return s.send_sync(mut td, req)
}

// --- Adding and removing chats ---

// add_chat_to_folder adds chat_id to the folder identified by chat_folder_id.
// The folder must already exist (use create_chat_folder() or get_chat_folders()
// to find its ID).
//
// TDLib method: addChatToList chat_id:Int53 chat_list:chatListFolder
fn add_chat_to_folder(s Session, mut td TDLib, chat_id i64, chat_folder_id int) !json2.Any {
	req := new_request('addChatToList').with_i64('chat_id', chat_id).with_obj('chat_list',
		{
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
	req := new_request('addChatFolderByInviteLink').with_str('invite_link', invite_link).with_arr('chat_ids',
		ids).build()!
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
	req := new_request('createChatFolderInviteLink').with_int('chat_folder_id', chat_folder_id).with_str('name',
		name).with_arr('chat_ids', ids).build()!
	resp := s.send_sync(mut td, req)!
	return map_str(resp.as_map(), 'invite_link')
}
