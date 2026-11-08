//! A minimal D-Bus client, enough for one portal call: a Unix socket to the
//! session bus, `EXTERNAL` authentication, the message format (little
//! endian out, either endianness in), method calls, replies and signals.
//! No unix fd passing, no introspection, no async runtime. Every read and
//! write is bounded by one deadline and every message by `MAX_MESSAGE`.

use std::io::{self, ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Instant;

pub const METHOD_CALL: u8 = 1;
pub const METHOD_RETURN: u8 = 2;
pub const ERROR: u8 = 3;
pub const SIGNAL: u8 = 4;
/// Far above anything the portal sends (the spec allows 128 MiB).
pub const MAX_MESSAGE: usize = 1 << 20;
const MAX_DEPTH: usize = 32;
const MAX_LINE: usize = 1024;

#[derive(Debug)]
pub enum Error {
    /// No usable bus address, or nobody listening there.
    NoBus(String),
    Io(io::Error),
    Timeout,
    Protocol(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::NoBus(text) => write!(f, "no session bus: {text}"),
            Error::Io(error) => write!(f, "{error}"),
            Error::Timeout => write!(f, "timed out"),
            Error::Protocol(text) => write!(f, "D-Bus protocol error: {text}"),
        }
    }
}

fn protocol<T>(text: impl Into<String>) -> Result<T, Error> {
    Err(Error::Protocol(text.into()))
}

/// Body and header encoding, little endian. Offsets count from the start
/// of the buffer, which must start 8-aligned in the message.
#[derive(Debug, Default)]
pub struct Writer {
    pub buf: Vec<u8>,
}

impl Writer {
    pub fn new() -> Writer {
        Writer::default()
    }

    pub fn pad(&mut self, align: usize) {
        while !self.buf.len().is_multiple_of(align) {
            self.buf.push(0);
        }
    }

    pub fn byte(&mut self, value: u8) {
        self.buf.push(value);
    }

    pub fn u32(&mut self, value: u32) {
        self.pad(4);
        self.buf.extend_from_slice(&value.to_le_bytes());
    }

    pub fn boolean(&mut self, value: bool) {
        self.u32(u32::from(value));
    }

    /// `s` and `o`.
    pub fn string(&mut self, text: &str) {
        self.u32(text.len() as u32);
        self.buf.extend_from_slice(text.as_bytes());
        self.buf.push(0);
    }

    pub fn signature(&mut self, text: &str) {
        self.byte(text.len() as u8);
        self.buf.extend_from_slice(text.as_bytes());
        self.buf.push(0);
    }

    /// An array whose elements align to `element_align`.
    pub fn array(&mut self, element_align: usize, elements: impl FnOnce(&mut Writer)) {
        self.pad(4);
        let at = self.buf.len();
        self.buf.extend_from_slice(&[0; 4]);
        self.pad(element_align);
        let start = self.buf.len();
        elements(self);
        let length = (self.buf.len() - start) as u32;
        self.buf[at..at + 4].copy_from_slice(&length.to_le_bytes());
    }

    /// A struct or dict entry.
    pub fn structure(&mut self, fields: impl FnOnce(&mut Writer)) {
        self.pad(8);
        fields(self);
    }

    /// A `{sv}` dict entry with a value of signature `signature`.
    pub fn entry(&mut self, key: &str, signature: &str, value: impl FnOnce(&mut Writer)) {
        self.structure(|w| {
            w.string(key);
            w.signature(signature);
            value(w);
        });
    }
}

/// The first complete type of `signature`, and the rest.
pub fn split_type(signature: &str) -> Result<(&str, &str), Error> {
    let bytes = signature.as_bytes();
    let mut depth = 0usize;
    let mut end = 0;
    loop {
        let Some(&c) = bytes.get(end) else {
            return protocol(format!("incomplete signature {signature:?}"));
        };
        end += 1;
        match c {
            b'a' => continue,
            b'(' | b'{' => depth += 1,
            b')' | b'}' => {
                if depth == 0 {
                    return protocol(format!("unbalanced signature {signature:?}"));
                }
                depth -= 1;
            }
            b'y' | b'b' | b'n' | b'q' | b'i' | b'u' | b'x' | b't' | b'd' | b'h' | b's' | b'o'
            | b'g' | b'v' => {}
            _ => return protocol(format!("unknown type in signature {signature:?}")),
        }
        if depth == 0 {
            return Ok((&signature[..end], &signature[end..]));
        }
    }
}

