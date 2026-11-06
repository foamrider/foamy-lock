//! The bounded HTTPS fetch of artwork.py (`fetch_https`): five seconds for
//! everything (DNS included), at most three hops, every hop re-resolved and
//! checked against the public-address policy, the TCP connection made to
//! the checked address and TLS verified against the host name, at most
//! `MAX_INPUT` bytes, identity encoding only. A minimal HTTP/1.1 client
//! (status line, headers, Content-Length, chunked or close-delimited
//! bodies) with Python `http.client`'s limits: 65536-byte lines and fewer
//! than 100 header lines.

use std::io::{self, BufRead, BufReader, ErrorKind, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use foamy_helper::net::{self, DeadlineStream};
use foamy_helper::tls::{self, TlsError, rustls};
use rustls::pki_types::ServerName;
use rustls::{ClientConfig, ClientConnection, StreamOwned};

use crate::url;
use crate::{Fail, MAX_INPUT};

const BUDGET: Duration = Duration::from_secs(5);
const MAX_LINE: usize = 65536;
const MAX_HEADERS: usize = 100;

/// Test-only DNS answers (see the contract in main.rs).
pub const TEST_RESOLVE: &str = "FOAMY_LOCK_TEST_RESOLVE";
/// Test-only connection endpoints (see the contract in main.rs).
pub const TEST_CONNECT: &str = "FOAMY_LOCK_TEST_CONNECT";

fn timeout() -> Fail {
    Fail("fetch-timeout")
}

/// Maps a transport error: the fetch deadline (`DeadlineExceeded`, or a
/// socket timeout, which is always armed to the time left) is
/// `fetch-timeout`, anything else a failed source.
fn transport(error: io::Error) -> Fail {
    if net::is_deadline(&error) {
        timeout()
    } else {
        Fail("source-unavailable")
    }
}

fn left(deadline: Instant) -> Result<Duration, Fail> {
    let now = Instant::now();
    if now >= deadline {
        return Err(timeout());
    }
    Ok(deadline - now)
}

fn in_v4(ip: Ipv4Addr, net: [u8; 4], prefix: u32) -> bool {
    let mask = if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    };
    u32::from(ip) & mask == u32::from(Ipv4Addr::from(net)) & mask
}

fn in_v6(ip: Ipv6Addr, net: &str, prefix: u32) -> bool {
    let net: Ipv6Addr = net.parse().expect("valid network");
    let mask = if prefix == 0 {
        0
    } else {
        u128::MAX << (128 - prefix)
    };
    u128::from(ip) & mask == u128::from(net) & mask
}

/// Python 3.14 `ipaddress`: `IPv4Address.is_private`.
fn v4_private(ip: Ipv4Addr) -> bool {
    const PRIVATE: &[([u8; 4], u32)] = &[
        ([0, 0, 0, 0], 8),
        ([10, 0, 0, 0], 8),
        ([127, 0, 0, 0], 8),
        ([169, 254, 0, 0], 16),
        ([172, 16, 0, 0], 12),
        ([192, 0, 0, 0], 24),
        ([192, 0, 0, 170], 31),
        ([192, 0, 2, 0], 24),
        ([192, 168, 0, 0], 16),
        ([198, 18, 0, 0], 15),
        ([198, 51, 100, 0], 24),
        ([203, 0, 113, 0], 24),
        ([240, 0, 0, 0], 4),
        ([255, 255, 255, 255], 32),
    ];
    const EXCEPTIONS: &[([u8; 4], u32)] = &[([192, 0, 0, 9], 32), ([192, 0, 0, 10], 32)];
    PRIVATE.iter().any(|&(net, p)| in_v4(ip, net, p))
        && !EXCEPTIONS.iter().any(|&(net, p)| in_v4(ip, net, p))
}

fn v4_public(ip: Ipv4Addr) -> bool {
    let global = !in_v4(ip, [100, 64, 0, 0], 10) && !v4_private(ip);
    global && !in_v4(ip, [224, 0, 0, 0], 4) && !ip.is_unspecified()
}

