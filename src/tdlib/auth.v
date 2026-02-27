// tdlib/auth.v
// Authentication state machines for UserAccount and BotAccount.
//
// --- User auth flow ---
//   authorizationStateWaitTdlibParameters         -> (already sent via setup())
//   authorizationStateWaitPhoneNumber              -> setAuthenticationPhoneNumber
//   authorizationStateWaitEmailAddress             -> setAuthenticationEmailAddress
//   authorizationStateWaitEmailCode                -> checkAuthenticationEmailCode
//   authorizationStateWaitOtherDeviceConfirmation  -> display link, wait for confirmation
//   authorizationStateWaitCode                     -> checkAuthenticationCode
//   authorizationStateWaitRegistration             -> registerUser (new accounts only)
//   authorizationStateWaitPassword                 -> checkAuthenticationPassword (2FA)
//   authorizationStateReady                        -> done
//
// --- Bot auth flow ---
//   authorizationStateWaitPhoneNumber   -> checkAuthenticationBotToken
//   authorizationStateReady             -> done
//
// Both loops read from the session's per-account update channel so that
// auth updates for one account never interfere with another account's auth.
//
// --- Custom login ---
//
// By default, run_user_auth() reads credentials from stdin via os.input().
// Use run_user_auth_custom() with a UserLoginHandler to provide credentials
// programmatically (e.g. from a GUI, a config file, or an environment variable).
// Any handler field left as none falls back to the stdin prompt.
//
//   handler := tdlib.UserLoginHandler{
//       get_phone: fn() string { return os.getenv('TG_PHONE') }
//       get_code:  fn() string { return read_code_from_gui() }
//   }
//   user.login_custom(handler)!
module tdlib

import x.json2
import os

// --- Custom auth handler types ---

// UserLoginHandler provides callbacks for each step of the user authorization
// flow.  Only the callbacks your application needs must be assigned; any
// callback left as none (the zero value) falls back to reading from stdin via
// os.input(), which is the same behaviour as login().
//
// Minimum required fields: get_phone (or pass phone to login()), get_code.
// get_password is only needed when the account has 2FA enabled.
// get_email / get_email_code are only needed when Telegram requests them.
// get_first_name is only needed for brand-new accounts (registration).
pub struct UserLoginHandler {
pub:
	// get_phone returns the phone number string (with country code, e.g. "+12025550100").
	// Called when authorizationStateWaitPhoneNumber is received.
	// A none value falls back to an os.input() prompt.
	get_phone ?fn () string
	// get_email returns the email address when Telegram requests it.
	// A none value falls back to an os.input() prompt.
	get_email ?fn () string
	// get_email_code returns the verification code received at the email address.
	// A none value falls back to an os.input() prompt.
	get_email_code ?fn () string
	// get_code returns the OTP/SMS/Telegram authentication code.
	// A none value falls back to an os.input() prompt.
	get_code ?fn () string
	// get_password returns the 2FA cloud password.
	// A none value falls back to an os.input() prompt.
	get_password ?fn () string
	// get_first_name returns the first name to use when registering a new account.
	// A none value falls back to an os.input() prompt.
	get_first_name ?fn () string
	// get_last_name returns the last name to use when registering a new account
	// (may return '' to omit the last name).
	// A none value falls back to an os.input() prompt.
	get_last_name ?fn () string
	// on_qr_link is called when authorizationStateWaitOtherDeviceConfirmation is
	// received.  The link parameter is the tg:// URL that should be displayed as a
	// QR code or opened on another logged-in device.
	// A none value falls back to printing the link to stdout.
	on_qr_link ?fn (link string)
}

// BotLoginHandler provides a custom callback for supplying the bot token during
// the bot authentication flow.  Assign get_token to read the token from any
// source (environment variable, config file, secrets manager, etc.).
//
// A none get_token falls back to reading from stdin.
pub struct BotLoginHandler {
pub:
	// get_token returns the bot token string (e.g. "123456789:ABC-DEF1234...").
	// Called when authorizationStateWaitPhoneNumber is received for a bot session.
	// A none value falls back to an os.input() prompt.
	get_token ?fn () string
}

// --- Public auth entry points ---

