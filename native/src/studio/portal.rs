//! `studio pick-picture [title [filter name]]`: the desktop's file chooser,
//! through xdg-desktop-portal's `org.freedesktop.portal.FileChooser.OpenFile`
//! on the session bus.
//!
//! The call: no parent window, the title (default "Choose a picture"),
//! `modal`, one file, and one filter (default name "Images") of the MIME
//! types the lock can decode: `image/png`, `image/jpeg`, `image/webp`. The
//! bus is `$DBUS_SESSION_BUS_ADDRESS`, else `$XDG_RUNTIME_DIR/bus`, else
//! `/run/user/<uid>/bus`. The helper waits up to 30 minutes for the choice
//! and dies with its parent.
//!
//! Replies: `{"ok": true, "path": "/absolute/path"}`; `{"ok": true,
//! "cancelled": true}` when the dialog was closed without a choice; or
//! exit 1 with `NO_SESSION_BUS` (no bus, or it refused us),
//! `PORTAL_UNAVAILABLE` (no portal, or one without a file chooser) or
//! `PORTAL_FAILED` (an error from the portal, a choice that isn't a local
//! file or isn't UTF-8, the time limit).

use std::time::{Duration, Instant};

use foamy_helper::Failure;
use serde_json::{Value, json};

use super::dbus::{self, Address, Connection, Error, Message, Writer};
use super::{Env, random_suffix};

pub const DEFAULT_TITLE: &str = "Choose a picture";
pub const DEFAULT_FILTER: &str = "Images";
pub const MIME_TYPES: [&str; 3] = ["image/png", "image/jpeg", "image/webp"];
const PORTAL: &str = "org.freedesktop.portal.Desktop";
const PORTAL_PATH: &str = "/org/freedesktop/portal/desktop";
const REQUEST: &str = "org.freedesktop.portal.Request";
const WAIT: Duration = Duration::from_secs(30 * 60);

/// The session bus.
pub fn bus_address(env: &Env) -> Result<Address, Failure> {
    if let Some(list) = &env.bus {
        return dbus::parse_address(list).ok_or_else(|| {
            Failure::coded(
                "NO_SESSION_BUS",
                format!("DBUS_SESSION_BUS_ADDRESS has no unix socket: {list}"),
            )
        });
    }
    let runtime = env
        .runtime
        .clone()
        .unwrap_or_else(|| format!("/run/user/{}", rustix::process::getuid().as_raw()).into());
    Ok(Address::Path(runtime.join("bus")))
}

/// `OpenFile`'s body (`ssa{sv}`).
pub fn open_file_body(title: &str, filter: &str, token: &str) -> Vec<u8> {
    let images = |w: &mut Writer| {
        w.structure(|w| {
            w.string(filter);
            w.array(8, |w| {
                for mime in MIME_TYPES {
                    w.structure(|w| {
                        w.u32(1);
                        w.string(mime);
                    });
                }
            });
        });
    };
    let mut w = Writer::new();
    w.string("");
    w.string(title);
    w.array(8, |w| {
        w.entry("handle_token", "s", |w| w.string(token));
        w.entry("modal", "b", |w| w.boolean(true));
        w.entry("multiple", "b", |w| w.boolean(false));
        w.entry("directory", "b", |w| w.boolean(false));
        w.entry("filters", "a(sa(us))", |w| w.array(8, images));
        w.entry("current_filter", "(sa(us))", images);
    });
    w.buf
}

/// The `Response` signal's body (`ua{sv}`): the response code and the
/// chosen URIs.
pub fn parse_response(message: &Message) -> Result<(u32, Vec<String>), Error> {
    if message.signature != "ua{sv}" {
        return Err(Error::Protocol(format!(
            "a Response of type {:?}",
            message.signature
        )));
    }
    let mut r = message.reader();
    let code = r.u32()?;
    let mut uris = Vec::new();
    r.array(8, |r| {
        r.align(8)?;
        let key = r.string()?;
        let signature = r.signature()?;
        if key == "uris" && signature == "as" {
            r.array(4, |r| {
                uris.push(r.string()?.to_string());
                Ok(())
            })
        } else {
            r.skip(signature)
        }
    })?;
    Ok((code, uris))
}

