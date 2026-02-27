// tdlib/translate.v
// Text and message translation using TDLib's built-in translate API.
//
// TDLib exposes Telegram's translation service which supports automatic
// language detection and translation to a wide range of target languages.
// Translation requires a Telegram Premium subscription on user accounts;
// bots do not require Premium.
//
// --- Translating arbitrary text ---
//
//   result := user.translate_text('Bonjour le monde', 'en')!
//   println(result.text()) // Hello world
//
// --- Translating a received message ---
//
//   bot.on('updateNewMessage', fn [mut bot] (upd json2.Any) {
//       msg := tdlib.Message.from(tdlib.map_obj(upd.as_map(), 'message'))
//       if !msg.is_outgoing() {
//           translated := bot.translate_message(msg.chat_id(), msg.id(), 'en') or { return }
//           println('Translated: ${translated.text()}')
//       }
//   })
//
// Language codes follow IETF BCP 47 (e.g. 'en', 'fr', 'de', 'ja', 'zh-CN').
//
// Supported on both UserAccount and BotAccount.
module tdlib

import x.json2

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