/// Python 3.14 `ipaddress`: `IPv6Address.is_private` (for addresses that
/// are not IPv4-mapped; those are refused before).
fn v6_private(ip: Ipv6Addr) -> bool {
    const PRIVATE: &[(&str, u32)] = &[
        ("::1", 128),
        ("::", 128),
        ("::ffff:0:0", 96),
        ("64:ff9b:1::", 48),
        ("100::", 64),
        ("2001::", 23),
        ("2001:db8::", 32),
        ("2002::", 16),
        ("3fff::", 20),
        ("fc00::", 7),
        ("fe80::", 10),
    ];
    const EXCEPTIONS: &[(&str, u32)] = &[
        ("2001:1::1", 128),
        ("2001:1::2", 128),
        ("2001:3::", 32),
        ("2001:4:112::", 48),
        ("2001:20::", 28),
        ("2001:30::", 28),
    ];
    PRIVATE.iter().any(|&(net, p)| in_v6(ip, net, p))
        && !EXCEPTIONS.iter().any(|&(net, p)| in_v6(ip, net, p))
}

fn v6_public(ip: Ipv6Addr) -> bool {
    let bits = u128::from(ip);
    let mapped = bits >> 32 == 0xffff;
    let sixtofour = bits >> 112 == 0x2002;
    let teredo = bits >> 96 == 0x2001_0000;
    !(mapped
        || sixtofour
        || teredo
        || in_v6(ip, "64:ff9b::", 96)
        || in_v6(ip, "ff00::", 8)
        || bits == 0
        || v6_private(ip))
}

/// artwork.py's `public_addresses` test for one address: globally reachable
/// (Python 3.14's `is_global`), not multicast or unspecified, not an
/// IPv4-mapped, 6to4, Teredo or NAT64 (64:ff9b::/96) address.
pub fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => v4_public(ip),
        IpAddr::V6(ip) => v6_public(ip),
    }
}

fn json_env(name: &str) -> Result<Option<serde_json::Map<String, serde_json::Value>>, Fail> {
    match std::env::var(name) {
        Ok(text) => match serde_json::from_str(&text) {
            Ok(serde_json::Value::Object(map)) => Ok(Some(map)),
            _ => Err(Fail("source-unavailable")),
        },
        Err(_) => Ok(None),
    }
}

/// The host's addresses for port 443, in resolver order without duplicates.
fn lookup(host: &str, deadline: Instant) -> Result<Vec<IpAddr>, Fail> {
    if let Some(table) = json_env(TEST_RESOLVE)? {
        let answers = table
            .get(host)
            .and_then(|v| v.as_array())
            .ok_or(Fail("source-unavailable"))?;
        return answers
            .iter()
            .map(|a| {
                a.as_str()
                    .and_then(|a| a.parse().ok())
                    .ok_or(Fail("source-unavailable"))
            })
            .collect();
    }
    // getaddrinfo cannot be interrupted, so it runs on its own thread and
    // the fetch stops waiting at the deadline.
    let (sender, receiver) = mpsc::channel();
    let name = host.to_string();
    thread::spawn(move || {
        let answer = (name.as_str(), 443)
            .to_socket_addrs()
            .map(|addresses| addresses.map(|a| a.ip()).collect::<Vec<_>>());
        let _ = sender.send(answer);
    });
    match receiver.recv_timeout(left(deadline)?) {
        Ok(Ok(addresses)) => Ok(addresses),
        Ok(Err(_)) => Err(Fail("source-unavailable")),
        Err(_) => Err(timeout()),
    }
}

/// artwork.py's `public_addresses(host)[0]`: every answer must be public.
fn checked_address(host: &str, deadline: Instant) -> Result<IpAddr, Fail> {
    let mut unique = Vec::new();
    for address in lookup(host, deadline)? {
        if !unique.contains(&address) {
            unique.push(address);
        }
    }
    if unique.is_empty() {
        return Err(Fail("dns-failed"));
    }
    if !unique.iter().all(|&address| is_public(address)) {
        return Err(Fail("non-public-address"));
    }
    Ok(unique[0])
}

