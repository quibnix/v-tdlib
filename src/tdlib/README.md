# v-tdlib

A V-language wrapper for the [TDLib](https://core.telegram.org/tdlib) Telegram client library. Supports both full user accounts (userbot) and bot token accounts simultaneously, with typed helpers for every common message and media type, complete keyboard support, proxy management, file transfers, chat folder management, and a set of utility functions.

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
  - [Bot account](#bot-account)
  - [User account](#user-account)
  - [Multiple accounts](#multiple-accounts)
- [Authentication](#authentication)
  - [Bot login](#bot-login)
  - [User login](#user-login)
  - [Custom login handlers](#custom-login-handlers)
- [Update handling](#update-handling)
- [Sending messages](#sending-messages)
  - [Plain text](#plain-text)
  - [HTML and MarkdownV2](#html-and-markdownv2)
  - [Replies](#replies)
  - [Send options](#send-options)
- [Sending media](#sending-media)
  - [Photos](#photos)
  - [Videos](#videos)
  - [Audio](#audio)
  - [Voice notes](#voice-notes)
  - [Video notes](#video-notes)
  - [Documents](#documents)
  - [Animations](#animations)
  - [Stickers](#stickers)
  - [Albums](#albums)
  - [Locations and live locations](#locations-and-live-locations)
  - [Venues](#venues)
  - [Contacts](#contacts)
  - [Polls](#polls)
  - [Dice](#dice)
- [Keyboards](#keyboards)
  - [Inline keyboards](#inline-keyboards)
  - [Reply keyboards](#reply-keyboards)
  - [Removing a keyboard](#removing-a-keyboard)
  - [Force reply](#force-reply)
- [Editing messages](#editing-messages)
- [Forwarding and copying](#forwarding-and-copying)
- [Deleting and pinning](#deleting-and-pinning)
- [Reactions](#reactions)
- [Files](#files)
  - [Input file helpers](#input-file-helpers)
  - [Downloading files](#downloading-files)
  - [Uploading files](#uploading-files)
  - [File type constants](#file-type-constants)
- [Identity and chat lookup](#identity-and-chat-lookup)
- [Extended user information](#extended-user-information)
- [Extended supergroup and channel information](#extended-supergroup-and-channel-information)
- [Chat photo history](#chat-photo-history)
- [Chat management](#chat-management)
- [Moderation](#moderation)
- [Chat member queries](#chat-member-queries)
- [Chat folders](#chat-folders)
- [Scheduled messages](#scheduled-messages)
- [Forum topics](#forum-topics)
- [Translation](#translation)
- [Search](#search)
- [Inline queries (bots)](#inline-queries-bots)
- [Callback queries (bots)](#callback-queries-bots)
- [Bot profile management](#bot-profile-management)
- [Proxy management](#proxy-management)
- [Profile management (users)](#profile-management-users)
- [AccountManager](#accountmanager)
- [Raw API access](#raw-api-access)
- [Type reference](#type-reference)
  - [Message](#message)
  - [MessageContent](#messagecontent)
  - [User](#user)
  - [UserFullInfo](#userfullinfo)
  - [Chat](#chat)
  - [SupergroupFullInfo](#supergroupfullinfo)
  - [ChatPhoto](#chatphoto)
  - [TDFile](#tdfile)
  - [Photo and PhotoSize](#photo-and-photosize)
  - [Thumbnail](#thumbnail)
  - [Video](#video)
  - [Audio](#audio-1)
  - [VoiceNote](#voicenote)
  - [VideoNote](#videonote)
  - [Document](#document)
  - [Sticker](#sticker)
  - [Animation](#animation)
  - [Location](#location)
  - [Contact](#contact)
  - [Poll](#poll)
  - [Venue](#venue)
  - [Dice](#dice-1)
  - [ForwardInfo](#forwardinfo)
  - [ChatMember](#chatmember)
  - [ChatFolderInfo](#chatfolderinfo)
  - [ChatFolder](#chatfolder)
  - [ForumTopicInfo](#forumtopicinfo)
  - [ForumTopic](#forumtopic)
  - [TranslatedText](#translatedtext)
  - [Proxy](#proxy)
  - [BotInfo](#botinfo)
- [Builder and low-level helpers](#builder-and-low-level-helpers)
  - [RequestBuilder](#requestbuilder)
  - [FormattedText helpers](#formattedtext-helpers)
  - [Object constructors](#object-constructors)
  - [Map helpers](#map-helpers)
- [Utility functions](#utility-functions)
  - [Formatting](#formatting)
  - [String escaping](#string-escaping)
  - [Text helpers](#text-helpers)
  - [Command parsing](#command-parsing)
  - [Time helpers](#time-helpers)
  - [Validation](#validation)
  - [Fuzzy command matching](#fuzzy-command-matching)
  - [Rate limiting](#rate-limiting)
- [Channel ID semantics](#channel-id-semantics)
- [Log verbosity](#log-verbosity)

---

## Requirements

- [V](https://vlang.io/) compiler
- TDLib shared library (`.so` / `.dylib` / `.dll`) compiled for your platform
- A Telegram `api_id` and `api_hash` from [my.telegram.org](https://my.telegram.org)

---

## Installation

Copy the `tdlib/` directory into your project and import the module:

```v
import tdlib
```

---

## Quick Start

### Bot account

```v
import tdlib

fn main() {
    mut bot := tdlib.BotAccount.new()!
    defer { bot.shutdown() }

    bot.setup(api_id, api_hash, './data/bot')!
    bot.login('123456:ABCdef...')!

    bot.on('updateNewMessage', fn [mut bot] (upd json2.Any) {
        msg := tdlib.Message.from(tdlib.map_obj(upd.as_map(), 'message'))
        if msg.is_outgoing() { return }
        bot.send_text(msg.chat_id(), 'Hello!') or {}
    })

    for { _ = bot.get_update() }
}
```

### User account

```v
import tdlib

fn main() {
    mut user := tdlib.UserAccount.new()!
    defer { user.shutdown() }

    user.setup(api_id, api_hash, './data/user')!
    user.login('+12025550100')!   // pass none to prompt on stdin

    user.on('updateNewMessage', fn [mut user] (upd json2.Any) {
        msg := tdlib.Message.from(tdlib.map_obj(upd.as_map(), 'message'))
        if msg.is_outgoing() { return }
        user.send_text(msg.chat_id(), 'Got it!') or {}
    })

    for { _ = user.get_update() }
}
```

### Multiple accounts

```v
mut mgr := tdlib.AccountManager.new()
defer { mgr.shutdown() }

alice := mgr.add_user('alice')
alice.setup(api_id, api_hash, './db/alice')!
alice.login('+12025550100')!

scanner := mgr.add_bot('scanner')
scanner.setup(api_id, api_hash, './db/scanner')!
scanner.login(bot_token)!
```

---

## Authentication

### Bot login

```v
bot.login('123456:ABCdef...')!
```

### User login

```v
// Prompt for phone number, code, and optional 2FA password via stdin:
user.login(none)!

// Provide the phone number programmatically (code and 2FA still prompt stdin):
user.login('+12025550100')!
```

### Custom login handlers

Use `login_custom` to supply all credentials without touching stdin - useful for GUI apps and automated test suites.

**Bot:**

```v
handler := tdlib.BotLoginHandler{
    get_token: fn() string { return os.getenv('BOT_TOKEN') }
}
bot.login_custom(handler)!
```

**User:**

```v
handler := tdlib.UserLoginHandler{
    get_phone: fn() string { return os.getenv('TG_PHONE') }
    get_code:  fn() string { return read_otp_from_database() }
    // get_password: fn() string { return '2fa-password' }  // optional
}
user.login_custom(handler)!
```

---

## Update handling

Register typed update handlers before entering the main loop. Each handler runs in its own goroutine so you can call any synchronous API method inside it.

```v
bot.on('updateNewMessage', fn [mut bot] (upd json2.Any) {
    msg := tdlib.Message.from(tdlib.map_obj(upd.as_map(), 'message'))
    // ...
})

bot.on('updateNewCallbackQuery', fn [mut bot] (upd json2.Any) {
    m   := upd.as_map()
    qid := tdlib.map_i64(m, 'id')
    // ...
})

// Remove a handler:
bot.off('updateNewMessage')
```

For a manual polling loop (useful during startup):

```v
upd := bot.get_update()
```

---

## Sending messages

### Plain text

```v
bot.send_text(chat_id, 'Hello world')!
bot.send_text_opts(chat_id, 'Hello', tdlib.SendOptions{ silent: true })!
```

### HTML and MarkdownV2

```v
bot.send_html(chat_id, '<b>Bold</b> and <i>italic</i>')!
bot.send_markdown(chat_id, '*Bold* and _italic_')!
```

### Replies

```v
bot.reply_text(chat_id, reply_to_message_id, 'Got it!')!
bot.reply_html(chat_id, reply_to_message_id, '<b>Noted</b>')!
bot.reply_markdown(chat_id, reply_to_message_id, '_Understood_')!
```

### Send options

`SendOptions` is accepted by every text and media send method:

| Field | Type | Description |
|---|---|---|
| `reply_to_message_id` | `i64` | Message to reply to. `0` means no reply. |
| `silent` | `bool` | Suppress the notification sound for the recipient. |
| `protect_content` | `bool` | Disable forwarding and saving for recipients. |
| `message_thread_id` | `i64` | Forum topic thread ID for sending into a topic. `0` means no topic. See [Forum topics](#forum-topics). |

```v
opts := tdlib.SendOptions{
    reply_to_message_id: original_id
    silent:              true
    protect_content:     true
}
bot.send_text_opts(chat_id, 'Secret reply', opts)!
```

---

## Sending media

All media send functions accept an `InputFile` built with one of the [input file helpers](#input-file-helpers).

### Photos

```v
bot.send_photo(chat_id, tdlib.input_local('/tmp/img.jpg'), tdlib.PhotoSendOptions{
    caption: 'My photo'
    ttl:     0          // self-destruct timer in seconds; 0 = permanent
    send:    tdlib.SendOptions{}
})!
```

### Videos

```v
bot.send_video(chat_id, tdlib.input_local('/tmp/clip.mp4'), tdlib.VideoSendOptions{
    caption:            'My video'
    duration:           30        // seconds
    width:              1280
    height:             720
    supports_streaming: true
})!
```

### Audio

```v
bot.send_audio(chat_id, tdlib.input_local('/tmp/song.mp3'), tdlib.AudioSendOptions{
    title:     'Song Title'
    performer: 'Artist Name'
    duration:  210
    caption:   'Listen to this'
})!
```

### Voice notes

```v
bot.send_voice_note(chat_id, tdlib.input_local('/tmp/voice.ogg'), tdlib.VoiceSendOptions{
    duration: 15
    caption:  ''
    // waveform: raw PCM bytes (optional; shown as audio visualiser)
})!
```

### Video notes

```v
bot.send_video_note(chat_id, tdlib.input_local('/tmp/note.mp4'), tdlib.VideoNoteSendOptions{
    duration: 15
    length:   384   // circle diameter in pixels
})!
```

### Documents

```v
bot.send_document(chat_id, tdlib.input_local('/tmp/file.pdf'), tdlib.DocumentSendOptions{
    caption: 'Attached PDF'
})!
```

### Animations

```v
bot.send_animation(chat_id, tdlib.input_local('/tmp/anim.gif'), tdlib.AnimationSendOptions{
    caption:  'Funny GIF'
    duration: 3
    width:    480
    height:   270
})!
```

### Stickers

```v
bot.send_sticker(chat_id, tdlib.input_id(file_id))!
bot.send_sticker_opts(chat_id, tdlib.input_remote(remote_id), tdlib.StickerSendOptions{
    width:  512
    height: 512
    emoji:  ''
})!
```

### Albums

Send 2-10 photos or videos as a single grouped album:

```v
items := [
    tdlib.album_photo(tdlib.input_local('/img1.jpg'), 'First'),
    tdlib.album_photo(tdlib.input_local('/img2.jpg'), ''),
    tdlib.album_video(tdlib.input_local('/clip.mp4'), 'Clip', 10, 1280, 720),
]
bot.send_album(chat_id, items, tdlib.SendOptions{})!
```

### Locations and live locations

```v
// Static pin:
bot.send_location(chat_id, 51.5074, -0.1278)!
bot.send_location_opts(chat_id, 51.5074, -0.1278, tdlib.SendOptions{ silent: true })!

// Live location (updates in real time):
bot.send_live_location(chat_id, 51.5074, -0.1278, tdlib.LiveLocationOptions{
    live_period:            900   // seconds (60..86400; 2147483647 = indefinite)
    heading:                90    // degrees (1..360; 0 = not set)
    proximity_alert_radius: 500   // metres (0 = disabled)
})!

// Push a new position:
bot.edit_live_location(chat_id, message_id, 51.51, -0.12, 180, 0)!

// Stop the live share:
bot.stop_live_location(chat_id, message_id)!
```

### Venues

```v
bot.send_venue(chat_id,
    51.5074, -0.1278,                 // latitude, longitude
    'Big Ben', 'Westminster, London', // title, address
    'foursquare', '4b058764f964a52076001fe3', // provider, place ID ('' for plain)
    tdlib.VenueOptions{})!
```

### Contacts

```v
bot.send_contact(chat_id, '+12025550100', 'John', 'Doe')!
bot.send_contact_opts(chat_id, '+12025550100', 'John', 'Doe', tdlib.SendOptions{})!
```

### Polls

```v
// Regular poll:
bot.send_poll(chat_id, 'Favourite colour?', ['Red', 'Green', 'Blue'],
    tdlib.PollSendOptions{
        is_anonymous:            true
        allows_multiple_answers: false
    })!

// Quiz (single correct answer):
bot.send_poll(chat_id, 'Capital of France?', ['Berlin', 'Paris', 'Madrid'],
    tdlib.PollSendOptions{
        correct_option_id: 1
        explanation:       'Paris is the capital.'
    })!

// Vote (user accounts only):
user.set_poll_answer(chat_id, poll_message_id, [1])!

// Close a poll:
bot.stop_poll(chat_id, poll_message_id)!
```

### Dice

```v
// Pass the emoji character as a runtime string variable.
// Supported emojis: die, dart, basketball, football, slot machine, bowling ball.
bot.send_dice(chat_id, dice_emoji)!
bot.send_dice_opts(chat_id, dice_emoji, tdlib.SendOptions{ silent: true })!
```

---

## Keyboards

### Inline keyboards

Inline keyboards attach buttons to a specific message. Pressing a button fires `updateNewCallbackQuery` (or opens a URL) and does **not** send a message.

```v
markup := tdlib.inline_keyboard_markup([
    [
        tdlib.InlineButton{ text: 'Yes', callback_data: 'answer:yes' },
        tdlib.InlineButton{ text: 'No',  callback_data: 'answer:no'  },
    ],
    [
        tdlib.InlineButton{ text: 'Visit',  url: 'https://example.com' },
        tdlib.InlineButton{ text: 'Search', switch_inline_query: ' '  },
    ],
])
bot.send_text_keyboard(chat_id, 'Make a choice:', markup, tdlib.SendOptions{})!
```

`InlineButton` fields:

| Field | Description |
|---|---|
| `text` | Button label |
| `callback_data` | Callback payload string. Automatically base64-encoded. Decode with `tdlib.decode_callback_data()`. |
| `url` | Opens this URL when tapped (takes priority over callback). |
| `switch_inline_query` | Opens inline mode in any chosen chat with this query. Use `' '` for an empty query. |
| `switch_inline_current` | Opens inline mode in the **current** chat. |

**Layout helpers:**

```v
buttons := [btn1, btn2, btn3, btn4, btn5]

// Explicit layout [2, 3] -> row 1 has 2, row 2 has 3:
markup := tdlib.inline_keyboard_layout(buttons, [2, 3])!

// Auto: 2 buttons per row:
markup = tdlib.inline_keyboard_auto(buttons, 2)
```

**Decoding callback data:**

```v
bot.on('updateNewCallbackQuery', fn [mut bot] (upd json2.Any) {
    m    := upd.as_map()
    qid  := tdlib.map_i64(m, 'id')
    data := tdlib.decode_callback_data(tdlib.map_str(tdlib.map_obj(m, 'payload'), 'data'))
    bot.answer_callback_query(qid, '', false, '', 0) or {}
})
```

### Reply keyboards

Reply keyboards show persistent buttons below the text input box. Pressing a button sends its text as a normal message.

```v
markup := tdlib.reply_keyboard_markup([
    [
        tdlib.KeyboardButton{ text: 'Red'   },
        tdlib.KeyboardButton{ text: 'Green' },
        tdlib.KeyboardButton{ text: 'Blue'  },
    ],
    [
        tdlib.KeyboardButton{ text: 'My Location', request_location: true },
        tdlib.KeyboardButton{ text: 'My Phone',    request_phone:    true },
    ],
], tdlib.ReplyKeyboardOptions{
    resize:      true
    one_time:    true
    is_personal: false
    placeholder: 'Choose a colour...'
})
bot.send_text_reply_keyboard(chat_id, 'Pick one:', markup, tdlib.SendOptions{})!
```

`KeyboardButton` fields:

| Field | Description |
|---|---|
| `text` | Button label and the text sent as a message when pressed. |
| `request_phone` | Shows the system "Share phone number" dialog. |
| `request_location` | Shows the system location picker. |

**Layout helpers:**

```v
// Explicit layout:
markup := tdlib.reply_keyboard_layout(buttons, [2, 2, 1], opts)!

// Auto layout:
markup = tdlib.reply_keyboard_auto(buttons, 2, opts)
```

### Removing a keyboard

```v
bot.send_text_reply_keyboard(chat_id, 'Done!', tdlib.remove_keyboard(false), tdlib.SendOptions{})!
```

Pass `true` to `remove_keyboard` to remove the keyboard only for the current user (groups only).

### Force reply

```v
bot.send_text_keyboard(chat_id, 'What is your name?',
    tdlib.force_reply(false, 'Enter your name...'),
    tdlib.SendOptions{})!
```

---

## Editing messages

```v
// Edit plain text:
bot.edit_text(chat_id, message_id, 'Updated text')!
bot.edit_html(chat_id, message_id, '<b>Updated</b>')!
bot.edit_markdown(chat_id, message_id, '*Updated*')!

// Edit caption on a media message:
bot.edit_caption(chat_id, message_id, 'New caption')!

// Replace keyboard:
bot.edit_reply_markup(chat_id, message_id, new_markup)!

// Edit inline-query messages (identified by inline_message_id string):
bot.edit_inline_markup(inline_message_id, new_markup)!
bot.edit_inline_text(inline_message_id, '<b>New text</b>', new_markup)!
bot.edit_inline_text_plain(inline_message_id, 'New text', new_markup)!
bot.edit_inline_text_markdown(inline_message_id, '*New text*', new_markup)!
```

---

## Forwarding and copying

```v
// Forward with "Forwarded from" attribution:
bot.forward_messages(to_chat_id, from_chat_id, [msg_id1, msg_id2])!

// Forward and re-attach the original inline keyboard:
bot.forward_message_with_markup(to_chat_id, from_chat_id, msg_id)!

// Copy without attribution:
bot.copy_message(to_chat_id, from_chat_id, msg_id,
    false,               // remove_caption
    tdlib.SendOptions{})!
```

---

## Deleting and pinning

```v
// Delete specific messages (revoke = delete for everyone):
bot.delete(chat_id, [msg_id1, msg_id2], true)!

// Delete every message in an album by any one member's ID:
bot.delete_album(chat_id, any_album_msg_id, true)!  // user accounts only

// Pin a message:
bot.pin_message(chat_id, message_id, false)!   // false = notify members

// Unpin a single message:
bot.unpin_message(chat_id, message_id)!

// Unpin all pinned messages at once:
bot.unpin_all_messages(chat_id)!
```

---

## Reactions

```v
// Add a reaction (is_big = true sends an animated "big" reaction):
bot.add_message_reaction(chat_id, message_id, reaction_emoji, false)!

// Remove a previously set reaction:
bot.remove_message_reaction(chat_id, message_id, reaction_emoji)!
```

Pass the emoji character as a runtime string variable.

---

## Files

### Input file helpers

Use these wherever an `InputFile` argument is required:

```v
tdlib.input_local('/path/to/file.jpg')  // upload from disk
tdlib.input_id(file_id)                 // reference a file TDLib already knows
tdlib.input_remote(remote_id)           // reference by Telegram remote ID string
```

### Downloading files

**Asynchronous** - register a handler for progress, then start the download:

```v
bot.on('updateFile', fn (upd json2.Any) {
    f := tdlib.TDFile.from(tdlib.map_obj(upd.as_map(), 'file'))
    if f.is_downloaded() {
        println('Saved to: ${f.local_path()}')
    } else {
        println('${f.downloaded_size()} / ${f.size()} bytes')
    }
})
bot.download(file_id, 16)!   // priority 1 (lowest) .. 32 (highest)
```

**Synchronous** - blocks until fully on disk, no handler needed:

```v
f := bot.download_sync(file_id, 16)!
println(f.local_path())
```

Cancel a download:

```v
bot.cancel_download(file_id)!
```

Get file metadata by ID:

```v
f := bot.get_file(file_id)!
```

### Uploading files

Pre-upload a file once and reuse it for many sends:

```v
f := bot.upload_file('/tmp/promo.jpg', tdlib.file_type_photo)!
// Track progress via updateFile on f.id().
// Once remote_id is non-empty, send to many recipients:
for uid in user_ids {
    bot.send_photo(uid, tdlib.input_remote(f.remote_id()), tdlib.PhotoSendOptions{})!
}

bot.cancel_upload(f.id())!   // cancel if needed
```

### File type constants

| Constant | TDLib type |
|---|---|
| `tdlib.file_type_photo` | `fileTypePhoto` |
| `tdlib.file_type_video` | `fileTypeVideo` |
| `tdlib.file_type_audio` | `fileTypeAudio` |
| `tdlib.file_type_voice` | `fileTypeVoiceNote` |
| `tdlib.file_type_video_note` | `fileTypeVideoNote` |
| `tdlib.file_type_document` | `fileTypeDocument` |
| `tdlib.file_type_sticker` | `fileTypeSticker` |
| `tdlib.file_type_animation` | `fileTypeAnimation` |

---

## Identity and chat lookup

```v
me   := bot.get_me()!
user := bot.get_user(user_id)!
chat := bot.get_chat(chat_id)!
msg  := bot.get_message(chat_id, message_id)!

// User accounts only:
history := user.get_chat_history(chat_id, 0, 50)!  // from_message_id=0 = newest
ids      := user.get_chats(100)!                    // sorted by last activity
```

---

## Extended user information

`getUserFullInfo` returns the bio, call settings, profile photos, and more:

```v
full := user.get_user_full_info(user_id)!

full.bio()                                         // About text
full.group_in_common_count()                       // int
full.can_be_called()                               // bool
full.supports_video_calls()                        // bool
full.has_private_calls()                           // bool
full.has_private_forwards()                        // bool
full.has_restricted_voice_and_video_note_messages() // bool
full.has_pinned_stories()                          // bool
full.is_blocked()                                  // bool

if photo := full.photo() {                         // ChatPhoto?
    println('Photo id: ${photo.id()}')
    if sz := photo.largest_size() {
        println('${sz.width()}x${sz.height()}')
    }
}

// personal_photo(): shown only to contacts (Telegram Premium)
// public_photo():   fallback when main photo is contacts-only
```

Available on both `UserAccount` and `BotAccount`.

---

## Extended supergroup and channel information

`getSupergroupFullInfo` returns description, member counts, invite link, profile photo, and more. Pass the bare `supergroup_id` from `Chat.supergroup_id()`:

```v
chat  := user.get_chat(chat_id)!
sgfi  := user.get_supergroup_full_info(chat.supergroup_id())!

sgfi.description()                       // About text
sgfi.member_count()                      // int
sgfi.administrator_count()               // int
sgfi.restricted_count()                  // int
sgfi.banned_count()                      // int
sgfi.linked_chat_id()                    // i64 (discussion group or linked channel)
sgfi.slow_mode_delay()                   // int seconds (0 = off)
sgfi.is_all_history_available()          // bool
sgfi.has_aggressive_anti_spam_enabled()  // bool
sgfi.has_hidden_members()                // bool
sgfi.sticker_set_id()                    // i64
sgfi.custom_emoji_sticker_set_id()       // i64
sgfi.invite_link_url()                   // string (primary invite link URL)
sgfi.has_pinned_stories()                // bool
sgfi.upgraded_from_basic_group_id()      // i64 (0 if not upgraded)

if photo := sgfi.photo() {               // ChatPhoto?
    println('Channel photo id: ${photo.id()}')
}
```

Available on both `UserAccount` and `BotAccount`.

---

## Chat photo history

Returns all profile photos for any chat, oldest to newest:

```v
photos := user.get_chat_photo_history(chat_id, 0, 50)!
for p in photos {
    println('id=${p.id()}  added=${tdlib.unix_to_date(p.added_date())}')
    if sz := p.largest_size() {
        println('  ${sz.width()}x${sz.height()}  file_id=${sz.file().id()}')
    }
}
```

Parameters: `chat_id`, `offset` (skip N photos), `limit` (max to return).

Available on both `UserAccount` and `BotAccount`.

---

## Chat management

```v
bot.set_chat_title(chat_id, 'New Title')!
bot.set_chat_description(chat_id, 'New description')!
bot.set_chat_photo(chat_id, '/path/to/photo.jpg')!
bot.delete_chat_photo(chat_id)!
bot.set_slow_mode(chat_id, 30)!    // 0, 10, 30, 60, 300, 900, or 3600 seconds

// User accounts only:
user.leave_chat(chat_id)!
user.join_chat_by_invite_link('https://t.me/+XXXXXXXX')!
link := user.create_chat_invite_link(chat_id, 0, 0)! // expire_date=0, limit=0 = unlimited

// Open / close a chat to receive live location updates and read receipts:
user.open_chat(chat_id)!
user.close_chat(chat_id)!

// Mark messages as read (user accounts only):
user.view_messages(chat_id, [msg_id1, msg_id2], true)!

// Chat action indicator:
bot.send_chat_action(chat_id, 'chatActionTyping')!
```

---

## Moderation

```v
// Ban permanently (pass revoke_messages=true to also delete their messages):
bot.ban_chat_member(chat_id, user_id, false)!

// Unban (user can rejoin):
bot.unban_chat_member(chat_id, user_id)!

// Kick (remove without permanent ban):
bot.kick_chat_member(chat_id, user_id)!

// Restrict:
bot.restrict_chat_member(chat_id, user_id, tdlib.ChatPermissions{
    can_send_messages:       true
    can_send_media_messages: false
    can_send_polls:          false
}, until_date)!    // until_date=0 for permanent

// Promote to admin:
bot.promote_chat_member(chat_id, user_id, tdlib.full_admin_rights(), 'Moderator')!

// Demote back to member:
bot.demote_chat_member(chat_id, user_id)!
```

`full_admin_rights()` returns an `AdminRights` with every permission set to `true`. Build a custom `AdminRights` struct to restrict which rights are granted.

---

## Chat member queries

```v
// All admins:
admins := bot.get_chat_administrators(chat_id)!
for a in admins {
    println('${a.member_id()}  admin=${a.is_admin()}  owner=${a.is_owner()}')
}

// Member count (dispatches to the correct TDLib method for each chat type):
count := bot.get_chat_member_count(chat_id)!

// Single member status:
member := bot.get_chat_member(chat_id, user_id)!
println('banned=${member.is_banned()}  joined=${member.joined_chat_date()}')

// Supergroup member list (user accounts only for most filters):
members := user.get_supergroup_members(
    chat.supergroup_id(),
    tdlib.sg_filter_recent,   // or sg_filter_administrators, sg_filter_banned, etc.
    0, 200)!
```

Supergroup member filter constants:

| Constant | Description |
|---|---|
| `tdlib.sg_filter_recent` | Most recently joined members |
| `tdlib.sg_filter_administrators` | All administrators |
| `tdlib.sg_filter_banned` | Banned users |
| `tdlib.sg_filter_restricted` | Restricted users |
| `tdlib.sg_filter_bots` | Bots in the group |

---

## Chat folders

Chat folders are only available on user accounts. Bots have no chat list concept.

### Listing folders

```v
folders := user.get_chat_folders()!
for f in folders {
    println('id=${f.id()}  name=${f.name()}  icon=${f.icon_name()}')
}
```

### Getting full folder configuration

```v
folder := user.get_chat_folder(folder_id)!
println(folder.name())
println(folder.include_channels())
println(folder.exclude_muted())
for id in folder.pinned_chat_ids() {
    println('pinned: ${id}')
}
```

### Listing chats in a folder

```v
ids := user.get_chats_in_folder(folder_id, 50)!
for id in ids {
    chat := user.get_chat(id)!
    println(chat.title())
}
```

### Creating a folder

```v
new_id := user.create_chat_folder('Work', tdlib.ChatFolderOptions{
    icon_name:        'Briefcase'
    include_channels: false
    include_groups:   true
    include_bots:     false
    exclude_muted:    true
    is_shareable:     true
    included_chat_ids: [chat_id_a, chat_id_b]
})!
```

### Editing a folder

```v
info := user.edit_chat_folder(folder_id, 'Work (updated)', tdlib.ChatFolderOptions{
    include_groups:   true
    exclude_archived: true
})!
println('Updated: ${info.name()}')
```

### Deleting a folder

```v
// Keep all chats; just remove the folder:
user.delete_chat_folder(folder_id, [])!

// Leave specific chats when deleting:
user.delete_chat_folder(folder_id, [chat_id_to_leave])!
```

### Adding and removing a chat

```v
// Add a chat to a folder:
user.add_chat_to_folder(chat_id, folder_id)!

// Remove a chat from a folder (does not leave the chat):
user.remove_chat_from_folder(chat_id, folder_id)!
```

### Joining chats via a folder link

```v
// Check a link before joining (returns raw info map):
info := user.check_chat_folder_invite_link('https://t.me/addlist/XXXXXXXX')!
folder_info := tdlib.ChatFolderInfo.from(tdlib.map_obj(info.as_map(), 'chat_folder_info'))
println('Folder: ${folder_info.name()}')

// Join all chats in the link (pass [] to join all):
user.join_chat_folder_by_link('https://t.me/addlist/XXXXXXXX', [])!

// Join only specific chats from the link:
user.join_chat_folder_by_link('https://t.me/addlist/XXXXXXXX', [chat_id_a, chat_id_b])!
```

### Creating a folder invite link

```v
link := user.create_chat_folder_invite_link(
    folder_id,
    'My Work Folder',   // link label
    [])!                // [] = include all shareable chats
println(link)           // https://t.me/addlist/...
```

---

## Scheduled messages

Messages can be held back and delivered at a specified Unix timestamp. Scheduled messages appear in the chat's "Scheduled Messages" list until sent or cancelled. All content types (text, photos, documents) support scheduling.

```v
// Schedule a plain-text message to go out in one hour.
send_date := tdlib.unix_now() + 3600
user.send_scheduled_text(chat_id, 'See you in an hour!', send_date, tdlib.SendOptions{})!

// Schedule an HTML message.
user.send_scheduled_html(chat_id, '<b>Reminder:</b> meeting at 3pm', send_date, tdlib.SendOptions{})!

// Schedule a photo.
user.send_scheduled_photo(chat_id, tdlib.input_local('/tmp/banner.jpg'), 'Launching soon!',
    send_date, tdlib.SendOptions{})!

// List all pending scheduled messages in a chat.
msgs := user.get_scheduled_messages(chat_id)!
for m in msgs {
    println('Scheduled: ${m.text()}')
}

// Deliver a specific scheduled message right now.
user.send_scheduled_message_now(chat_id, msgs[0].id())!

// Deliver every pending scheduled message in the chat immediately.
user.send_all_scheduled_now(chat_id)!

// Cancel (delete without sending) one or more scheduled messages.
user.delete_scheduled_messages(chat_id, [msgs[0].id()])!
```

Scheduled messages are available on both `UserAccount` and `BotAccount`.

| Method | Returns | Description |
|---|---|---|
| `send_scheduled_text(chat_id, text, send_date, opts)` | `!json2.Any` | Schedule a plain-text message. |
| `send_scheduled_html(chat_id, html, send_date, opts)` | `!json2.Any` | Schedule an HTML-formatted message. |
| `send_scheduled_markdown(chat_id, md, send_date, opts)` | `!json2.Any` | Schedule a MarkdownV2 message. |
| `send_scheduled_photo(chat_id, file, caption, send_date, opts)` | `!json2.Any` | Schedule a photo. |
| `send_scheduled_document(chat_id, file, caption, send_date, opts)` | `!json2.Any` | Schedule a document. |
| `get_scheduled_messages(chat_id)` | `![]Message` | List all pending scheduled messages. |
| `send_scheduled_message_now(chat_id, message_id)` | `!json2.Any` | Deliver a scheduled message immediately. |
| `send_all_scheduled_now(chat_id)` | `!` | Deliver every pending scheduled message immediately. |
| `delete_scheduled_messages(chat_id, message_ids)` | `!json2.Any` | Cancel scheduled messages without sending. |

---

## Forum topics

Forum topics are named threads inside supergroups that have the "Topics" feature enabled. Each topic is identified by a `message_thread_id`. Pass this ID in `SendOptions.message_thread_id` to send messages to the topic.

### Creating and sending to a topic

```v
// Create a new topic with a built-in colour icon.
// Allowed icon_color values: 0x6FB9F0 (blue), 0xFFD67E (yellow), 0xCB86DB (violet),
// 0x8EEE98 (green), 0xFF93B2 (rose), 0xFB6F5F (red). Pass 0 to let Telegram choose.
info := user.create_forum_topic(chat_id, 'Announcements', 0x6FB9F0, '')!
thread_id := info.message_thread_id()

// Send a message inside the topic.
user.send_text_opts(chat_id, 'Welcome to Announcements!',
    tdlib.SendOptions{ message_thread_id: thread_id })!

// Send HTML into a topic.
user.send_html_opts(chat_id, '<b>First post</b>',
    tdlib.SendOptions{ message_thread_id: thread_id })!
```

### Managing topics

```v
// List the first 20 topics (pass zeroes for the initial page).
topics := user.get_forum_topics(chat_id, '', 0, 0, 0, 20)!
for t in topics {
    info := t.info()
    println('${info.name()} thread=${info.message_thread_id()} closed=${info.is_closed()}')
}

// Get a single topic by thread ID.
topic := user.get_forum_topic(chat_id, thread_id)!
println('Unread: ${topic.unread_count()}')

// Rename a topic.
user.edit_forum_topic(chat_id, thread_id, 'Important Announcements', '')!

// Read the message history of a topic.
msgs := user.get_forum_topic_history(chat_id, thread_id, 0, 50)!

// Close (archive) a topic - no new messages can be posted.
user.close_forum_topic(chat_id, thread_id)!

// Re-open a closed topic.
user.reopen_forum_topic(chat_id, thread_id)!

// Pin a topic at the top of the forum list.
user.pin_forum_topic(chat_id, thread_id, true)!

// Hide the built-in General topic (supergroup owners only).
user.hide_general_forum_topic(chat_id, true)!

// Permanently delete a topic and all its messages.
user.delete_forum_topic(chat_id, thread_id)!
```

Forum topics are available on both `UserAccount` and `BotAccount` (bots require `can_manage_topics` admin right for most management operations).

| Method | Returns | Description |
|---|---|---|
| `create_forum_topic(chat_id, name, icon_color, icon_custom_emoji_id)` | `!ForumTopicInfo` | Create a new topic. |
| `edit_forum_topic(chat_id, thread_id, name, icon_custom_emoji_id)` | `!json2.Any` | Rename or change the icon of a topic. |
| `close_forum_topic(chat_id, thread_id)` | `!json2.Any` | Archive a topic. |
| `reopen_forum_topic(chat_id, thread_id)` | `!json2.Any` | Un-archive a topic. |
| `delete_forum_topic(chat_id, thread_id)` | `!json2.Any` | Delete a topic and all its messages. |
| `pin_forum_topic(chat_id, thread_id, is_pinned)` | `!json2.Any` | Pin or unpin a topic. |
| `hide_general_forum_topic(chat_id, hide)` | `!json2.Any` | Hide or show the General topic. |
| `get_forum_topics(chat_id, query, offset_date, offset_msg_id, offset_thread_id, limit)` | `![]ForumTopic` | Paginated topic list. |
| `get_forum_topic(chat_id, thread_id)` | `!ForumTopic` | Get details of a single topic. |
| `get_forum_topic_history(chat_id, thread_id, from_message_id, limit)` | `![]Message` | Message history of a topic. |

---

## Translation

Translate text strings or existing messages to any target language using Telegram's built-in translation service. Language detection is automatic; only the target language code is needed.

Language codes follow [IETF BCP 47](https://en.wikipedia.org/wiki/IETF_language_tag): `'en'`, `'fr'`, `'de'`, `'ja'`, `'zh-CN'`, etc.

```v
// Translate an arbitrary string.
result := user.translate_text('Bonjour le monde', 'en')!
println(result.text())  // Hello world

// Translate an existing message (identified by chat_id + message_id).
translated := bot.translate_message(msg.chat_id(), msg.id(), 'en')!
println(translated.text())

// Check whether the result contains formatting entities.
if translated.has_entities() {
    // Work with translated.entities_raw() for rich text rendering.
}
```

Translation is available on both `UserAccount` and `BotAccount`. User accounts require Telegram Premium for `translate_text` and `translate_message`. Bots do not require Premium.

| Method | Returns | Description |
|---|---|---|
| `translate_text(text, to_language_code)` | `!TranslatedText` | Translate a plain string. |
| `translate_message(chat_id, message_id, to_language_code)` | `!TranslatedText` | Translate the text of an existing message. |

---

## Search

```v
// Find a public chat by username:
chat := bot.search_public_chat('telegram')!

// Search messages in a chat:
results := user.search_messages(chat_id, 'invoice', 0, 20)!

// Get profile photos of a user (UserAccount only):
photos := user.get_user_profile_photos(user_id, 10)!
for p in photos {
    if sz := p.largest_size() {
        f := user.download_sync(sz.file().id(), 16)!
        println(f.local_path())
    }
}
```

---

## Inline queries (bots)

```v
bot.on('updateNewInlineQuery', fn [mut bot] (upd json2.Any) {
    m        := upd.as_map()
    query_id := tdlib.map_i64(m, 'id')
    query    := tdlib.map_str(m, 'query')

    results := [
        tdlib.inline_result_article(
            'r1', 'Result title', 'Description',
            tdlib.plain_text('Message text'),
            json2.Any(map[string]json2.Any{}),
        ),
        tdlib.inline_result_photo_simple(
            'r2', 'A photo', '',
            'https://example.com/photo.jpg',
            'https://example.com/thumb.jpg',
        ),
        tdlib.inline_result_gif_simple(
            'r3', 'A GIF',
            'https://example.com/anim.gif',
            'https://example.com/thumb.jpg',
            'image/jpeg',
        ),
    ]
    bot.answer_inline_query(query_id, results, 10, false, '')!
})
```

---

## Callback queries (bots)

Bots **must** answer every callback query or the button will spin indefinitely.

```v
bot.on('updateNewCallbackQuery', fn [mut bot] (upd json2.Any) {
    m    := upd.as_map()
    qid  := tdlib.map_i64(m, 'id')
    data := tdlib.decode_callback_data(
        tdlib.map_str(tdlib.map_obj(m, 'payload'), 'data'))

    // Show a toast notification:
    bot.answer_callback_query(qid, 'You clicked: ${data}', false, '', 0) or {}

    // Show an alert dialog:
    // bot.answer_callback_query(qid, 'Alert!', true, '', 0) or {}
})
```

---

## Bot profile management

```v
// Commands shown in the Telegram UI:
bot.set_commands([
    tdlib.BotCommand{ command: 'start', description: 'Start the bot' },
    tdlib.BotCommand{ command: 'help',  description: 'Show help'     },
])!
cmds := bot.get_commands()!

// Name, descriptions:
bot.set_name('My Bot')!
bot.set_description('A long description shown to new users.')!
bot.set_short_description('Short description shown on profile page.')!

// Profile photo:
bot.set_profile_photo('/path/to/photo.jpg')!

// Current info:
info := bot.get_info()!
println('Name: ${info.name()}')
println('Description: ${info.description()}')
println('Short: ${info.short_description()}')

// Web App menu button:
bot.set_menu_button(0, 'Open App', 'https://myapp.example.com')!  // 0 = all users
bot.reset_menu_button(0)!
```

---

## Proxy management

```v
// Add proxies:
p1 := bot.add_mtproto_proxy('proxy.example.com', 443, 'ee0000...')!
p2 := bot.add_socks5_proxy('socks.example.com', 1080, 'user', 'pass')!
p3 := bot.add_http_proxy('http.example.com', 8080, '', '')!

// List all stored proxies:
proxies := bot.get_proxies()!
for p in proxies {
    println('${p.id()}  ${p.server()}:${p.port()}  type=${p.proxy_type()}  active=${p.is_enabled()}')
}

// Activate / deactivate:
bot.enable_proxy(p1.id())!
bot.disable_proxy()!

// Measure latency:
ms := bot.ping_proxy(p1.id())!
println('Ping: ${ms:.1f} ms')

// Auto-select the fastest:
sorted := bot.get_proxies_sorted_by_ping()!
if sorted.len > 0 {
    bot.enable_proxy(sorted[0].proxy.id())!
}

// Remove a proxy:
bot.remove_proxy(p2.id())!
```

---

## Profile management (users)

```v
user.set_name('Alice', 'Smith')!
user.set_bio('My new bio text.')!
user.set_username('alice_dev')!       // '' removes the username
user.set_profile_photo('/photo.jpg')!
user.delete_profile_photo(photo_id)!  // photo_id from get_user_profile_photos()
```

---

## AccountManager

`AccountManager` runs many accounts over a single shared TDLib hub. Update routing is automatic - handlers on one account never fire for another.

```v
mut mgr := tdlib.AccountManager.new()
defer { mgr.shutdown() }

alice := mgr.add_user('alice')
alice.setup(api_id, api_hash, './db/alice')!
alice.login('+12025550100')!

scanner := mgr.add_bot('scanner')
scanner.setup(api_id, api_hash, './db/scanner')!
scanner.login(bot_token)!

// Retrieve by name later:
a := mgr.user('alice')!
b := mgr.bot('scanner')!

// List registered names:
println(mgr.user_names())
println(mgr.bot_names())
```

---

## Raw API access

Call any TDLib method not yet wrapped by the library:

```v
req := tdlib.new_request('getTopChats')
    .with_obj('category', { '@type': json2.Any('topChatCategoryUsers') })
    .with_int('limit', 10)
    .build()!

// Fire and forget:
bot.raw_send_fire(req)!

// Async (returns a channel):
ch := bot.raw_send(req)!
resp := <-ch

// Synchronous:
resp := bot.raw_send_sync(req)!
m    := resp.as_map()
```

---

## Type reference

### Message

```v
msg.id()                   // i64  message ID
msg.chat_id()              // i64  chat this message belongs to
msg.date()                 // i64  Unix timestamp
msg.edit_date()            // i64  Unix timestamp of last edit (0 if never edited)
msg.is_outgoing()          // bool
msg.is_pinned()            // bool
msg.is_channel_post()      // bool
msg.can_be_edited()        // bool
msg.can_be_deleted_only_for_self()   // bool
msg.can_be_deleted_for_all_users()   // bool
msg.media_album_id()       // i64  non-zero for album members
msg.via_bot_user_id()      // i64  0 if not via inline bot
msg.author_signature()     // string channel post signature
msg.sender_user_id()       // i64  0 for channel/anonymous posts
msg.sender_chat_id()       // i64  -100XXXXXXXXX form; 0 for user senders
msg.reply_to_message_id()  // i64  0 if not a reply
msg.reply_to_chat_id()     // i64  non-zero for cross-chat replies
msg.content()              // MessageContent
msg.text()                 // string  shortcut for content().text()
msg.caption()              // string  shortcut for content().caption()
msg.reply_markup_raw()     // json2.Any  raw reply_markup field
msg.forward_info()         // ?ForwardInfo
```

### MessageContent

```v
mc.content_type()       // string  e.g. 'messageText', 'messagePhoto', ...
mc.text()               // string  plain text (messageText only)
mc.caption()            // string  caption for media types

mc.as_photo()           // ?Photo
mc.as_video()           // ?Video
mc.as_audio()           // ?Audio
mc.as_voice_note()      // ?VoiceNote
mc.as_video_note()      // ?VideoNote
mc.as_document()        // ?Document
mc.as_sticker()         // ?Sticker
mc.as_animation()       // ?Animation
mc.as_location()        // ?Location
mc.as_contact()         // ?Contact
mc.as_poll()            // ?Poll
mc.as_venue()           // ?Venue
mc.as_dice()            // ?Dice
```

### User

```v
u.id()                  // i64
u.first_name()          // string
u.last_name()           // string
u.full_name()           // string  "First Last"
u.username()            // string  first active username (no '@')
u.phone_number()        // string
u.language_code()       // string
u.is_bot()              // bool
u.is_verified()         // bool
u.is_premium()          // bool
u.is_support()          // bool
u.is_scam()             // bool
u.is_fake()             // bool
u.is_mutual_contact()   // bool
u.profile_photo_small() // ?TDFile
u.profile_photo_big()   // ?TDFile
```

### UserFullInfo

```v
full.bio()                                          // string
full.group_in_common_count()                        // int
full.can_be_called()                                // bool
full.supports_video_calls()                         // bool
full.has_private_calls()                            // bool
full.has_private_forwards()                         // bool
full.has_restricted_voice_and_video_note_messages() // bool
full.has_pinned_stories()                           // bool
full.is_blocked()                                   // bool
full.photo()                                        // ?ChatPhoto  (main public photo)
full.personal_photo()                               // ?ChatPhoto  (contacts-only photo)
full.public_photo()                                 // ?ChatPhoto  (fallback public photo)
```

### Chat

```v
c.id()                  // i64  always in correct API form
c.title()               // string
c.chat_type()           // string  @type of the type object
c.is_private()          // bool
c.is_group()            // bool  (basic group)
c.is_supergroup()       // bool
c.is_channel()          // bool
c.is_secret()           // bool
c.private_user_id()     // i64  (private chats only)
c.supergroup_id()       // i64  bare ID for getSupergroup* methods
c.channel_chat_id()     // i64  -100XXXXXXXXX form for message APIs
c.unread_count()        // int
c.unread_mention_count()// int
c.is_marked_as_unread() // bool
c.has_protected_content()// bool
c.member_count()        // int  (usually 0; use get_chat_member_count() instead)
```

**Important:** Use `chat.id()` or `chat.channel_chat_id()` when passing the ID to message-level API calls. Use `chat.supergroup_id()` only for `getSupergroup*` methods.

### SupergroupFullInfo

```v
sgfi.photo()                            // ?ChatPhoto
sgfi.description()                      // string
sgfi.member_count()                     // int
sgfi.administrator_count()              // int
sgfi.restricted_count()                 // int
sgfi.banned_count()                     // int
sgfi.linked_chat_id()                   // i64
sgfi.slow_mode_delay()                  // int
sgfi.is_all_history_available()         // bool
sgfi.has_aggressive_anti_spam_enabled() // bool
sgfi.has_hidden_members()               // bool
sgfi.sticker_set_id()                   // i64
sgfi.custom_emoji_sticker_set_id()      // i64
sgfi.invite_link_url()                  // string
sgfi.has_pinned_stories()               // bool
sgfi.upgraded_from_basic_group_id()     // i64
```

### ChatPhoto

```v
cp.id()             // i64
cp.added_date()     // i64  Unix timestamp
cp.sizes()          // []PhotoSize
cp.largest_size()   // ?PhotoSize
cp.smallest_size()  // ?PhotoSize
cp.has_animation()  // bool
```

### TDFile

```v
f.id()                  // i64
f.size()                // i64  total bytes (0 while unknown)
f.expected_size()       // i64
f.remote_id()           // string  Telegram remote ID
f.remote_unique_id()    // string
f.local_path()          // string  path on disk (empty until downloaded)
f.is_downloaded()       // bool
f.is_downloading()      // bool
f.downloaded_size()     // i64
f.can_be_downloaded()   // bool
```

### Photo and PhotoSize

```v
// Photo (from message content):
p.id()              // i64
p.has_stickers()    // bool
p.sizes()           // []PhotoSize
p.largest_size()    // ?PhotoSize
p.smallest_size()   // ?PhotoSize

// PhotoSize:
sz.size_type()      // string  single letter like 's', 'm', 'x', 'y'
sz.width()          // int
sz.height()         // int
sz.file()           // TDFile  (key is 'photo')
```

### Thumbnail

Used by `Video`, `Audio`, `Document`, `Sticker`, `Animation`, `VideoNote`:

```v
t.width()           // int
t.height()          // int
t.file()            // TDFile  (key is 'file', not 'photo')
t.format_type()     // string  e.g. 'thumbnailFormatJpeg'
```

### Video

```v
v.duration()            // int
v.width()               // int
v.height()              // int
v.file_name()           // string
v.mime_type()           // string
v.supports_streaming()  // bool
v.file()                // TDFile  (key 'video')
v.thumbnail()           // ?Thumbnail
```

### Audio

```v
a.duration()    // int
a.title()       // string
a.performer()   // string
a.file_name()   // string
a.mime_type()   // string
a.file()        // TDFile  (key 'audio')
a.thumbnail()   // ?Thumbnail  (album cover)
```

### VoiceNote

```v
v.duration()    // int
v.mime_type()   // string
v.file()        // TDFile  (key 'voice')
v.waveform()    // []u8   decoded from base64
```

### VideoNote

```v
v.duration()    // int
v.length()      // int  circle diameter in pixels
v.file()        // TDFile  (key 'video')
v.thumbnail()   // ?Thumbnail
```

### Document

```v
d.file_name()   // string
d.mime_type()   // string
d.file()        // TDFile  (key 'document')
d.thumbnail()   // ?Thumbnail
```

### Sticker

```v
s.set_id()      // i64
s.width()       // int
s.height()      // int
s.emoji()       // string
s.format()      // string  @type of format object
s.file()        // TDFile  (key 'sticker')
s.thumbnail()   // ?Thumbnail
```

### Animation

```v
a.duration()    // int
a.width()       // int
a.height()      // int
a.file_name()   // string
a.mime_type()   // string
a.file()        // TDFile  (key 'animation')
a.thumbnail()   // ?Thumbnail
```

### Location

```v
l.latitude()            // f64
l.longitude()           // f64
l.horizontal_accuracy() // f64
```

### Contact

```v
c.phone_number()    // string
c.first_name()      // string
c.last_name()       // string
c.user_id()         // i64
```

### Poll

```v
p.id()                  // i64
p.question()            // string  plain text
p.is_anonymous()        // bool
p.is_closed()           // bool
p.total_voter_count()   // int
p.type_str()            // string  'pollTypeRegular' or 'pollTypeQuiz'
p.is_quiz()             // bool
p.options()             // []json2.Any  raw option objects
p.option_text(i)        // string  plain text of option at index i
```

### Venue

```v
v.location()        // Location
v.title()           // string
v.address()         // string
v.provider()        // string  e.g. 'foursquare'
v.provider_id()     // string  third-party place ID
```

### Dice

```v
d.emoji()   // string  dice emoji character
d.value()   // int     rolled value (0 while animating)
```

### ForwardInfo

```v
fi.date()                   // i64  Unix timestamp of original message
fi.origin_type()            // string  @type of origin
fi.origin_user_id()         // i64  (messageOriginUser)
fi.origin_sender_name()     // string  (messageOriginHiddenUser)
fi.origin_chat_id()         // i64  -100XXXXXXXXX form (messageOriginChat / messageOriginChannel)
fi.origin_message_id()      // i64  (messageOriginChannel)
fi.origin_author_signature()// string
```

### ChatMember

```v
cm.member_id()          // i64  user ID (0 for chat senders)
cm.status_type()        // string  @type of status object
cm.is_admin()           // bool
cm.is_owner()           // bool
cm.is_banned()          // bool
cm.joined_chat_date()   // i64  Unix timestamp
```

### ChatFolderInfo

```v
cfi.id()                // int
cfi.name()              // string
cfi.icon_name()         // string
cfi.color_id()          // int  (-1 = default)
cfi.is_shareable()      // bool
cfi.has_my_invite_links()// bool
```

### ChatFolder

```v
cf.name()                   // string
cf.icon_name()              // string
cf.color_id()               // int
cf.is_shareable()           // bool
cf.pinned_chat_ids()        // []i64
cf.included_chat_ids()      // []i64
cf.excluded_chat_ids()      // []i64
cf.exclude_muted()          // bool
cf.exclude_read()           // bool
cf.exclude_archived()       // bool
cf.include_contacts()       // bool
cf.include_non_contacts()   // bool
cf.include_bots()           // bool
cf.include_groups()         // bool
cf.include_channels()       // bool
```

### ForumTopicInfo

Summary of a forum topic returned by `create_forum_topic()` and embedded in `ForumTopic.info()`.

```v
fi.message_thread_id()      // i64    - use as SendOptions.message_thread_id
fi.name()                   // string
fi.creation_date()          // i64
fi.is_closed()              // bool
fi.is_hidden()              // bool
fi.is_pinned()              // bool
fi.is_outgoing()            // bool   - true if the current account created this topic
fi.icon_color()             // int    - ARGB colour of the built-in icon
fi.icon_custom_emoji_id()   // i64    - custom emoji icon document ID (0 if using built-in)
fi.creator_user_id()        // i64    - 0 for anonymous/chat senders
```

### ForumTopic

Full topic object returned by `get_forum_topics()` and `get_forum_topic()`.

```v
ft.info()                   // ForumTopicInfo
ft.is_pinned()              // bool
ft.unread_count()           // int
ft.unread_mention_count()   // int
ft.unread_reaction_count()  // int
ft.last_message()           // ?Message
```

### TranslatedText

Result of `translate_text()` and `translate_message()`.

```v
tt.text()           // string        - the translated plain text
tt.has_entities()   // bool          - true when formatting entities are present
tt.entities_raw()   // []json2.Any   - raw textEntity array for rich rendering
```

### Proxy

```v
p.id()              // int
p.server()          // string
p.port()            // int
p.is_enabled()      // bool
p.last_used_date()  // i64
p.proxy_type()      // string  @type of the type object
```

### BotInfo

```v
bi.name()               // string
bi.description()        // string
bi.short_description()  // string
```

---

## Builder and low-level helpers

### RequestBuilder

Build a TDLib request with a fluent API:

```v
req := tdlib.new_request('sendMessage')
    .with_i64('chat_id', chat_id)
    .with_str('text', 'Hello')
    .with_bool('disable_notification', true)
    .with_int('reply_to_message_id', 0)
    .with_i64('some_id', some_id)
    .with_f64('latitude', 51.5)
    .with_obj('options', { '@type': json2.Any('messageSendOptions') })
    .with_arr('ids', [json2.Any(i64(1)), json2.Any(i64(2))])
    .build()!
```

### FormattedText helpers

```v
tdlib.plain_text('Hello, world!')      // no formatting
tdlib.html_text('<b>Bold</b>')!        // parsed HTML
tdlib.markdown_text('*Bold*')!         // parsed MarkdownV2
```

### Object constructors

```v
tdlib.typed_obj('proxyTypeSocks5', { 'username': json2.Any('user') })
tdlib.obj({ 'key': json2.Any('value') })
tdlib.arr([json2.Any('a'), json2.Any('b')])
tdlib.arr_of_i64([i64(1), i64(2), i64(3)])
tdlib.arr_of_str(['a', 'b', 'c'])
tdlib.val(42)!          // wraps any primitive as json2.Any
```

### Map helpers

These are exported so you can work with raw `json2.Any` maps from update handlers:

```v
tdlib.map_str(m, 'key')     // string
tdlib.map_i64(m, 'key')     // i64
tdlib.map_int(m, 'key')     // int
tdlib.map_bool(m, 'key')    // bool
tdlib.map_arr(m, 'key')     // []json2.Any
tdlib.map_obj(m, 'key')     // map[string]json2.Any
tdlib.map_type(m, 'key')    // string  @type of nested object
tdlib.any_to_i64(v)         // i64  coerces any numeric json2.Any
```

---

## Utility functions

### Formatting

```v
tdlib.fmt_bytes(1536)                // "1 KB"
tdlib.fmt_bytes_precise(1536)        // "1.5 KB"
tdlib.fmt_bytes_precise(2684354560)  // "2.5 GB"
tdlib.fmt_duration(90)               // "1m 30s"
tdlib.fmt_duration(3661)             // "1h 1m 1s"
tdlib.fmt_count(1500)                // "1.5K"
tdlib.fmt_count(2_000_000)           // "2M"
```

### String escaping

```v
tdlib.escape_html('a < b & c > d')   // safe for HTML messages
tdlib.escape_markdown('Hello (world)')// safe for MarkdownV2 messages
```

### Text helpers

```v
tdlib.truncate('Hello, world!', 8, '...')         // "Hello..."
tdlib.smart_truncate('Hello world foo', 10, '...') // "Hello..."  (word boundary)
tdlib.chunks('long text', 4000)                    // []string  (splits at byte boundary)
tdlib.chunks_runes('emoji text', 100)              // []string  (splits at rune boundary)
tdlib.word_wrap('long sentence here', 10)          // []string
tdlib.strip_html('<b>Bold</b> text')               // "Bold text"
```

### Command parsing

```v
if ca := tdlib.parse_command('/start@mybot hello world') {
    println(ca.command)    // "start"
    println(ca.args)       // ["hello", "world"]
    println(ca.raw_args)   // "hello world"
}
```

### Time helpers

```v
tdlib.unix_now()                        // i64  current Unix timestamp
tdlib.unix_to_date(1700000000)          // "2023-11-14 22:13:20"
tdlib.relative_time(unix_now() - 70)    // "1 minute ago"
tdlib.plural(1, 'item', 'items')        // "1 item"
tdlib.plural(5, 'item', 'items')        // "5 items"
```

### Validation

```v
tdlib.is_valid_username('@mybot')       // true
tdlib.is_valid_username('x')           // false  (too short)
tdlib.is_valid_command('/start')       // true
tdlib.is_valid_command('/Start')       // false  (uppercase)
```

### Fuzzy command matching

```v
known := ['/start', '/help', '/settings']
if cmd := tdlib.closest_command('/setings', known, 2) {
    println('Did you mean ${cmd}?')   // "/settings"
}

dist := tdlib.levenshtein('kitten', 'sitting')  // 3
```

### Rate limiting

```v
mut rl := tdlib.RateLimiter.new(3, 10)   // 3 calls per 10 seconds

if rl.allow('${user_id}') {
    bot.send_text(chat_id, reply) or {}
} else {
    bot.send_text(chat_id, 'Too fast! Try again shortly.') or {}
}

rl.remaining('${user_id}')   // int  calls left in current window
rl.reset('${user_id}')       // clear history for this key
```

---

## Channel ID semantics

TDLib uses two different numeric representations for channels and supergroups:

| Representation | Form | Used by |
|---|---|---|
| `supergroup_id` | Bare positive integer | `getSupergroup`, `getSupergroupFullInfo`, `getSupergroupMembers` |
| `chat_id` | `-100XXXXXXXXX` negative integer | Every message/send/forward API call |

The library handles this automatically:

- `Chat.id()` always returns the correct `chat_id` form.
- `Chat.channel_chat_id()` converts a bare `supergroup_id` to the `-100XXXXXXXXX` form.
- `Chat.supergroup_id()` returns the bare ID for `getSupergroup*` methods.
- `Message.sender_chat_id()` automatically normalises channel sender IDs to `-100XXXXXXXXX`.
- `ForwardInfo.origin_chat_id()` automatically normalises forwarded channel IDs.
- `channel_id_to_chat_id(id)` is available as a standalone helper; it is a no-op for already-negative IDs.

```v
chat := user.get_chat(chat_id)!

// Correct for message/send calls:
bot.send_text(chat.id(), 'Hello')!
bot.send_text(chat.channel_chat_id(), 'Hello')!

// Correct for supergroup-level methods:
sgfi := user.get_supergroup_full_info(chat.supergroup_id())!
```

---

## Log verbosity

```v
tdlib.set_log_verbosity(1)   // errors only (recommended for production)
tdlib.set_log_verbosity(3)   // info
tdlib.set_log_verbosity(5)   // verbose debug
```

Levels: `0` fatal, `1` errors, `2` warnings, `3` info, `4` debug, `5` verbose.