fn alignment(code: u8) -> usize {
    match code {
        b'n' | b'q' => 2,
        b'b' | b'i' | b'u' | b'h' | b's' | b'o' | b'a' => 4,
        b'x' | b't' | b'd' | b'(' | b'{' => 8,
        _ => 1,
    }
}

/// Decoding from a buffer that starts 8-aligned in its message.
pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
    big_endian: bool,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8], big_endian: bool) -> Reader<'a> {
        Reader {
            data,
            pos: 0,
            big_endian,
        }
    }

    fn take(&mut self, count: usize) -> Result<&'a [u8], Error> {
        let end = self
            .pos
            .checked_add(count)
            .filter(|&end| end <= self.data.len());
        let Some(end) = end else {
            return protocol("message ends early");
        };
        let bytes = &self.data[self.pos..end];
        self.pos = end;
        Ok(bytes)
    }

    pub fn align(&mut self, align: usize) -> Result<(), Error> {
        let padding = (align - self.pos % align) % align;
        self.take(padding).map(drop)
    }

    pub fn byte(&mut self) -> Result<u8, Error> {
        Ok(self.take(1)?[0])
    }

    pub fn u32(&mut self) -> Result<u32, Error> {
        self.align(4)?;
        let bytes: [u8; 4] = self.take(4)?.try_into().unwrap_or_default();
        Ok(if self.big_endian {
            u32::from_be_bytes(bytes)
        } else {
            u32::from_le_bytes(bytes)
        })
    }

    fn text(&mut self, length: usize) -> Result<&'a str, Error> {
        let bytes = self.take(length + 1)?;
        if bytes[length] != 0 {
            return protocol("a string isn't NUL-terminated");
        }
        std::str::from_utf8(&bytes[..length]).or_else(|_| protocol("a string isn't UTF-8"))
    }

    /// `s` and `o`.
    pub fn string(&mut self) -> Result<&'a str, Error> {
        let length = self.u32()? as usize;
        self.text(length)
    }

    pub fn signature(&mut self) -> Result<&'a str, Error> {
        let length = self.byte()? as usize;
        self.text(length)
    }

    /// Calls `element` once per element of an array of `element_align`.
    pub fn array(
        &mut self,
        element_align: usize,
        mut element: impl FnMut(&mut Reader<'a>) -> Result<(), Error>,
    ) -> Result<(), Error> {
        let length = self.u32()? as usize;
        self.align(element_align)?;
        let end = self
            .pos
            .checked_add(length)
            .filter(|&end| end <= self.data.len());
        let Some(end) = end else {
            return protocol("an array runs past the message");
        };
        while self.pos < end {
            element(self)?;
        }
        if self.pos != end {
            return protocol("an array element runs past its array");
        }
        Ok(())
    }

    /// Skips one value of the complete type `signature`.
    pub fn skip(&mut self, signature: &str) -> Result<(), Error> {
        match split_type(signature)? {
            (single, "") => self.skip_at(single, 0),
            _ => protocol(format!("{signature:?} isn't one complete type")),
        }
    }

    fn skip_at(&mut self, signature: &str, depth: usize) -> Result<(), Error> {
        if depth > MAX_DEPTH {
            return protocol("values nest too deeply");
        }
        let code = *signature.as_bytes().first().unwrap_or(&0);
        match code {
            b'y' => self.take(1).map(drop),
            b'n' | b'q' => self.align(2).and_then(|()| self.take(2).map(drop)),
            b'b' | b'i' | b'u' | b'h' => self.u32().map(drop),
            b'x' | b't' | b'd' => self.align(8).and_then(|()| self.take(8).map(drop)),
            b's' | b'o' => self.string().map(drop),
            b'g' => self.signature().map(drop),
            b'v' => {
                let inner = self.signature()?;
                let (single, rest) = split_type(inner)?;
                if !rest.is_empty() {
                    return protocol("a variant holds more than one type");
                }
                self.skip_at(single, depth + 1)
            }
            b'a' => {
                let element = &signature[1..];
                let align = alignment(*element.as_bytes().first().unwrap_or(&0));
                self.array(align, |r| r.skip_at(element, depth + 1))
            }
            b'(' | b'{' => {
                self.align(8)?;
                let mut inner = &signature[1..signature.len() - 1];
                while !inner.is_empty() {
                    let (single, rest) = split_type(inner)?;
                    self.skip_at(single, depth + 1)?;
                    inner = rest;
                }
                Ok(())
            }
            _ => protocol(format!("can't read type {signature:?}")),
        }
    }
}