/// Where a connection to the checked `address` goes: `address:443`, or in
/// tests the loopback endpoint `FOAMY_LOCK_TEST_CONNECT` maps it to.
fn endpoint(address: IpAddr) -> Result<SocketAddr, Fail> {
    match json_env(TEST_CONNECT)? {
        None => Ok(SocketAddr::new(address, 443)),
        Some(table) => {
            let target: SocketAddr = table
                .get(&address.to_string())
                .and_then(|v| v.as_str())
                .and_then(|v| v.parse().ok())
                .ok_or(Fail("source-unavailable"))?;
            if !target.ip().is_loopback() {
                return Err(Fail("source-unavailable"));
            }
            Ok(target)
        }
    }
}

/// TLS over TCP. The socket is a `DeadlineStream`: rustls may read the
/// socket many times for one record (a handshake flight, a body record
/// trickled byte by byte), and each of those reads and writes gets only
/// the time left, so the handshake, request, head and body of every hop
/// share the one fetch budget (artwork.py had an independent 5 s timer).
/// A TCP close without TLS close_notify reads as the end of the stream
/// (Python's `suppress_ragged_eofs`); the framing below decides whether
/// that is an error.
struct Transport {
    stream: StreamOwned<ClientConnection, DeadlineStream<TcpStream>>,
}

impl Read for Transport {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self.stream.read(buf) {
            Err(error) if error.kind() == ErrorKind::UnexpectedEof => Ok(0),
            other => other,
        }
    }
}

impl Write for Transport {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.stream.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.stream.flush()
    }
}

/// A response line: at most `MAX_LINE` bytes including its newline (Python
/// reads `MAX_LINE + 1` and refuses more than `MAX_LINE`). Empty at EOF.
fn read_line<R: BufRead>(reader: &mut R) -> Result<Vec<u8>, Fail> {
    let mut line = Vec::new();
    loop {
        let available = reader.fill_buf().map_err(transport)?;
        if available.is_empty() {
            return Ok(line);
        }
        let room = MAX_LINE + 1 - line.len();
        let take = available
            .iter()
            .take(room)
            .position(|&b| b == b'\n')
            .map(|i| i + 1);
        let count = take.unwrap_or(available.len().min(room));
        line.extend_from_slice(&available[..count]);
        reader.consume(count);
        if line.len() > MAX_LINE {
            return Err(Fail("source-unavailable"));
        }
        if take.is_some() {
            return Ok(line);
        }
    }
}

fn latin1(bytes: &[u8]) -> String {
    bytes.iter().map(|&b| b as char).collect()
}

fn python_space(c: char) -> bool {
    matches!(
        c,
        ' ' | '\t' | '\n' | '\r' | '\x0b' | '\x0c' | '\x1c'..='\x1f' | '\u{85}' | '\u{a0}'
    )
}

/// `http.client._read_headers`: lines up to the blank one, refusing more
/// than `MAX_HEADERS` lines (the blank line included).
fn read_header_lines<R: BufRead>(reader: &mut R) -> Result<Vec<String>, Fail> {
    let mut lines = Vec::new();
    loop {
        let line = read_line(reader)?;
        let end = line.is_empty() || line == b"\r\n" || line == b"\n";
        lines.push(latin1(&line));
        if lines.len() > MAX_HEADERS {
            return Err(Fail("source-unavailable"));
        }
        if end {
            lines.pop();
            return Ok(lines);
        }
    }
}

/// The headers as Python's `email` parser (policy compat32) sees them: a
/// header line is `name:value` with a name of printable ASCII other than
/// `:`; continuation lines are appended raw; the first line that is
/// neither ends the headers. Values keep trailing whitespace.
#[derive(Debug, Default)]
struct Headers(Vec<(String, String)>);