// run_user_auth drives the authorization state machine for a phone-number user
// account.  phone is optional: when provided it is used automatically; when
// none the user is prompted via stdin.  Blocks until authorizationStateReady
// or error.  Called by UserAccount.login().
//
// BUG FIX: phone is now ?string so that login() can be called with or without
// a pre-known phone number, removing the forced stdin prompt for callers that
// already have the phone number at login time.
fn run_user_auth(session Session, mut td TDLib, phone ?string) ! {
	handler := if p := phone {
		UserLoginHandler{
			get_phone: fn [p] () string {
				return p
			}
		}
	} else {
		UserLoginHandler{}
	}
	run_user_auth_with_handler(session, mut td, handler)!
}

// run_user_auth_with_handler drives the authorization state machine using the
// callbacks in handler.  Any none callback falls back to os.input().
// Blocks until authorizationStateReady or error.
// Called directly by UserAccount.login_custom().
fn run_user_auth_with_handler(session Session, mut td TDLib, handler UserLoginHandler) ! {
	for {
		update := td.get_update(session.id)
		m := update.as_map()
		typ := map_str(m, '@type')
		// Detect hub shutdown sentinel or closed-channel zero value.
		if typ == 'tdlibShutdown' || typ == '' {
			return error('TDLib hub shut down during authentication')
		}
		if typ != 'updateAuthorizationState' {
			continue
		}
		state := map_obj(m, 'authorization_state')
		match map_str(state, '@type') {
			'authorizationStateWaitTdlibParameters' {
				// Parameters already sent in setup() - nothing to do here.
			}
			'authorizationStateWaitPhoneNumber' {
				// BUG FIX: Optional functions (?fn() string) must be unwrapped with
				// an if-let pattern before calling.  The previous code used
				// `handler.get_phone != none` (invalid for V optionals) and then
				// called `handler.get_phone()` directly on the unwrapped optional
				// without unwrapping first.  All handler field accesses below are
				// corrected to use `if f := handler.xxx { f() }`.
				phone := if f := handler.get_phone {
					f()
				} else {
					os.input('Phone number (with country code): ').trim_space()
				}
				if phone == '' {
					return error('no phone number entered')
				}
				send_phone_number(session, mut td, phone)!
			}
			'authorizationStateWaitEmailAddress' {
				email := if f := handler.get_email {
					f()
				} else {
					os.input('Email address for login: ').trim_space()
				}
				send_email_address(session, mut td, email)!
			}
			'authorizationStateWaitEmailCode' {
				code := if f := handler.get_email_code {
					f()
				} else {
					os.input('Email authentication code: ').trim_space()
				}
				send_email_code(session, mut td, code)!
			}
			'authorizationStateWaitOtherDeviceConfirmation' {
				// The user must confirm the login attempt on another logged-in device.
				// TDLib provides a tg:// link that should be displayed as a QR code or
				// opened on the other device.  TDLib transitions automatically once the
				// confirmation is received; no API call is needed here.
				link := map_str(state, 'link')
				if f := handler.on_qr_link {
					f(link)
				} else if link != '' {
					println('Confirm this login on another device by opening: ${link}')
				} else {
					println('Confirm this login on another device (check your Telegram app).')
				}
				// No API call needed; TDLib transitions automatically once confirmed.
			}
			'authorizationStateWaitCode' {
				code := if f := handler.get_code {
					f()
				} else {
					os.input('Authentication code: ').trim_space()
				}
				if code == '' {
					return error('no authentication code entered')
				}
				send_auth_code(session, mut td, code)!
			}
			'authorizationStateWaitRegistration' {
				first := if f := handler.get_first_name {
					f()
				} else {
					os.input('First name: ').trim_space()
				}
				last := if f := handler.get_last_name {
					f()
				} else {
					os.input('Last name (optional): ').trim_space()
				}
				register_user(session, mut td, first, last)!
			}
			'authorizationStateWaitPassword' {
				pass := if f := handler.get_password {
					f()
				} else {
					os.input('2FA password: ').trim_space()
				}
				if pass == '' {
					return error('no 2FA password entered')
				}
				send_auth_password(session, mut td, pass)!
			}
			'authorizationStateReady' {
				return
			}
			'authorizationStateLoggingOut' {
				return error('session is logging out')
			}
			'authorizationStateClosed' {
				return error('TDLib session closed unexpectedly')
			}
			else {}
		}
	}
}