/// One message, either way.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Message {
    pub kind: u8,
    pub flags: u8,
    pub serial: u32,
    pub path: Option<String>,
    pub interface: Option<String>,
    pub member: Option<String>,
    pub error_name: Option<String>,
    pub reply_serial: Option<u32>,
    pub destination: Option<String>,
    pub sender: Option<String>,
    pub signature: String,
    pub body: Vec<u8>,
    pub big_endian: bool,
}

/// The total length of a message from its first 16 bytes.
pub fn message_length(head: &[u8]) -> Result<usize, Error> {
    if head.len() < 16 {
        return protocol("short header");
    }
    let mut reader = Reader::new(
        head,
        match head[0] {
            b'l' => false,
            b'B' => true,
            _ => return protocol("unknown byte order"),
        },
    );
    reader.take(4)?;
    let body = reader.u32()? as usize;
    reader.u32()?;
    let fields = reader.u32()? as usize;
    let header = (16usize.saturating_add(fields))
        .div_ceil(8)
        .saturating_mul(8);
    let total = header.saturating_add(body);
    if total > MAX_MESSAGE {
        return protocol(format!("a message of {total} bytes is too large"));
    }
    Ok(total)
}

impl Message {
    pub fn call(destination: &str, path: &str, interface: &str, member: &str) -> Message {
        Message {
            kind: METHOD_CALL,
            path: Some(path.into()),
            interface: Some(interface.into()),
            member: Some(member.into()),
            destination: Some(destination.into()),
            ..Message::default()
        }
    }

    pub fn with_body(mut self, signature: &str, body: Vec<u8>) -> Message {
        self.signature = signature.into();
        self.body = body;
        self
    }

    /// The wire form (little endian).
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        w.byte(b'l');
        w.byte(self.kind);
        w.byte(self.flags);
        w.byte(1);
        w.u32(self.body.len() as u32);
        w.u32(self.serial);
        w.array(8, |w| {
            let mut text = |code: u8, signature: &str, value: &Option<String>| {
                if let Some(value) = value {
                    w.structure(|w| {
                        w.byte(code);
                        w.signature(signature);
                        if signature == "g" {
                            w.signature(value);
                        } else {
                            w.string(value);
                        }
                    });
                }
            };
            text(1, "o", &self.path);
            text(2, "s", &self.interface);
            text(3, "s", &self.member);
            text(4, "s", &self.error_name);
            text(6, "s", &self.destination);
            text(7, "s", &self.sender);
            if !self.signature.is_empty() {
                text(8, "g", &Some(self.signature.clone()));
            }
            if let Some(serial) = self.reply_serial {
                w.structure(|w| {
                    w.byte(5);
                    w.signature("u");
                    w.u32(serial);
                });
            }
        });
        w.pad(8);
        w.buf.extend_from_slice(&self.body);
        w.buf
    }

    /// Parses one whole message (`message_length` bytes).
    pub fn decode(data: &[u8]) -> Result<Message, Error> {
        let total = message_length(data)?;
        if data.len() != total {
            return protocol("message length mismatch");
        }
        let big_endian = data[0] == b'B';
        let mut r = Reader::new(data, big_endian);
        r.take(1)?;
        let mut message = Message {
            kind: r.byte()?,
            flags: r.byte()?,
            big_endian,
            ..Message::default()
        };
        if r.byte()? != 1 {
            return protocol("unknown protocol version");
        }
        let body_length = r.u32()? as usize;
        message.serial = r.u32()?;
        r.array(8, |r| {
            r.align(8)?;
            let code = r.byte()?;
            let signature = r.signature()?;
            let expected = match code {
                1 => "o",
                2 | 3 | 4 | 6 | 7 => "s",
                5 | 9 => "u",
                8 => "g",
                _ => {
                    let (single, _) = split_type(signature)?;
                    return r.skip(single);
                }
            };
            if signature != expected {
                return protocol(format!("header field {code} has type {signature:?}"));
            }
            match code {
                5 => message.reply_serial = Some(r.u32()?),
                9 => {
                    r.u32()?;
                }
                8 => message.signature = r.signature()?.to_string(),
                _ => {
                    let value = Some(r.string()?.to_string());
                    match code {
                        1 => message.path = value,
                        2 => message.interface = value,
                        3 => message.member = value,
                        4 => message.error_name = value,
                        6 => message.destination = value,
                        _ => message.sender = value,
                    }
                }
            }
            Ok(())
        })?;
        r.align(8)?;
        message.body = r.take(body_length)?.to_vec();
        if message.serial == 0 || !(1..=4).contains(&message.kind) {
            return protocol("invalid message header");
        }
        Ok(message)
    }

    pub fn reader(&self) -> Reader<'_> {
        Reader::new(&self.body, self.big_endian)
    }

    /// The first string of the body, if it has one (an error's message).
    pub fn first_string(&self) -> Option<String> {
        if !self.signature.starts_with('s') {
            return None;
        }
        self.reader().string().ok().map(str::to_string)
    }
}