impl Headers {
    fn parse(lines: &[String]) -> Headers {
        let mut headers: Vec<(String, String)> = Vec::new();
        for line in lines {
            if line.starts_with([' ', '\t']) {
                if let Some(last) = headers.last_mut() {
                    last.1.push_str(line);
                }
                continue;
            }
            if line.starts_with("From ") {
                continue;
            }
            let Some((name, value)) = line.split_once(':') else {
                break;
            };
            if !name.chars().all(|c| ('\x21'..='\x7e').contains(&c)) {
                break;
            }
            headers.push((
                name.to_string(),
                value.trim_start_matches([' ', '\t']).to_string(),
            ));
        }
        for header in &mut headers {
            let trimmed = header.1.trim_end_matches(['\r', '\n']).len();
            header.1.truncate(trimmed);
        }
        Headers(headers)
    }

    fn all<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a str> + 'a {
        self.0
            .iter()
            .filter(move |(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    /// `headers.get(name)`: the first value.
    fn first<'a>(&'a self, name: &'a str) -> Option<&'a str> {
        self.all(name).next()
    }

    /// `HTTPResponse.getheader(name)`: every value joined with ", ".
    fn joined(&self, name: &str) -> Option<String> {
        let values: Vec<&str> = self.all(name).collect();
        (!values.is_empty()).then(|| values.join(", "))
    }
}

struct Head {
    status: u32,
    headers: Headers,
}

/// `http.client._read_status`: `Err` for a status line Python refuses.
fn read_status<R: BufRead>(reader: &mut R) -> Result<(String, u32), Fail> {
    let bad = || Fail("source-unavailable");
    let line = latin1(&read_line(reader)?);
    if line.is_empty() {
        return Err(bad());
    }
    let mut parts = line.split(python_space).filter(|p| !p.is_empty());
    let version = parts.next().unwrap_or("");
    let status = parts.next();
    if !version.starts_with("HTTP/") {
        return Err(bad());
    }
    let status = status.ok_or_else(bad)?;
    let digits = status.strip_prefix('+').unwrap_or(status);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) || digits.len() > 9 {
        return Err(bad());
    }
    let code: u32 = digits.parse().map_err(|_| bad())?;
    if !(100..=999).contains(&code) {
        return Err(bad());
    }
    Ok((version.to_string(), code))
}

fn read_head<R: BufRead>(reader: &mut R) -> Result<Head, Fail> {
    let (version, status) = loop {
        let (version, status) = read_status(reader)?;
        if status != 100 {
            break (version, status);
        }
        read_header_lines(reader)?;
    };
    if !(version == "HTTP/1.0" || version == "HTTP/0.9" || version.starts_with("HTTP/1.")) {
        return Err(Fail("source-unavailable"));
    }
    let headers = Headers::parse(&read_header_lines(reader)?);
    Ok(Head { status, headers })
}

/// Python's `str.isdigit()` for the ASCII text a length can have.
fn digits(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit())
}

/// Appends up to `MAX_INPUT + 1` bytes from `reader` (at most `want` when
/// given); returns how many were read before the end of the stream.
fn read_into<R: Read>(reader: &mut R, data: &mut Vec<u8>, want: Option<u64>) -> Result<u64, Fail> {
    let mut buffer = [0u8; 65536];
    let mut total = 0u64;
    loop {
        let room = (MAX_INPUT + 1).saturating_sub(data.len());
        if room == 0 {
            return Ok(total);
        }
        let mut size = buffer.len().min(room);
        if let Some(want) = want {
            if total >= want {
                return Ok(total);
            }
            size = size.min((want - total).min(usize::MAX as u64) as usize);
        }
        let read = reader.read(&mut buffer[..size]).map_err(transport)?;
        if read == 0 {
            return Ok(total);
        }
        data.extend_from_slice(&buffer[..read]);
        total += read as u64;
    }
}

