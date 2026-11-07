//! URL handling, carried over from artwork.py's use of Python 3.14's
//! `urllib.parse` (`urlsplit`, `urljoin`, `unquote`) and `os.path.normpath`,
//! so the same requests are accepted and refused with the same codes.

use crate::Fail;

/// `urlsplit` with `None` for components that were absent (as `_urlsplit`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Split {
    pub scheme: Option<String>,
    pub netloc: Option<String>,
    pub path: String,
    pub query: Option<String>,
    pub fragment: Option<String>,
}

const SCHEME_CHARS: &str = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.";

/// Python's `_urlsplit(url, None, True)`. `Err` where Python raises
/// `ValueError` (unbalanced or invalid brackets).
pub fn split(url: &str) -> Result<Split, ()> {
    let mut url: String = url
        .trim_start_matches(|c: char| c <= ' ')
        .chars()
        .filter(|&c| c != '\t' && c != '\r' && c != '\n')
        .collect();
    let mut scheme = None;
    if let Some(i) = url.find(':') {
        let first = url.chars().next().unwrap_or(' ');
        if i > 0
            && first.is_ascii_alphabetic()
            && url[..i].chars().all(|c| SCHEME_CHARS.contains(c))
        {
            scheme = Some(url[..i].to_ascii_lowercase());
            url = url[i + 1..].to_string();
        }
    }
    let mut netloc = None;
    if url.starts_with("//") {
        let end = url[2..].find(['/', '?', '#']).map_or(url.len(), |i| i + 2);
        let host = url[2..end].to_string();
        url = url[end..].to_string();
        let (open, close) = (host.contains('['), host.contains(']'));
        if open != close {
            return Err(());
        }
        if open && close {
            check_bracketed_netloc(&host)?;
        }
        netloc = Some(host);
    }
    let mut fragment = None;
    if let Some(i) = url.find('#') {
        fragment = Some(url[i + 1..].to_string());
        url.truncate(i);
    }
    let mut query = None;
    if let Some(i) = url.find('?') {
        query = Some(url[i + 1..].to_string());
        url.truncate(i);
    }
    Ok(Split {
        scheme,
        netloc,
        path: url,
        query,
        fragment,
    })
}

fn check_bracketed_netloc(netloc: &str) -> Result<(), ()> {
    let host_and_port = netloc.rsplit_once('@').map_or(netloc, |(_, rest)| rest);
    let hostname = match host_and_port.split_once('[') {
        Some((before, bracketed)) => {
            if !before.is_empty() {
                return Err(());
            }
            let (hostname, port) = bracketed.split_once(']').unwrap_or((bracketed, ""));
            if !port.is_empty() && !port.starts_with(':') {
                return Err(());
            }
            hostname
        }
        None => host_and_port
            .split_once(':')
            .map_or(host_and_port, |(h, _)| h),
    };
    // RFC 3986 IPvFuture, or an IPv6 address (an IPv4 address is refused).
    if let Some(rest) = hostname.strip_prefix(['v', 'V']) {
        let (hex, tail) = rest.split_once('.').ok_or(())?;
        if hex.is_empty() || !hex.chars().all(|c| c.is_ascii_hexdigit()) || tail.is_empty() {
            return Err(());
        }
        return Ok(());
    }
    let address = hostname.split_once('%').map_or(hostname, |(a, _)| a);
    address
        .parse::<std::net::Ipv6Addr>()
        .map(|_| ())
        .map_err(|_| ())
}

impl Split {
    /// `_hostinfo`: the host (not lowercased) and the port text.
    fn hostinfo(&self) -> (String, Option<String>) {
        let netloc = self.netloc.as_deref().unwrap_or("");
        let hostinfo = netloc.rsplit_once('@').map_or(netloc, |(_, rest)| rest);
        let (hostname, port) = match hostinfo.split_once('[') {
            Some((_, bracketed)) => {
                let (hostname, rest) = bracketed.split_once(']').unwrap_or((bracketed, ""));
                (hostname, rest.split_once(':').map_or("", |(_, p)| p))
            }
            None => hostinfo.split_once(':').unwrap_or((hostinfo, "")),
        };
        (
            hostname.to_string(),
            (!port.is_empty()).then(|| port.to_string()),
        )
    }

    /// `SplitResult.hostname`: lowercased (not a zone after `%`), `None` when empty.
    pub fn hostname(&self) -> Option<String> {
        let (hostname, _) = self.hostinfo();
        if hostname.is_empty() {
            return None;
        }
        Some(match hostname.split_once('%') {
            Some((host, zone)) => format!("{}%{zone}", host.to_lowercase()),
            None => hostname.to_lowercase(),
        })
    }