/// A bus address's socket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Address {
    Path(PathBuf),
    Abstract(Vec<u8>),
}

fn unescape(value: &str) -> Option<Vec<u8>> {
    let bytes = value.as_bytes();
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
    Some(out)
}

/// The first `unix:` address with `path=` or `abstract=` in a bus address
/// list (`DBUS_SESSION_BUS_ADDRESS`).
pub fn parse_address(list: &str) -> Option<Address> {
    use std::os::unix::ffi::OsStringExt;
    for address in list.split(';') {
        let Some(params) = address.strip_prefix("unix:") else {
            continue;
        };
        for param in params.split(',') {
            let Some((key, value)) = param.split_once('=') else {
                continue;
            };
            let Some(value) = unescape(value).filter(|v| !v.is_empty()) else {
                continue;
            };
            match key {
                "path" => return Some(Address::Path(std::ffi::OsString::from_vec(value).into())),
                "abstract" => return Some(Address::Abstract(value)),
                _ => {}
            }
        }
    }
    None
}

/// A buffered, deadline-bounded socket.
pub struct Wire {
    stream: UnixStream,
    buf: Vec<u8>,
    deadline: Instant,
}

impl Wire {
    pub fn new(stream: UnixStream, deadline: Instant) -> Wire {
        Wire {
            stream,
            buf: Vec::new(),
            deadline,
        }
    }

    fn left(&self) -> Result<std::time::Duration, Error> {
        let left = self.deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(Error::Timeout);
        }
        Ok(left)
    }

    fn fill(&mut self) -> Result<(), Error> {
        let mut chunk = [0u8; 8192];
        loop {
            self.stream
                .set_read_timeout(Some(self.left()?))
                .map_err(Error::Io)?;
            match self.stream.read(&mut chunk) {
                Ok(0) => {
                    return Err(Error::Io(io::Error::new(
                        ErrorKind::UnexpectedEof,
                        "the bus hung up",
                    )));
                }
                Ok(read) => {
                    self.buf.extend_from_slice(&chunk[..read]);
                    return Ok(());
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(error)
                    if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
                {
                    return Err(Error::Timeout);
                }
                Err(error) => return Err(Error::Io(error)),
            }
        }
    }

    pub fn write(&mut self, bytes: &[u8]) -> Result<(), Error> {
        self.stream
            .set_write_timeout(Some(self.left()?))
            .map_err(Error::Io)?;
        self.stream
            .write_all(bytes)
            .map_err(|error| match error.kind() {
                ErrorKind::WouldBlock | ErrorKind::TimedOut => Error::Timeout,
                _ => Error::Io(error),
            })
    }

    pub fn read_exact(&mut self, count: usize) -> Result<Vec<u8>, Error> {
        while self.buf.len() < count {
            self.fill()?;
        }
        Ok(self.buf.drain(..count).collect())
    }

    /// One authentication line, without its `\r\n`.
    pub fn read_line(&mut self) -> Result<String, Error> {
        loop {
            if let Some(end) = self.buf.windows(2).position(|pair| pair == b"\r\n") {
                let line: Vec<u8> = self.buf.drain(..end + 2).take(end).collect();
                return String::from_utf8(line).or_else(|_| protocol("an auth line isn't UTF-8"));
            }
            if self.buf.len() > MAX_LINE {
                return protocol("an auth line is too long");
            }
            self.fill()?;
        }
    }

    pub fn read_message(&mut self) -> Result<Message, Error> {
        while self.buf.len() < 16 {
            self.fill()?;
        }
        let total = message_length(&self.buf[..16])?;
        let bytes = self.read_exact(total)?;
        Message::decode(&bytes)
    }
}