/// The body of a 200 response, framed like `http.client`: chunked when the
/// first Transfer-Encoding is "chunked", else Content-Length, else until
/// the connection closes. Stops after `MAX_INPUT + 1` bytes.
fn read_body<R: BufRead>(
    reader: &mut R,
    headers: &Headers,
    length: Option<u64>,
) -> Result<Vec<u8>, Fail> {
    let incomplete = || Fail("source-unavailable");
    let mut data = Vec::new();
    let chunked = headers
        .first("transfer-encoding")
        .is_some_and(|v| v.eq_ignore_ascii_case("chunked"));
    if chunked {
        loop {
            if data.len() > MAX_INPUT {
                return Ok(data);
            }
            let line = latin1(&read_line(reader)?);
            let size = line
                .split(';')
                .next()
                .unwrap_or("")
                .trim_matches(python_space);
            let hex = size
                .strip_prefix("0x")
                .or_else(|| size.strip_prefix("0X"))
                .unwrap_or(size);
            if hex.is_empty() || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
                return Err(incomplete());
            }
            let significant = hex.trim_start_matches('0');
            // Python's int() has no upper bound: a huge size reads until the cap.
            let size = if significant.len() > 16 {
                u64::MAX
            } else {
                u64::from_str_radix(significant, 16).unwrap_or(0)
            };
            if size == 0 {
                // Trailer lines up to a blank line or the end of the stream.
                loop {
                    let trailer = read_line(reader)?;
                    if trailer.is_empty() || trailer == b"\r\n" || trailer == b"\n" {
                        return Ok(data);
                    }
                }
            }
            let before = data.len();
            let read = read_into(reader, &mut data, Some(size))?;
            if data.len() > MAX_INPUT {
                return Ok(data);
            }
            if read < size || data.len() - before < size as usize {
                return Err(incomplete());
            }
            let mut crlf = [0u8; 2];
            reader
                .read_exact(&mut crlf)
                .map_err(|error| match error.kind() {
                    ErrorKind::UnexpectedEof => incomplete(),
                    _ => transport(error),
                })?;
        }
    }
    match length {
        Some(length) => {
            let read = read_into(reader, &mut data, Some(length))?;
            if data.len() <= MAX_INPUT && read < length {
                // Shorter than announced: Python would pass the truncated
                // image on; refuse it.
                return Err(incomplete());
            }
            Ok(data)
        }
        None => {
            read_into(reader, &mut data, None)?;
            Ok(data)
        }
    }
}

fn connect(
    host: &str,
    address: IpAddr,
    deadline: Instant,
    config: &Arc<ClientConfig>,
) -> Result<Transport, Fail> {
    let target = endpoint(address)?;
    let socket = TcpStream::connect_timeout(&target, left(deadline)?).map_err(transport)?;
    let name = ServerName::try_from(host.to_string()).map_err(|_| Fail("source-unavailable"))?;
    let connection =
        ClientConnection::new(Arc::clone(config), name).map_err(|_| Fail("source-unavailable"))?;
    Ok(Transport {
        stream: StreamOwned::new(connection, DeadlineStream::new(socket, deadline)),
    })
}

fn request(target: &str, host: &str) -> Vec<u8> {
    format!(
        "GET {target} HTTP/1.1\r\nHost: {host}\r\nAccept: image/png,image/jpeg,image/webp\r\n\
         Accept-Encoding: identity\r\nUser-Agent: FoamyLock/1.0\r\nConnection: close\r\n\r\n"
    )
    .into_bytes()
}

fn tls_config() -> Result<Arc<ClientConfig>, Fail> {
    tls::client_config().map_err(|error| match error {
        TlsError::UnsupportedCpu => Fail("https-unsupported"),
        _ => Fail("source-unavailable"),
    })
}