    /// `SplitResult.port`; `Err` where Python raises `ValueError`.
    pub fn port(&self) -> Result<Option<u32>, ()> {
        match self.hostinfo().1 {
            None => Ok(None),
            Some(port) if !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) => {
                let digits = port.trim_start_matches('0');
                if digits.len() > 5 {
                    return Err(());
                }
                let value: u32 = if digits.is_empty() {
                    0
                } else {
                    digits.parse().map_err(|_| ())?
                };
                if value > 65535 {
                    Err(())
                } else {
                    Ok(Some(value))
                }
            }
            Some(_) => Err(()),
        }
    }

    fn has_userinfo(&self) -> bool {
        self.netloc
            .as_deref()
            .is_some_and(|netloc| netloc.contains('@'))
    }
}

/// A request URL as artwork.py's `parse_url` accepts it.
#[derive(Debug, Clone)]
pub struct Parsed {
    pub split: Split,
    pub hostname: Option<String>,
}

impl Parsed {
    pub fn scheme(&self) -> &str {
        self.split.scheme.as_deref().unwrap_or("")
    }

    /// `parts.path or '/'` plus `?query` when the query is not empty.
    pub fn target(&self) -> String {
        let mut target = if self.split.path.is_empty() {
            "/".to_string()
        } else {
            self.split.path.clone()
        };
        if let Some(query) = self.split.query.as_deref().filter(|q| !q.is_empty()) {
            target.push('?');
            target.push_str(query);
        }
        target
    }
}

/// artwork.py's `parse_url`: printable ASCII only, at most 8192 characters,
/// no backslash, no credentials or fragment; `file:` without host, query or
/// port; `https:` with a host and no port but 443.
pub fn parse(url: &str) -> Result<Parsed, Fail> {
    let invalid = Fail("invalid-url");
    if url.is_empty()
        || url.chars().count() > 8192
        || url.chars().any(|c| c <= ' ' || c >= '\x7f')
        || url.contains('\\')
    {
        return Err(invalid);
    }
    let split = split(url).map_err(|_| Fail("invalid-url"))?;
    if split.has_userinfo() || split.fragment.as_deref().is_some_and(|f| !f.is_empty()) {
        return Err(Fail("invalid-url"));
    }
    let port = split.port().map_err(|_| Fail("invalid-url"))?;
    let hostname = split.hostname();
    match split.scheme.as_deref().unwrap_or("") {
        "file" => {
            if split.netloc.as_deref().is_some_and(|n| !n.is_empty())
                || split.query.as_deref().is_some_and(|q| !q.is_empty())
                || port.is_some()
            {
                return Err(Fail("invalid-file-url"));
            }
        }
        "https" => {
            if hostname.is_none() || !matches!(port, None | Some(443)) {
                return Err(Fail("invalid-https-url"));
            }
        }
        _ => return Err(Fail("unsupported-scheme")),
    }
    Ok(Parsed { split, hostname })
}

const USES_RELATIVE: &[&str] = &[
    "", "ftp", "http", "gopher", "nntp", "imap", "wais", "file", "https", "shttp", "mms",
    "prospero", "rtsp", "rtsps", "rtspu", "sftp", "svn", "svn+ssh", "ws", "wss",
];
const USES_NETLOC: &[&str] = &[
    "",
    "ftp",
    "http",
    "gopher",
    "nntp",
    "telnet",
    "imap",
    "wais",
    "file",
    "mms",
    "https",
    "shttp",
    "snews",
    "prospero",
    "rtsp",
    "rtsps",
    "rtspu",
    "rsync",
    "svn",
    "svn+ssh",
    "sftp",
    "nfs",
    "git",
    "git+ssh",
    "ws",
    "wss",
    "itms-services",
];

fn unsplit(
    scheme: Option<&str>,
    netloc: Option<&str>,
    path: &str,
    query: Option<&str>,
    fragment: Option<&str>,
) -> String {
    let mut url = path.to_string();
    if let Some(netloc) = netloc {
        if !url.is_empty() && !url.starts_with('/') {
            url.insert(0, '/');
        }
        url = format!("//{netloc}{url}");
    } else if url.starts_with("//") {
        url = format!("//{url}");
    }
    if let Some(scheme) = scheme.filter(|s| !s.is_empty()) {
        url = format!("{scheme}:{url}");
    }
    if let Some(query) = query {
        url.push('?');
        url.push_str(query);
    }
    if let Some(fragment) = fragment {
        url.push('#');
        url.push_str(fragment);
    }
    url
}