/// A local path from a `file:` URI (empty or `localhost` host).
pub fn uri_path(uri: &str) -> Option<String> {
    let rest = uri.strip_prefix("file://")?;
    let path = rest.strip_prefix("localhost").unwrap_or(rest);
    if !path.starts_with('/') || path.contains(['?', '#']) {
        return None;
    }
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    if out.contains(&0) {
        return None;
    }
    String::from_utf8(out).ok()
}

fn failed(error: Error) -> Failure {
    match error {
        Error::NoBus(text) => Failure::coded("NO_SESSION_BUS", text),
        Error::Timeout => Failure::coded("PORTAL_FAILED", "no choice within the time limit"),
        other => Failure::coded("PORTAL_FAILED", other.to_string()),
    }
}

const UNAVAILABLE: [&str; 5] = [
    "org.freedesktop.DBus.Error.ServiceUnknown",
    "org.freedesktop.DBus.Error.NameHasNoOwner",
    "org.freedesktop.DBus.Error.UnknownMethod",
    "org.freedesktop.DBus.Error.UnknownInterface",
    "org.freedesktop.DBus.Error.UnknownObject",
];

/// The portal conversation on `address`.
pub fn pick_on(
    address: &Address,
    title: &str,
    filter: &str,
    deadline: Instant,
) -> Result<Value, Failure> {
    let mut bus = Connection::open(address, deadline).map_err(failed)?;
    let token = format!(
        "foamy_lock_{}",
        random_suffix().map_err(|e| failed(Error::Io(e)))?
    );
    let sender = bus.unique_name.trim_start_matches(':').replace('.', "_");
    // Subscribe to the predicted request path before the call, so the
    // Response can't come first.
    let mut handles = vec![format!("{PORTAL_PATH}/request/{sender}/{token}")];
    let add_match = |bus: &mut Connection, handle: &str| {
        let rule = format!("type='signal',interface='{REQUEST}',member='Response',path='{handle}'");
        let mut body = Writer::new();
        body.string(&rule);
        bus.send(
            Message::call(
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "AddMatch",
            )
            .with_body("s", body.buf),
        )
    };
    add_match(&mut bus, &handles[0]).map_err(failed)?;
    let call = bus
        .send(
            Message::call(
                PORTAL,
                PORTAL_PATH,
                "org.freedesktop.portal.FileChooser",
                "OpenFile",
            )
            .with_body("ssa{sv}", open_file_body(title, filter, &token)),
        )
        .map_err(failed)?;
    loop {
        let message = bus.read().map_err(failed)?;
        match message.kind {
            dbus::METHOD_RETURN if message.reply_serial == Some(call) => {
                // An older portal may pick its own path: follow that one too.
                if let Ok(handle) = message.reader().string()
                    && !handles.iter().any(|known| known == handle)
                {
                    let handle = handle.to_string();
                    add_match(&mut bus, &handle).map_err(failed)?;
                    handles.push(handle);
                }
            }
            dbus::ERROR if message.reply_serial == Some(call) => {
                let name = message.error_name.clone().unwrap_or_default();
                let text = message.first_string().unwrap_or_default();
                let code = if UNAVAILABLE.contains(&name.as_str()) {
                    "PORTAL_UNAVAILABLE"
                } else {
                    "PORTAL_FAILED"
                };
                return Err(Failure::coded(code, format!("{name}: {text}")));
            }
            dbus::SIGNAL
                if message.interface.as_deref() == Some(REQUEST)
                    && message.member.as_deref() == Some("Response")
                    && message
                        .path
                        .as_ref()
                        .is_some_and(|path| handles.contains(path)) =>
            {
                let (code, uris) = parse_response(&message).map_err(failed)?;
                return match code {
                    0 => {
                        let uri = uris.first().ok_or_else(|| {
                            Failure::coded("PORTAL_FAILED", "the portal chose nothing")
                        })?;
                        let path = uri_path(uri).ok_or_else(|| {
                            Failure::coded("PORTAL_FAILED", format!("not a local file: {uri}"))
                        })?;
                        Ok(json!({"ok": true, "path": path}))
                    }
                    1 | 2 => Ok(json!({"ok": true, "cancelled": true})),
                    other => Err(Failure::coded(
                        "PORTAL_FAILED",
                        format!("the portal answered {other}"),
                    )),
                };
            }
            _ => {}
        }
    }
}