// run_bot_auth drives the authorization state machine for a bot token.
// Blocks until authorizationStateReady or error.
// Called by BotAccount.login().
fn run_bot_auth(session Session, mut td TDLib, token string) ! {
	handler := BotLoginHandler{
		get_token: fn [token] () string {
			return token
		}
	}
	run_bot_auth_with_handler(session, mut td, handler)!
}

// run_bot_auth_with_handler drives the bot authorization state machine using
// the callback in handler.  A none get_token falls back to os.input().
// Blocks until authorizationStateReady or error.
// Called directly by BotAccount.login_custom().
fn run_bot_auth_with_handler(session Session, mut td TDLib, handler BotLoginHandler) ! {
	for {
		update := td.get_update(session.id)
		m := update.as_map()
		typ := map_str(m, '@type')
		// Detect hub shutdown sentinel or closed-channel zero value.
		if typ == 'tdlibShutdown' || typ == '' {
			return error('TDLib hub shut down during authentication')
		}
		if typ != 'updateAuthorizationState' {
			continue
		}
		state := map_obj(m, 'authorization_state')
		match map_str(state, '@type') {
			'authorizationStateWaitTdlibParameters' {
				// Parameters already sent in setup() - nothing to do.
			}
			'authorizationStateWaitPhoneNumber' {
				// TDLib enters this state for bots too; we respond with the bot
				// token (not a phone number) via checkAuthenticationBotToken.
				// BUG FIX: unwrap optional function with if-let before calling.
				token := if f := handler.get_token {
					f()
				} else {
					os.input('Bot token: ').trim_space()
				}
				if token == '' {
					return error('no bot token provided')
				}
				send_bot_token(session, mut td, token)!
			}
			'authorizationStateReady' {
				return
			}
			'authorizationStateLoggingOut' {
				return error('session is logging out')
			}
			'authorizationStateClosed' {
				return error('TDLib session closed unexpectedly')
			}
			'authorizationStateWaitCode', 'authorizationStateWaitPassword',
			'authorizationStateWaitRegistration', 'authorizationStateWaitEmailAddress',
			'authorizationStateWaitEmailCode', 'authorizationStateWaitOtherDeviceConfirmation' {
				return error('unexpected auth state for bot: ${map_str(state, '@type')}')
			}
			else {}
		}
	}
}

// --- Auth sub-step helpers ---

fn send_phone_number(s Session, mut td TDLib, phone string) ! {
	req := new_request('setAuthenticationPhoneNumber').with_str('phone_number', phone).build()!
	s.send_fire(mut td, req)!
}

fn send_bot_token(s Session, mut td TDLib, token string) ! {
	req := new_request('checkAuthenticationBotToken').with_str('token', token).build()!
	s.send_fire(mut td, req)!
}

fn send_auth_code(s Session, mut td TDLib, code string) ! {
	req := new_request('checkAuthenticationCode').with_str('code', code).build()!
	s.send_fire(mut td, req)!
}

fn send_auth_password(s Session, mut td TDLib, password string) ! {
	req := new_request('checkAuthenticationPassword').with_str('password', password).build()!
	s.send_fire(mut td, req)!
}

fn send_email_address(s Session, mut td TDLib, email string) ! {
	req := new_request('setAuthenticationEmailAddress').with_str('email_address', email).build()!
	s.send_fire(mut td, req)!
}

fn send_email_code(s Session, mut td TDLib, code string) ! {
	// TDLib schema: checkAuthenticationEmailCode code:EmailAddressAuthentication
	// emailAddressAuthenticationCode is the typed wrapper for a plain code string.
	req := new_request('checkAuthenticationEmailCode').with_obj('code', {
		'@type': json2.Any('emailAddressAuthenticationCode')
		'code':  json2.Any(code)
	}).build()!
	s.send_fire(mut td, req)!
}

fn register_user(s Session, mut td TDLib, first_name string, last_name string) ! {
	req := new_request('registerUser').with_str('first_name', first_name).with_str('last_name',
		last_name).build()!
	s.send_fire(mut td, req)!
}