/// Python 3.14's `urljoin(base, url)` (RFC 3986 resolution with Python's
/// quirks). `Err` where `urlsplit` raises.
pub fn join(base: &str, url: &str) -> Result<String, ()> {
    if base.is_empty() {
        return Ok(url.to_string());
    }
    if url.is_empty() {
        return Ok(base.to_string());
    }
    let b = split(base)?;
    let u = split(url)?;
    let scheme = u.scheme.clone().or_else(|| b.scheme.clone());
    if scheme != b.scheme
        || scheme
            .as_deref()
            .is_some_and(|s| !s.is_empty() && !USES_RELATIVE.contains(&s))
    {
        return Ok(url.to_string());
    }
    let scheme_text = scheme.as_deref().unwrap_or("");
    let mut netloc = u.netloc.clone();
    if scheme_text.is_empty() || USES_NETLOC.contains(&scheme_text) {
        if netloc.as_deref().is_some_and(|n| !n.is_empty()) {
            return Ok(unsplit(
                scheme.as_deref(),
                netloc.as_deref(),
                &u.path,
                u.query.as_deref(),
                u.fragment.as_deref(),
            ));
        }
        netloc = b.netloc.clone();
    }
    if u.path.is_empty() {
        let (mut query, mut fragment) = (u.query.clone(), u.fragment.clone());
        if query.is_none() {
            query = b.query.clone();
            if fragment.is_none() {
                fragment = b.fragment.clone();
            }
        }
        return Ok(unsplit(
            scheme.as_deref(),
            netloc.as_deref(),
            &b.path,
            query.as_deref(),
            fragment.as_deref(),
        ));
    }
    let mut base_parts: Vec<&str> = b.path.split('/').collect();
    if base_parts.last() != Some(&"") {
        base_parts.pop();
    }
    let segments: Vec<&str> = if u.path.starts_with('/') {
        u.path.split('/').collect()
    } else {
        let mut all: Vec<&str> = base_parts;
        all.extend(u.path.split('/'));
        if all.len() > 2 {
            let last = all.len() - 1;
            let middle: Vec<&str> = all[1..last]
                .iter()
                .copied()
                .filter(|s| !s.is_empty())
                .collect();
            let mut filtered = vec![all[0]];
            filtered.extend(middle);
            filtered.push(all[last]);
            all = filtered;
        }
        all
    };
    let mut resolved: Vec<&str> = Vec::new();
    for &segment in &segments {
        match segment {
            ".." => {
                resolved.pop();
            }
            "." => {}
            other => resolved.push(other),
        }
    }
    if matches!(segments.last(), Some(&".") | Some(&"..")) {
        resolved.push("");
    }
    let mut path = resolved.join("/");
    if path.is_empty() {
        path = "/".to_string();
    }
    Ok(unsplit(
        scheme.as_deref(),
        netloc.as_deref(),
        &path,
        u.query.as_deref(),
        u.fragment.as_deref(),
    ))
}

/// `unquote(path, errors='strict')` for an ASCII path: `%XX` escapes
/// decoded, the result UTF-8 (`Err` otherwise: Python's UnicodeDecodeError).
pub fn unquote(text: &str) -> Result<String, ()> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = |at: usize| bytes.get(at).and_then(|&b| (b as char).to_digit(16));
            if let (Some(high), Some(low)) = (hex(i + 1), hex(i + 2)) {
                out.push((high * 16 + low) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).map_err(|_| ())
}