/// A connection to a bus, after `Hello`.
pub struct Connection {
    wire: Wire,
    serial: u32,
    pub unique_name: String,
}

fn hex(text: &str) -> String {
    text.bytes().map(|b| format!("{b:02x}")).collect()
}

impl Connection {
    pub fn open(address: &Address, deadline: Instant) -> Result<Connection, Error> {
        let stream = match address {
            Address::Path(path) => UnixStream::connect(path),
            Address::Abstract(name) => {
                use std::os::linux::net::SocketAddrExt;
                std::os::unix::net::SocketAddr::from_abstract_name(name)
                    .and_then(|addr| UnixStream::connect_addr(&addr))
            }
        }
        .map_err(|error| Error::NoBus(format!("cannot connect: {error}")))?;
        let mut wire = Wire::new(stream, deadline);
        let uid = rustix::process::getuid().as_raw().to_string();
        wire.write(format!("\0AUTH EXTERNAL {}\r\n", hex(&uid)).as_bytes())?;
        let answer = wire.read_line()?;
        if !answer.starts_with("OK ") {
            return Err(Error::NoBus(format!("the bus refused us: {answer}")));
        }
        wire.write(b"BEGIN\r\n")?;
        let mut connection = Connection {
            wire,
            serial: 0,
            unique_name: String::new(),
        };
        let hello = connection.send(Message::call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "Hello",
        ))?;
        loop {
            let reply = connection.read()?;
            if reply.reply_serial != Some(hello) {
                continue;
            }
            if reply.kind != METHOD_RETURN || reply.signature != "s" {
                return Err(Error::NoBus("Hello failed".into()));
            }
            connection.unique_name = reply.reader().string()?.to_string();
            return Ok(connection);
        }
    }

    /// Sends `message` with the next serial; returns the serial.
    pub fn send(&mut self, mut message: Message) -> Result<u32, Error> {
        self.serial += 1;
        message.serial = self.serial;
        self.wire.write(&message.encode())?;
        Ok(self.serial)
    }

    pub fn read(&mut self) -> Result<Message, Error> {
        self.wire.read_message()
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;

    #[test]
    fn signatures_split_into_complete_types() {
        assert_eq!(split_type("ssa{sv}").unwrap(), ("s", "sa{sv}"));
        assert_eq!(split_type("a{sv}").unwrap(), ("a{sv}", ""));
        assert_eq!(split_type("a(sa(us))u").unwrap(), ("a(sa(us))", "u"));
        assert_eq!(split_type("aay").unwrap(), ("aay", ""));
        for bad in ["", "a", "(s", ")", "z", "a{sv"] {
            assert!(split_type(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn messages_round_trip() {
        let mut body = Writer::new();
        body.string("hello");
        body.array(8, |w| {
            w.entry("n", "u", |w| w.u32(7));
            w.entry("flag", "b", |w| w.boolean(true));
        });
        let mut message = Message::call("org.example", "/org/example", "org.example.I", "Do")
            .with_body("sa{sv}", body.buf);
        message.serial = 9;
        message.reply_serial = Some(3);
        message.sender = Some(":1.5".into());
        let bytes = message.encode();
        assert_eq!(bytes.len(), message_length(&bytes[..16]).unwrap());
        let decoded = Message::decode(&bytes).unwrap();
        assert_eq!(decoded, message);
        let mut r = decoded.reader();
        assert_eq!(r.string().unwrap(), "hello");
        let mut seen = Vec::new();
        r.array(8, |r| {
            r.align(8)?;
            let key = r.string()?.to_string();
            let signature = r.signature()?.to_string();
            let value = r.u32()?;
            seen.push((key, signature, value));
            Ok(())
        })
        .unwrap();
        assert_eq!(
            seen,
            [("n".into(), "u".into(), 7), ("flag".into(), "b".into(), 1)]
        );
    }

    #[test]
    fn hello_matches_the_reference_bytes() {
        // The Hello every libdbus client starts with (serial 1).
        let mut hello = Message::call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "Hello",
        );
        hello.serial = 1;
        let bytes = hello.encode();
        assert_eq!(
            &bytes[..16],
            b"l\x01\x00\x01\x00\x00\x00\x00\x01\x00\x00\x00\x6d\x00\x00\x00"
        );
        assert_eq!(&bytes[16..24], b"\x01\x01o\x00\x15\x00\x00\x00");
        assert_eq!(bytes.len(), 128);
    }

    #[test]
    fn big_endian_messages_decode() {
        // A signal with only a path and a u32 body, built by hand.
        let mut bytes = vec![b'B', SIGNAL, 0, 1, 0, 0, 0, 4, 0, 0, 0, 2];
        let fields: [u8; 23] = [
            1, 1, b'o', 0, 0, 0, 0, 2, b'/', b'x', 0, 0, 0, 0, 0, 0, // path "/x", padded
            8, 1, b'g', 0, 1, b'u', 0, // signature "u"
        ];
        bytes.extend_from_slice(&(fields.len() as u32).to_be_bytes());
        bytes.extend_from_slice(&fields);
        bytes.push(0); // the header ends 8-aligned
        bytes.extend_from_slice(&42u32.to_be_bytes());
        let message = Message::decode(&bytes).unwrap();
        assert_eq!((message.kind, message.serial), (SIGNAL, 2));
        assert_eq!(message.path.as_deref(), Some("/x"));
        assert_eq!(message.signature, "u");
        assert_eq!(message.reader().u32().unwrap(), 42);
    }

    #[test]
    fn values_are_skipped_by_signature() {
        let mut w = Writer::new();
        w.byte(1);
        w.array(8, |w| {
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
        w.signature("as");
        w.array(4, |w| w.string("x"));
        w.u32(99);
        let mut r = Reader::new(&w.buf, false);
        r.skip("y").unwrap();
        r.skip("a(sa(us))").unwrap();
        r.skip("v").unwrap();
        assert_eq!(r.u32().unwrap(), 99);
        // Truncation and runaway arrays are errors, not panics.
        for cut in 0..w.buf.len() {
            let mut r = Reader::new(&w.buf[..cut], false);
            let _ = r
                .skip("y")
                .and_then(|()| r.skip("a(sa(us))"))
                .and_then(|()| r.skip("v"));
        }
        let mut huge = Writer::new();
        huge.u32(u32::MAX);
        assert!(Reader::new(&huge.buf, false).skip("ay").is_err());
        // Variants inside variants stop at the depth limit.
        let mut deep = Writer::new();
        for _ in 0..40 {
            deep.signature("v");
        }
        deep.signature("y");
        deep.byte(0);
        assert!(Reader::new(&deep.buf, false).skip("v").is_err());
    }

    #[test]
    fn oversized_and_odd_messages_are_refused() {
        let mut head = vec![b'l', 1, 0, 1];
        head.extend_from_slice(&(MAX_MESSAGE as u32).to_le_bytes());
        head.extend_from_slice(&[1, 0, 0, 0, 0, 0, 0, 0]);
        assert!(message_length(&head).is_err());
        head[0] = b'x';
        assert!(message_length(&head).is_err());
        assert!(message_length(&head[..8]).is_err());
    }

    #[test]
    fn bus_addresses_parse() {
        assert_eq!(
            parse_address("unix:path=/run/user/1000/bus"),
            Some(Address::Path("/run/user/1000/bus".into()))
        );
        assert_eq!(
            parse_address("tcp:host=x,port=1;unix:guid=abc,path=/tmp/a%20b"),
            Some(Address::Path("/tmp/a b".into()))
        );
        assert_eq!(
            parse_address("unix:abstract=/tmp/dbus-XYZ,guid=1"),
            Some(Address::Abstract(b"/tmp/dbus-XYZ".to_vec()))
        );
        for bad in [
            "",
            "tcp:host=x",
            "unix:tmpdir=/tmp",
            "unix:path=",
            "unix:path=%zz",
        ] {
            assert_eq!(parse_address(bad), None, "{bad:?}");
        }
    }
}
