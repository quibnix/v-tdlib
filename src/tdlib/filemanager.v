// tdlib/filemanager.v
// High-level file management helpers shared by UserAccount and BotAccount.
//
// --- Download ---
//
//   // Async: register an updateFile handler for progress, then kick it off.
//   bot.on('updateFile', fn (upd json2.Any) {
//       f := tdlib.TDFile.from(tdlib.map_obj(upd.as_map(), 'file'))
//       if f.is_downloaded() { println(f.local_path()) }
//   })
//   bot.download(file_id, 1)!
//
//   // Sync: block until fully downloaded, no handler needed.
//   f := bot.download_sync(file_id, 1)!
//   println(f.local_path())
//
// --- Upload (preliminary) ---
//
//   // Pre-upload once, reuse the remote_id for many sends.
//   f := bot.upload_file('/tmp/banner.jpg', tdlib.file_type_photo)!
//   // f.id() can now be tracked via updateFile.
//   // Once f.remote_id() is non-empty, send via input_remote(f.remote_id()).
//
// --- File type constants ---
//
//   tdlib.file_type_photo
//   tdlib.file_type_video
//   tdlib.file_type_audio
//   tdlib.file_type_voice
//   tdlib.file_type_video_note
//   tdlib.file_type_document
//   tdlib.file_type_sticker
//   tdlib.file_type_animation
module tdlib

import x.json2

// --- File type constants ---
// Pass these to upload_file() to tell TDLib how to classify the upload.

pub const file_type_photo = 'fileTypePhoto'
pub const file_type_video = 'fileTypeVideo'
pub const file_type_audio = 'fileTypeAudio'
pub const file_type_voice = 'fileTypeVoiceNote'
pub const file_type_video_note = 'fileTypeVideoNote'
pub const file_type_document = 'fileTypeDocument'
pub const file_type_sticker = 'fileTypeSticker'
pub const file_type_animation = 'fileTypeAnimation'

// --- Synchronous download ---

// download_file_sync downloads a file and BLOCKS until TDLib reports it is
// fully on disk.  Returns a TDFile with local_path() set.
//
// Unlike download_file(), no 'updateFile' handler is needed.  TDLib handles
// the blocking internally via the synchronous flag.
//
// priority: 1 (lowest) .. 32 (highest).  Files at priority 32 jump ahead of
// any background downloads already queued.
fn download_file_sync(s Session, mut td TDLib, file_id i64, priority int) !TDFile {
	clamped := if priority < 1 {
		1
	} else if priority > 32 {
		32
	} else {
		priority
	}
	req := new_request('downloadFile').with_i64('file_id', file_id).with_int('priority',
		clamped).with_int('offset', 0).with_int('limit', 0).with_bool('synchronous', true).build()!
	resp := s.send_sync(mut td, req)!
	return TDFile.from(resp.as_map())
}

// --- Preliminary upload ---

// preliminary_upload_file pre-uploads a local file to Telegram without
// sending it anywhere.  Returns a TDFile whose remote_id() can be used in
// subsequent input_remote() calls to send the same file to many recipients
// without re-uploading.
//
// file_type: one of the file_type_* constants, e.g. file_type_photo.
// progress:  register an 'updateFile' handler to track upload progress.
//            Once the upload completes f.is_downloaded() stays false, but
//            f.remote_id() becomes non-empty - that is your reuse token.
//
// Typical bot pattern (send the same image to 1000 users):
//
//   f := bot.upload_file('/tmp/promo.jpg', tdlib.file_type_photo)!
//   // watch updateFile for f.id() until remote_unique_id is set, then:
//   for user_id in user_ids {
//       bot.send_photo(user_id, tdlib.input_remote(f.remote_id()), tdlib.PhotoSendOptions{})!
//   }
fn preliminary_upload_file(s Session, mut td TDLib, local_path string, file_type string) !TDFile {
	req := new_request('preliminaryUploadFile').with('file', input_local(local_path)).with_obj('file_type',
		{
		'@type': json2.Any(file_type)
	}).with_int('priority', 1).build()!
	resp := s.send_sync(mut td, req)!
	return TDFile.from(resp.as_map())
}

// cancel_preliminary_upload cancels an in-progress preliminary upload started
// by upload_file().  file_id is the TDFile.id() returned from that call.
// Has no effect if the upload has already completed.
fn cancel_preliminary_upload(s Session, mut td TDLib, file_id i64) !json2.Any {
	req := new_request('cancelPreliminaryUploadFile').with_i64('file_id', file_id).build()!
	return s.send_sync(mut td, req)
}