/// `os.path.normpath` for POSIX paths (`abspath` of an absolute path).
pub fn normpath(path: &str) -> String {
    if path.is_empty() {
        return ".".to_string();
    }
    let initial = if path.starts_with("//") && !path.starts_with("///") {
        2
    } else if path.starts_with('/') {
        1
    } else {
        0
    };
    let mut parts: Vec<&str> = Vec::new();
    for component in path.split('/') {
        if component.is_empty() || component == "." {
            continue;
        }
        if component != ".." || (initial == 0 && parts.is_empty()) || parts.last() == Some(&"..") {
            parts.push(component);
        } else if !parts.is_empty() {
            parts.pop();
        }
    }
    let joined = format!("{}{}", "/".repeat(initial), parts.join("/"));
    if joined.is_empty() {
        ".".to_string()
    } else {
        joined
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_matches_urlsplit() {
        let s = split("HTTPS://User@Host.Example:443/a/b?q=1#f").unwrap();
        assert_eq!(s.scheme.as_deref(), Some("https"));
        assert_eq!(s.netloc.as_deref(), Some("User@Host.Example:443"));
        assert_eq!(
            (s.path.as_str(), s.query.as_deref(), s.fragment.as_deref()),
            ("/a/b", Some("q=1"), Some("f"))
        );
        assert_eq!(s.hostname().as_deref(), Some("host.example"));
        assert_eq!(s.port(), Ok(Some(443)));
        assert!(split("https://[::1/a").is_err());
        assert!(split("https://a]/").is_err());
        assert!(split("https://[1.2.3.4]/").is_err());
        assert!(split("https://x[::1]/").is_err());
        assert!(split("https://[::1]x/").is_err());
        let v6 = split("https://[FE80::1%Eth0]:8080/").unwrap();
        assert_eq!(v6.hostname().as_deref(), Some("fe80::1%Eth0"));
        assert_eq!(v6.port(), Ok(Some(8080)));
        assert!(split("https://[v1.x]/").is_ok());
        assert_eq!(split("1http://x").unwrap().scheme, None);
        assert_eq!(split("file:rel").unwrap().path, "rel");
    }

    #[test]
    fn ports_follow_python() {
        for (url, port) in [
            ("https://h:0443/", Ok(Some(443))),
            ("https://h:/", Ok(None)),
            ("https://h:65536/", Err(())),
            ("https://h:1:2/", Err(())),
            ("https://h:+1/", Err(())),
            ("https://h:000000000080/", Ok(Some(80))),
        ] {
            assert_eq!(split(url).unwrap().port(), port, "{url}");
        }
    }

    #[test]
    fn parse_codes() {
        let code = |url: &str| parse(url).err().map(|f| f.0);
        assert_eq!(code("https://example.com/a"), None);
        assert_eq!(
            code("https://example.com:8080/a"),
            Some("invalid-https-url")
        );
        assert_eq!(code("https://u@example.com/a"), Some("invalid-url"));
        assert_eq!(code("https://example.com/a#x"), Some("invalid-url"));
        assert_eq!(code("https://example.com/a#"), None);
        assert_eq!(code("file:///a?"), None);
        assert_eq!(code("file:///a?b"), Some("invalid-file-url"));
        assert_eq!(code("gopher://x"), Some("unsupported-scheme"));
        assert_eq!(parse("https://h/p?").unwrap().target(), "/p");
        assert_eq!(parse("https://h").unwrap().target(), "/");
    }

    #[test]
    fn join_matches_urljoin() {
        let base = "https://images.example.com/relative/deep";
        for (location, joined) in [
            (
                "../cover.png?x=1",
                "https://images.example.com/cover.png?x=1",
            ),
            ("/b", "https://images.example.com/b"),
            ("c", "https://images.example.com/relative/c"),
            ("//other.example/a", "https://other.example/a"),
            ("http://images.example.com/a", "http://images.example.com/a"),
            ("?q", "https://images.example.com/relative/deep?q"),
            ("#f", "https://images.example.com/relative/deep#f"),
            ("/a#", "https://images.example.com/a#"),
            (".", "https://images.example.com/relative/"),
            ("../../..", "https://images.example.com/"),
            ("a//b/./c", "https://images.example.com/relative/a/b/c"),
            ("file:///etc/passwd", "file:///etc/passwd"),
            ("/a\tb", "https://images.example.com/ab"),
            (" /x", "https://images.example.com/x"),
        ] {
            assert_eq!(join(base, location).unwrap(), joined, "{location}");
        }
        assert_eq!(join("https://h/a?x", "").unwrap(), "https://h/a?x");
    }

    #[test]
    fn unquote_and_normpath() {
        assert_eq!(unquote("/a%20b%2F%2e%2E%zz%4").unwrap(), "/a b/..%zz%4");
        assert!(unquote("/%ff").is_err());
        assert_eq!(unquote("/%C3%A9").unwrap(), "/é");
        for (path, normal) in [
            ("/a/./b/", "/a/b"),
            ("//a//b", "//a/b"),
            ("///a", "/a"),
            ("/.", "/"),
            ("//", "//"),
            ("/a/../b", "/b"),
            ("/..", "/"),
        ] {
            assert_eq!(normpath(path), normal, "{path}");
        }
    }
}