/// artwork.py's `fetch_https(url, hosts)`.
pub fn fetch(start: &str, hosts: &[String]) -> Result<Vec<u8>, Fail> {
    let deadline = Instant::now() + BUDGET;
    let config = tls_config()?;
    let mut current = start.to_string();
    for hop in 0..3 {
        let parts = url::parse(&current)?;
        let host = match parts.hostname.as_deref() {
            Some(host) if parts.scheme() == "https" && hosts.iter().any(|h| h == host) => {
                host.to_string()
            }
            _ => return Err(Fail("host-not-allowed")),
        };
        let address = checked_address(&host, deadline)?;
        left(deadline)?;
        let mut reader =
            BufReader::with_capacity(65536, connect(&host, address, deadline, &config)?);
        reader
            .get_mut()
            .write_all(&request(&parts.target(), &host))
            .map_err(transport)?;
        reader.get_mut().flush().map_err(transport)?;
        let head = read_head(&mut reader)?;
        if matches!(head.status, 301 | 302 | 303 | 307 | 308) {
            let location = head.headers.joined("location").unwrap_or_default();
            if location.is_empty() || hop == 2 {
                return Err(Fail("redirect-limit"));
            }
            current = url::join(&current, &location).map_err(|_| Fail("source-unavailable"))?;
            continue;
        }
        if head.status != 200 {
            return Err(Fail("http-error"));
        }
        let encoding = head
            .headers
            .joined("content-encoding")
            .unwrap_or_else(|| "identity".to_string());
        if encoding.to_lowercase() != "identity" {
            return Err(Fail("encoded-response"));
        }
        let length = match head.headers.joined("content-length") {
            None => None,
            Some(value) => {
                if !digits(&value) {
                    return Err(Fail("input-too-large"));
                }
                match value.parse::<u64>() {
                    Ok(length) if length <= MAX_INPUT as u64 => Some(length),
                    _ => return Err(Fail("input-too-large")),
                }
            }
        };
        let data = read_body(&mut reader, &head.headers, length)?;
        if data.len() > MAX_INPUT {
            return Err(Fail("input-too-large"));
        }
        return Ok(data);
    }
    Err(Fail("redirect-limit"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn public(text: &str) -> bool {
        is_public(text.parse().unwrap())
    }

    #[test]
    fn address_policy_matches_python() {
        for refused in [
            "127.0.0.1",
            "10.0.0.1",
            "169.254.169.254",
            "0.0.0.0",
            "224.0.0.1",
            "::1",
            "fc00::1",
            "fe80::1",
            "::ffff:8.8.8.8",
            "2002:808:808::1",
            "64:ff9b::7f00:1",
            "100.64.0.1",
            "192.0.0.8",
            "192.0.0.170",
            "198.18.0.1",
            "240.0.0.1",
            "255.255.255.255",
            "2001:db8::1",
            "2001::1",
            "3fff::1",
            "ff02::1",
            "::",
            "100::1",
            "64:ff9b:1::1",
            "64:ff9b::8.8.8.8",
        ] {
            assert!(!public(refused), "{refused}");
        }
        for allowed in [
            "8.8.8.8",
            "1.1.1.1",
            "192.0.0.9",
            "192.0.0.10",
            "172.32.0.1",
            "192.88.99.1",
            "2606:4700::1111",
            "2001:200::1",
            "2001:4:112::1",
            "2001:20::1",
            "2001:30::1",
            "2001:3::1",
            "2001:1::1",
            "4000::1",
            "fec0::1",
            "::2",
            "::8.8.8.8",
            "64:ff9b::1:0:0",
        ] {
            assert!(public(allowed), "{allowed}");
        }
    }

    fn head(text: &str) -> Result<Head, Fail> {
        read_head(&mut Cursor::new(text.as_bytes().to_vec()))
    }

    #[test]
    fn heads_parse_like_http_client() {
        let parsed = head("HTTP/1.1 100 Continue\r\nX: y\r\n\r\nHTTP/1.0 302 Found\r\nLocation: /a\r\nLocation: /b\r\nX-Folded: a\r\n b\r\nContent-Encoding: gzip \r\n\r\n").unwrap();
        assert_eq!(parsed.status, 302);
        assert_eq!(parsed.headers.joined("LOCATION").as_deref(), Some("/a, /b"));
        assert_eq!(parsed.headers.first("x-folded"), Some("a\r\n b"));
        assert_eq!(parsed.headers.first("content-encoding"), Some("gzip "));
        assert_eq!(head("HTTP/1.1 103 Early\r\n\r\n").unwrap().status, 103);
        assert!(head("").is_err());
        assert!(head("ICY 200 OK\r\n\r\n").is_err());
        assert!(head("HTTP/1.1 99 Low\r\n\r\n").is_err());
        assert!(head("HTTP/2 200 OK\r\n\r\n").is_err());
        assert!(head("HTTP/1.1 2x0 OK\r\n\r\n").is_err());
        let stops = head("HTTP/1.1 200 OK\r\nA: 1\r\nnot a header\r\nB: 2\r\n\r\n").unwrap();
        assert_eq!(
            (stops.headers.first("a"), stops.headers.first("b")),
            (Some("1"), None)
        );
        let ninety_nine = format!("HTTP/1.1 200 OK\r\n{}\r\n", "A: 1\r\n".repeat(99));
        assert!(head(&ninety_nine).is_ok());
        let hundred = format!("HTTP/1.1 200 OK\r\n{}\r\n", "A: 1\r\n".repeat(100));
        assert!(head(&hundred).is_err());
        let long = format!("HTTP/1.1 200 OK\r\nA: {}\r\n\r\n", "x".repeat(MAX_LINE));
        assert!(head(&long).is_err());
    }

    fn body(text: &[u8], headers: &str, length: Option<u64>) -> Result<Vec<u8>, Fail> {
        let parsed = Headers::parse(&headers.lines().map(|l| l.to_string()).collect::<Vec<_>>());
        read_body(&mut Cursor::new(text.to_vec()), &parsed, length)
    }

    #[test]
    fn bodies_are_framed_and_bounded() {
        assert_eq!(body(b"hello world", "", Some(5)).unwrap(), b"hello");
        assert!(
            body(b"hell", "", Some(5)).is_err(),
            "shorter than Content-Length"
        );
        assert_eq!(body(b"until close", "", None).unwrap(), b"until close");
        let chunked = "Transfer-Encoding: chunked";
        assert_eq!(
            body(
                b"5;x=1\r\nhello\r\n0x6\r\n world\r\n0\r\nT: 1\r\n\r\nignored",
                chunked,
                Some(1)
            )
            .unwrap(),
            b"hello world"
        );
        assert_eq!(body(b"3\r\nabc\r\n0\r\n", chunked, None).unwrap(), b"abc");
        assert!(body(b"5\r\nabc", chunked, None).is_err());
        assert!(body(b"zz\r\nabc\r\n", chunked, None).is_err());
        assert!(body(b"", chunked, None).is_err());
        let big = vec![b'x'; MAX_INPUT + 10];
        assert_eq!(body(&big, "", None).unwrap().len(), MAX_INPUT + 1);
        let mut chunks = format!("{:x}\r\n", MAX_INPUT + 10).into_bytes();
        chunks.extend_from_slice(&big);
        assert_eq!(body(&chunks, chunked, None).unwrap().len(), MAX_INPUT + 1);
    }

    #[test]
    fn a_passed_deadline_is_a_fetch_timeout_wherever_it_surfaces() {
        use std::net::{TcpListener, TcpStream};
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let socket = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let mut stream = DeadlineStream::new(socket, Instant::now());
        let error = stream.read(&mut [0u8; 1]).unwrap_err();
        assert_eq!(transport(error), timeout());
        // As a TLS or HTTP layer would wrap it.
        let error = stream.write(b"x").unwrap_err();
        assert_eq!(transport(io::Error::other(error)), timeout());
        assert_eq!(
            transport(io::Error::from(ErrorKind::ConnectionReset)),
            Fail("source-unavailable")
        );
    }

    #[test]
    fn requests_are_minimal() {
        assert_eq!(
            String::from_utf8(request("/a?b", "images.example.com")).unwrap(),
            "GET /a?b HTTP/1.1\r\nHost: images.example.com\r\nAccept: image/png,image/jpeg,image/webp\r\n\
             Accept-Encoding: identity\r\nUser-Agent: FoamyLock/1.0\r\nConnection: close\r\n\r\n"
        );
    }
}