/// `studio pick-picture`.
pub fn pick(env: &Env, title: &str, filter: &str) -> Result<Value, Failure> {
    // A studio that quits takes its question with it.
    let _ = foamy_helper::process::die_with_parent();
    pick_on(&bus_address(env)?, title, filter, Instant::now() + WAIT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::studio::dbus::{Reader, Wire};
    use crate::studio::tests::Scratch;
    use std::os::unix::net::UnixListener;
    use std::thread;

    #[test]
    fn file_uris_become_paths() {
        assert_eq!(
            uri_path("file:///home/me/a.png").as_deref(),
            Some("/home/me/a.png")
        );
        assert_eq!(
            uri_path("file://localhost/home/me/Bilde%20%C3%A5.jpg").as_deref(),
            Some("/home/me/Bilde å.jpg")
        );
        for bad in [
            "https://x/a.png",
            "file://host/a.png",
            "file:relative",
            "file:///a%00b",
            "file:///a%zz",
            "file:///a%ff",
            "file:///a?b",
        ] {
            assert_eq!(uri_path(bad), None, "{bad}");
        }
    }

    #[test]
    fn the_bus_comes_from_the_environment() {
        let scratch = Scratch::new("bus");
        let mut env = scratch.env();
        assert_eq!(
            bus_address(&env).unwrap(),
            Address::Path(scratch.path("run/bus"))
        );
        env.bus = Some("unix:path=/x/bus".into());
        assert_eq!(bus_address(&env).unwrap(), Address::Path("/x/bus".into()));
        env.bus = Some("tcp:host=localhost".into());
        assert_eq!(bus_address(&env).unwrap_err().code, "NO_SESSION_BUS");
    }

    /// What the fake portal does with `OpenFile`.
    #[derive(Clone, Copy)]
    enum Portal {
        Choose,
        Cancel,
        OwnPath,
        Missing,
    }

    fn reply_to(call: &Message, kind: u8) -> Message {
        Message {
            kind,
            reply_serial: Some(call.serial),
            destination: call.sender.clone(),
            sender: Some("org.freedesktop.DBus".into()),
            ..Message::default()
        }
    }

    /// A one-client bus with a portal behind it; returns what OpenFile got.
    fn serve(
        listener: UnixListener,
        portal: Portal,
    ) -> thread::JoinHandle<(String, String, Vec<String>)> {
        thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut wire = Wire::new(stream, Instant::now() + Duration::from_secs(10));
            assert_eq!(wire.read_exact(1).unwrap(), b"\0");
            let auth = wire.read_line().unwrap();
            let uid = rustix::process::getuid().as_raw().to_string();
            let expected: String = uid.bytes().map(|b| format!("{b:02x}")).collect();
            assert_eq!(auth, format!("AUTH EXTERNAL {expected}"));
            wire.write(b"OK 0123456789abcdef0123456789abcdef\r\n")
                .unwrap();
            assert_eq!(wire.read_line().unwrap(), "BEGIN");
            let mut serial = 100;
            let mut send = |wire: &mut Wire, mut message: Message| {
                serial += 1;
                message.serial = serial;
                wire.write(&message.encode()).unwrap();
            };
            let mut matches = Vec::new();
            loop {
                let mut call = wire.read_message().unwrap();
                call.sender = Some(":1.42".into());
                match call.member.as_deref().unwrap_or("") {
                    "Hello" => {
                        let mut body = Writer::new();
                        body.string(":1.42");
                        // A signal first, as a real bus sends NameAcquired.
                        let mut acquired = Message {
                            kind: dbus::SIGNAL,
                            path: Some("/org/freedesktop/DBus".into()),
                            interface: Some("org.freedesktop.DBus".into()),
                            member: Some("NameAcquired".into()),
                            ..Message::default()
                        };
                        acquired = acquired.with_body("s", body.buf.clone());
                        send(&mut wire, acquired);
                        send(
                            &mut wire,
                            reply_to(&call, dbus::METHOD_RETURN).with_body("s", body.buf),
                        );
                    }
                    "AddMatch" => {
                        matches.push(call.reader().string().unwrap().to_string());
                        send(&mut wire, reply_to(&call, dbus::METHOD_RETURN));
                    }
                    "OpenFile" => {
                        assert_eq!(call.destination.as_deref(), Some(PORTAL));
                        assert_eq!(call.signature, "ssa{sv}");
                        let mut r: Reader = call.reader();
                        assert_eq!(r.string().unwrap(), "");
                        let title = r.string().unwrap().to_string();
                        let mut token = String::new();
                        r.array(8, |r| {
                            r.align(8)?;
                            let key = r.string()?.to_string();
                            let signature = r.signature()?.to_string();
                            if key == "handle_token" {
                                token = r.string()?.to_string();
                                Ok(())
                            } else {
                                r.skip(&signature)
                            }
                        })
                        .unwrap();
                        if let Portal::Missing = portal {
                            let mut body = Writer::new();
                            body.string("The name is not activatable");
                            let mut error = reply_to(&call, dbus::ERROR).with_body("s", body.buf);
                            error.error_name =
                                Some("org.freedesktop.DBus.Error.ServiceUnknown".into());
                            send(&mut wire, error);
                            return (title, token, matches);
                        }
                        let path = match portal {
                            Portal::OwnPath => {
                                "/org/freedesktop/portal/desktop/request/1_42/other".to_string()
                            }
                            _ => format!("/org/freedesktop/portal/desktop/request/1_42/{token}"),
                        };
                        let mut body = Writer::new();
                        body.string(&path);
                        send(
                            &mut wire,
                            reply_to(&call, dbus::METHOD_RETURN).with_body("o", body.buf),
                        );
                        if let Portal::OwnPath = portal {
                            // Wait for the client to subscribe to it.
                            let call = wire.read_message().unwrap();
                            matches.push(call.reader().string().unwrap().to_string());
                            send(&mut wire, reply_to(&call, dbus::METHOD_RETURN));
                        }
                        let mut body = Writer::new();
                        body.u32(if let Portal::Cancel = portal { 1 } else { 0 });
                        body.array(8, |w| {
                            w.entry("choices", "a(ss)", |w| w.array(8, |_| {}));
                            w.entry("uris", "as", |w| {
                                w.array(4, |w| w.string("file:///home/me/Pictures/Fjord%20lys.png"))
                            });
                            w.entry("writable", "b", |w| w.boolean(false));
                        });
                        let response = Message {
                            kind: dbus::SIGNAL,
                            path: Some(path),
                            interface: Some(REQUEST.into()),
                            member: Some("Response".into()),
                            sender: Some(":1.7".into()),
                            ..Message::default()
                        }
                        .with_body("ua{sv}", body.buf);
                        // A Response for someone else's request first: ignored.
                        let mut stray = response.clone();
                        stray.path = Some("/org/freedesktop/portal/desktop/request/1_9/x".into());
                        send(&mut wire, stray);
                        send(&mut wire, response);
                        return (title, token, matches);
                    }
                    other => panic!("unexpected call {other}"),
                }
            }
        })
    }

    fn fake_bus(
        tag: &str,
        portal: Portal,
        title: &str,
    ) -> (Result<Value, Failure>, (String, String, Vec<String>)) {
        let scratch = Scratch::new(tag);
        let socket = scratch.path("bus");
        let server = serve(UnixListener::bind(&socket).unwrap(), portal);
        let result = pick_on(
            &Address::Path(socket),
            title,
            "Bilder",
            Instant::now() + Duration::from_secs(10),
        );
        (result, server.join().unwrap())
    }

    #[test]
    fn a_choice_comes_back_as_a_path() {
        let (result, (title, token, matches)) = fake_bus("choose", Portal::Choose, "Velg et bilde");
        assert_eq!(
            result.unwrap(),
            json!({"ok": true, "path": "/home/me/Pictures/Fjord lys.png"})
        );
        assert_eq!(title, "Velg et bilde");
        assert!(
            token.starts_with("foamy_lock_") && token.len() == 19,
            "{token}"
        );
        assert_eq!(
            matches,
            [format!(
                "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='/org/freedesktop/portal/desktop/request/1_42/{token}'"
            )]
        );
    }

    #[test]
    fn a_closed_dialog_is_cancelled() {
        let (result, _) = fake_bus("cancel", Portal::Cancel, DEFAULT_TITLE);
        assert_eq!(result.unwrap(), json!({"ok": true, "cancelled": true}));
    }

    #[test]
    fn a_portal_with_its_own_path_is_followed() {
        let (result, (_, _, matches)) = fake_bus("ownpath", Portal::OwnPath, DEFAULT_TITLE);
        assert_eq!(result.unwrap()["path"], "/home/me/Pictures/Fjord lys.png");
        assert_eq!(matches.len(), 2);
        assert!(matches[1].ends_with("path='/org/freedesktop/portal/desktop/request/1_42/other'"));
    }

    #[test]
    fn a_missing_portal_is_unavailable() {
        let (result, _) = fake_bus("missing", Portal::Missing, DEFAULT_TITLE);
        let failure = result.unwrap_err();
        assert_eq!(failure.code, "PORTAL_UNAVAILABLE");
        assert!(failure.message.contains("not activatable"), "{failure}");
    }

    #[test]
    fn no_bus_and_a_silent_bus_are_reported() {
        let scratch = Scratch::new("nobus");
        let missing = Address::Path(scratch.path("nothing"));
        let failure = pick_on(
            &missing,
            DEFAULT_TITLE,
            DEFAULT_FILTER,
            Instant::now() + Duration::from_secs(1),
        )
        .unwrap_err();
        assert_eq!(failure.code, "NO_SESSION_BUS");
        // A bus that accepts and never answers runs into the deadline.
        let listener = UnixListener::bind(scratch.path("silent")).unwrap();
        let started = Instant::now();
        let failure = pick_on(
            &Address::Path(scratch.path("silent")),
            DEFAULT_TITLE,
            DEFAULT_FILTER,
            Instant::now() + Duration::from_millis(200),
        )
        .unwrap_err();
        assert_eq!(failure.code, "PORTAL_FAILED");
        assert!(started.elapsed() < Duration::from_secs(2));
        drop(listener);
    }

    #[test]
    fn responses_parse_whatever_else_they_carry() {
        let mut body = Writer::new();
        body.u32(0);
        body.array(8, |w| {
            w.entry("current_filter", "(sa(us))", |w| {
                w.structure(|w| {
                    w.string("Images");
                    w.array(8, |w| {
                        w.structure(|w| {
                            w.u32(1);
                            w.string("image/png");
                        })
                    });
                })
            });
            w.entry("uris", "as", |w| {
                w.array(4, |w| {
                    w.string("file:///a.png");
                    w.string("file:///b.png");
                })
            });
        });
        let message = Message {
            kind: dbus::SIGNAL,
            serial: 1,
            ..Message::default()
        }
        .with_body("ua{sv}", body.buf);
        assert_eq!(
            parse_response(&message).unwrap(),
            (0, vec!["file:///a.png".into(), "file:///b.png".into()])
        );
        let wrong = Message {
            kind: dbus::SIGNAL,
            serial: 1,
            ..Message::default()
        }
        .with_body("u", vec![0; 4]);
        assert!(parse_response(&wrong).is_err());
    }
}
