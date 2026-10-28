//! A request target read as the Node server read it: `new URL('http://x' + url)` for a path ("/path?query", origin
//! form), `new URL(url)` for anything else (an absolute URL, and an Origin header), by the WHATWG URL parser's rules:
//! "\" is "/" in a special scheme's path, "." and ".." segments are resolved (also as "%2e"), what the path and query
//! percent-encode sets name is encoded, tabs and newlines are dropped, and a host is lowercased, percent-decoded and
//! read as an IPv4 or IPv6 address where it is one.  Then `decodeURIComponent` and `URLSearchParams`.
//!
//! Only what the routes need: the pathname, the query's parameters and the host.  Left out: Unicode host names (IDNA:
//! refused here, where Node would turn them into punycode), the validation of punycode labels beyond "xn--" alone,
//! and file URLs' Windows drive letters.

use std::fmt::Write;
use std::net::Ipv6Addr;

/// What a parsed URL gives the routes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Url {
    /// `u.host`: the host and the port unless it is the scheme's own ("" for none)
    pub host: String,
    /// `u.pathname`, still percent-encoded
    pub pathname: String,
    /// `u.search` without its "?" (None: no "?")
    pub query: Option<String>,
}

impl Url {
    /// `u.searchParams.get(name)`
    pub fn param(&self, name: &str) -> Option<String> {
        search_params(self.query.as_deref()?).into_iter().find(|(k, _)| k == name).map(|(_, v)| v)
    }
    /// `u.searchParams.has(name)`
    pub fn has_param(&self, name: &str) -> bool {
        self.query.as_deref().is_some_and(|q| search_params(q).iter().any(|(k, _)| k == name))
    }
}

/// `new URL(target.startsWith('/') ? 'http://x' + target : target)`; None where it throws
pub fn parse_target(target: &str) -> Option<Url> {
    if target.starts_with('/') { Some(parse_path(target)) } else { parse_absolute(target) }
}

/// leading and trailing C0 controls and spaces go, and every tab and newline
fn preprocess(input: &str) -> String {
    input.trim_matches(|c: char| c <= '\u{20}').chars().filter(|&c| c != '\t' && c != '\n' && c != '\r').collect()
}

/// `new URL('http://x' + target)` for a target that starts with "/"
pub fn parse_path(target: &str) -> Url {
    let s = preprocess(&format!("http://x{target}"));
    let rest = &s["http://x".len()..];
    let (pathname, query) = path_and_query(rest, true);
    Url { host: "x".into(), pathname, query }
}

const SPECIAL: [(&str, Option<u16>); 6] =
    [("ftp", Some(21)), ("file", None), ("http", Some(80)), ("https", Some(443)), ("ws", Some(80)), ("wss", Some(443))];

/// `new URL(input)` without a base; None where it throws
pub fn parse_absolute(input: &str) -> Option<Url> {
    let s = preprocess(input);
    let b = s.as_bytes();
    if b.is_empty() || !b[0].is_ascii_alphabetic() {
        return None;
    }
    let mut i = 1;
    while i < b.len() && (b[i].is_ascii_alphanumeric() || matches!(b[i], b'+' | b'-' | b'.')) {
        i += 1;
    }
    if i >= b.len() || b[i] != b':' {
        return None;
    }
    let scheme = s[..i].to_ascii_lowercase();
    let rest = &s[i + 1..];
    let special = SPECIAL.iter().find(|(n, _)| *n == scheme);
    match special {
        Some(&("file", _)) => parse_file(rest),
        Some(&(_, default_port)) => {
            // the special authority slashes, however many and of either kind
            let rest = rest.trim_start_matches(['/', '\\']);
            let (host, after) = authority(rest, true, default_port)?;
            let (pathname, query) = path_and_query(after, true);
            Some(Url { host, pathname, query })
        }
        None => {
            if let Some(r) = rest.strip_prefix("//") {
                let (host, after) = authority(r, false, None)?;
                let (pathname, query) = path_and_query(after, false);
                Some(Url { host, pathname, query })
            } else if let Some(r) = rest.strip_prefix('/') {
                let (pathname, query) = path_and_query(&format!("/{r}"), false);
                Some(Url { host: String::new(), pathname, query })
            } else {
                // an opaque path ("mailto:x"): no host
                let end = rest.find(['?', '#']).unwrap_or(rest.len());
                let mut pathname = String::new();
                for c in rest[..end].chars() {
                    encode(&mut pathname, c, c0_control);
                }
                let query = query_of(&rest[end..], false);
                Some(Url { host: String::new(), pathname, query })
            }
        }
    }
}

/// a file URL: its host ("localhost" is none) and path; no port
fn parse_file(rest: &str) -> Option<Url> {
    let r = rest.strip_prefix(['/', '\\']);
    let Some(r) = r.and_then(|r| r.strip_prefix(['/', '\\'])) else {
        let (pathname, query) = path_and_query(rest, true);
        return Some(Url { host: String::new(), pathname, query });
    };
    let end = r.find(['/', '\\', '?', '#']).unwrap_or(r.len());
    let mut host = if end == 0 { String::new() } else { host_parse(&r[..end], false)? };
    if host == "localhost" {
        host.clear();
    }
    let (pathname, query) = path_and_query(&r[end..], true);
    Some(Url { host, pathname, query })
}

/// the authority up to the path: the host (after the last "@") and port, as `u.host`; and what follows
fn authority(rest: &str, special: bool, default_port: Option<u16>) -> Option<(String, &str)> {
    let end = if special { rest.find(['/', '\\', '?', '#']) } else { rest.find(['/', '?', '#']) }.unwrap_or(rest.len());
    let auth = &rest[..end];
    let hostport = match auth.rfind('@') {
        Some(at) => {
            let h = &auth[at + 1..];
            if h.is_empty() {
                return None;
            }
            h
        }
        None => auth,
    };
    // a ":" outside brackets starts the port
    let mut inside = false;
    let mut colon = None;
    for (i, c) in hostport.char_indices() {
        match c {
            '[' => inside = true,
            ']' => inside = false,
            ':' if !inside => {
                colon = Some(i);
                break;
            }
            _ => {}
        }
    }
    let (name, port) = match colon {
        Some(i) => (&hostport[..i], Some(&hostport[i + 1..])),
        None => (hostport, None),
    };
    if name.is_empty() && (special || colon.is_some()) {
        return None;
    }
    let mut host = host_parse(name, !special)?;
    if let Some(p) = port {
        if !p.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        if !p.is_empty() {
            let digits = p.trim_start_matches('0');
            if digits.len() > 5 {
                return None;
            }
            let n: u32 = if digits.is_empty() { 0 } else { digits.parse().ok()? };
            if n > 65535 {
                return None;
            }
            if default_port != Some(n as u16) {
                let _ = write!(host, ":{n}");
            }
        }
    }
    Some((host, &rest[end..]))
}

/// a C0 control or anything above "~"
fn c0_control(c: char) -> bool {
    c <= '\u{1F}' || c > '~'
}
fn query_set(c: char) -> bool {
    c0_control(c) || matches!(c, ' ' | '"' | '#' | '<' | '>')
}
fn special_query_set(c: char) -> bool {
    query_set(c) || c == '\''
}
fn path_set(c: char) -> bool {
    query_set(c) || matches!(c, '?' | '^' | '`' | '{' | '}')
}
/// Node's parser (Ada) encodes a path only when it holds a character of the path set as it was before "^" joined it
/// (its quick check of the path predates that): "/^" stays "/^", "/^{" is "/%5E%7B"
fn path_set_before_caret(c: char) -> bool {
    c != '^' && path_set(c)
}
fn no_set(_: char) -> bool {
    false
}

/// c, or its UTF-8 bytes as %XX when the set names it
fn encode(out: &mut String, c: char, set: fn(char) -> bool) {
    if set(c) {
        let mut buf = [0u8; 4];
        for b in c.encode_utf8(&mut buf).bytes() {
            let _ = write!(out, "%{b:02X}");
        }
    } else {
        out.push(c);
    }
}

fn is_single_dot(s: &str) -> bool {
    s == "." || s.eq_ignore_ascii_case("%2e")
}
fn is_double_dot(s: &str) -> bool {
    s == ".." || s.eq_ignore_ascii_case(".%2e") || s.eq_ignore_ascii_case("%2e.") || s.eq_ignore_ascii_case("%2e%2e")
}

/// the path (from the path start state on) and the query of what follows the host
fn path_and_query(rest: &str, special: bool) -> (String, Option<String>) {
    let end = rest.find(['?', '#']).unwrap_or(rest.len());
    let path = &rest[..end];
    let query = query_of(&rest[end..], special);
    // the path start state: a special URL always has a path, its first "/" (or "\") is the start of it
    let body = if special {
        path.strip_prefix(['/', '\\']).unwrap_or(path)
    } else if path.is_empty() {
        return (String::new(), query);
    } else {
        path.strip_prefix('/').unwrap_or(path)
    };
    let sep = |c: char| c == '/' || (special && c == '\\');
    let set: fn(char) -> bool = if body.chars().any(path_set_before_caret) { path_set } else { no_set };
    let mut segs: Vec<String> = Vec::new();
    let mut buf = String::new();
    let mut chars = body.chars();
    loop {
        let c = chars.next();
        match c {
            Some(c) if !sep(c) => encode(&mut buf, c, set),
            _ => {
                let at_sep = c.is_some();
                if is_double_dot(&buf) {
                    segs.pop();
                    if !at_sep {
                        segs.push(String::new());
                    }
                } else if is_single_dot(&buf) {
                    if !at_sep {
                        segs.push(String::new());
                    }
                } else {
                    segs.push(std::mem::take(&mut buf));
                }
                buf.clear();
                if !at_sep {
                    break;
                }
            }
        }
    }
    let mut pathname = String::with_capacity(path.len() + 1);
    for s in &segs {
        pathname.push('/');
        pathname.push_str(s);
    }
    (pathname, query)
}

/// the query of "?query#fragment" (None without a "?"), percent-encoded as the URL keeps it
fn query_of(rest: &str, special: bool) -> Option<String> {
    let q = rest.strip_prefix('?')?;
    let q = &q[..q.find('#').unwrap_or(q.len())];
    let mut out = String::with_capacity(q.len());
    for c in q.chars() {
        encode(&mut out, c, if special { special_query_set } else { query_set });
    }
    Some(out)
}

/// percent-decoding as the URL standard does it: "%XX" is that byte, any other "%" stays
fn percent_decode(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if s[i] == b'%'
            && i + 2 < s.len()
            && let (Some(h), Some(l)) = (hex(s[i + 1]), hex(s[i + 2]))
        {
            out.push(h << 4 | l);
            i += 3;
            continue;
        }
        out.push(s[i]);
        i += 1;
    }
    out
}

fn hex(c: u8) -> Option<u8> {
    (c as char).to_digit(16).map(|d| d as u8)
}

/// `URLSearchParams` of a query: "&"-separated, "name=value" (no "=": an empty value), "+" a space, percent-decoded,
/// UTF-8 with U+FFFD for what is not
pub fn search_params(query: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for part in query.as_bytes().split(|&c| c == b'&') {
        if part.is_empty() {
            continue;
        }
        let (k, v) = match part.iter().position(|&c| c == b'=') {
            Some(i) => (&part[..i], &part[i + 1..]),
            None => (part, &part[part.len()..]),
        };
        let decode = |x: &[u8]| {
            let plus: Vec<u8> = x.iter().map(|&c| if c == b'+' { b' ' } else { c }).collect();
            String::from_utf8_lossy(&percent_decode(&plus)).into_owned()
        };
        out.push((decode(k), decode(v)));
    }
    out
}

/// `decodeURIComponent(s)`; None where it throws (a "%" without two hex digits, bytes that are not UTF-8)
pub fn decode_uri_component(s: &str) -> Option<String> {
    if !s.contains('%') {
        return Some(s.to_string());
    }
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    let byte_at = |i: usize| -> Option<u8> {
        if b.get(i) != Some(&b'%') {
            return None;
        }
        Some(hex(*b.get(i + 1)?)? << 4 | hex(*b.get(i + 2)?)?)
    };
    while i < b.len() {
        if b[i] != b'%' {
            // a whole character (s is UTF-8: copy up to the next "%")
            let next = s[i..].find('%').map_or(b.len(), |n| i + n);
            out.push_str(&s[i..next]);
            i = next;
            continue;
        }
        let b0 = byte_at(i)?;
        i += 3;
        if b0 < 0x80 {
            out.push(b0 as char);
            continue;
        }
        let n = if b0 & 0xE0 == 0xC0 {
            2
        } else if b0 & 0xF0 == 0xE0 {
            3
        } else if b0 & 0xF8 == 0xF0 {
            4
        } else {
            return None;
        };
        let mut octets = vec![b0];
        for _ in 1..n {
            let c = byte_at(i)?;
            if c & 0xC0 != 0x80 {
                return None;
            }
            octets.push(c);
            i += 3;
        }
        // from_utf8 refuses what decodeURIComponent refuses: overlong forms, surrogates, above U+10FFFF
        out.push_str(std::str::from_utf8(&octets).ok()?);
    }
    Some(out)
}

/// the host parser: an IPv6 address in brackets, an opaque host (a scheme that is not special), or a domain (ASCII
/// only here), which may be an IPv4 address
fn host_parse(input: &str, opaque: bool) -> Option<String> {
    if let Some(inner) = input.strip_prefix('[') {
        let inner = inner.strip_suffix(']')?;
        let a: Ipv6Addr = inner.parse().ok()?;
        return Some(format!("[{}]", ipv6_serialize(&a)));
    }
    if opaque {
        if input.chars().any(forbidden_host) {
            return None;
        }
        let mut out = String::with_capacity(input.len());
        for c in input.chars() {
            encode(&mut out, c, c0_control);
        }
        return Some(out);
    }
    let decoded = percent_decode(input.as_bytes());
    // (Node turns a Unicode name into punycode: refused here)
    if !decoded.is_ascii() || decoded.is_empty() {
        return None;
    }
    let domain = String::from_utf8(decoded).ok()?.to_ascii_lowercase();
    if domain.split('.').any(|l| l == "xn--") {
        return None;
    }
    if domain.chars().any(|c| forbidden_host(c) || c <= '\u{1F}' || c == '%' || c == '\u{7F}') {
        return None;
    }
    if ends_in_a_number(&domain) {
        return ipv4_parse(&domain).map(|v| format!("{}.{}.{}.{}", v >> 24, (v >> 16) & 255, (v >> 8) & 255, v & 255));
    }
    Some(domain)
}

fn forbidden_host(c: char) -> bool {
    matches!(c, '\0' | '\t' | '\n' | '\r' | ' ' | '#' | '/' | ':' | '<' | '>' | '?' | '@' | '[' | '\\' | ']' | '^' | '|')
}

fn ends_in_a_number(s: &str) -> bool {
    let mut parts: Vec<&str> = s.split('.').collect();
    if parts.last() == Some(&"") {
        if parts.len() == 1 {
            return false;
        }
        parts.pop();
    }
    let last = parts.last().copied().unwrap_or("");
    if !last.is_empty() && last.bytes().all(|c| c.is_ascii_digit()) {
        return true;
    }
    ipv4_number(last).is_some()
}

/// one part of an IPv4 address: decimal, 0x hex or 0 octal (saturating: anything that large is refused anyway)
fn ipv4_number(s: &str) -> Option<u64> {
    if s.is_empty() {
        return None;
    }
    let (digits, radix) = if let Some(h) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        (h, 16)
    } else if s.len() >= 2 && s.starts_with('0') {
        (&s[1..], 8)
    } else {
        (s, 10)
    };
    let mut v: u64 = 0;
    for c in digits.chars() {
        let d = c.to_digit(radix)? as u64;
        v = v.saturating_mul(radix as u64).saturating_add(d);
    }
    Some(v)
}

fn ipv4_parse(s: &str) -> Option<u32> {
    let mut parts: Vec<&str> = s.split('.').collect();
    if parts.last() == Some(&"") && parts.len() > 1 {
        parts.pop();
    }
    if parts.len() > 4 {
        return None;
    }
    let nums: Vec<u64> = parts.iter().map(|p| ipv4_number(p)).collect::<Option<_>>()?;
    let (last, head) = nums.split_last()?;
    if head.iter().any(|&n| n > 255) {
        return None;
    }
    if *last >= 256u64.pow(5 - nums.len() as u32) {
        return None;
    }
    let mut v = *last;
    for (i, n) in head.iter().enumerate() {
        v += n * 256u64.pow(3 - i as u32);
    }
    Some(v as u32)
}

/// an IPv6 address as the URL standard writes it: lowercase hex, the first longest run of two or more zero pieces as
/// "::", never a dotted IPv4 tail
fn ipv6_serialize(a: &Ipv6Addr) -> String {
    let p = a.segments();
    let (mut best, mut best_len) = (None, 1);
    let mut i = 0;
    while i < 8 {
        if p[i] == 0 {
            let start = i;
            while i < 8 && p[i] == 0 {
                i += 1;
            }
            if i - start > best_len {
                best = Some(start);
                best_len = i - start;
            }
        } else {
            i += 1;
        }
    }
    let mut out = String::new();
    let mut i = 0;
    while i < 8 {
        if Some(i) == best {
            out.push_str(if i == 0 { "::" } else { ":" });
            i += best_len;
            continue;
        }
        let _ = write!(out, "{:x}", p[i]);
        if i != 7 {
            out.push(':');
        }
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn path(t: &str) -> (String, Option<String>) {
        let u = parse_path(t);
        (u.pathname, u.query)
    }

    #[test]
    fn paths_as_node_reads_them() {
        // (each answer as node 24 gave it for new URL('http://x' + target))
        assert_eq!(path("/a^b{c}d`e\"f<g>h|i'j").0, "/a%5Eb%7Bc%7Dd%60e%22f%3Cg%3Eh|i'j");
        assert_eq!(path("/a b").0, "/a%20b");
        assert_eq!(path("/\u{7f}").0, "/%7F");
        assert_eq!(path("/é").0, "/%C3%A9");
        assert_eq!(path("/a\\b").0, "/a/b");
        assert_eq!(path("/.%2e/x").0, "/x");
        assert_eq!(path("/%2e%2E/x").0, "/x");
        assert_eq!(path("/a/./b/../c").0, "/a/c");
        assert_eq!(path("/a/..").0, "/");
        assert_eq!(path("/.").0, "/");
        assert_eq!(path("//x").0, "//x");
        assert_eq!(path("/x\t\ny").0, "/xy");
        assert_eq!(path("/x ").0, "/x");
        assert_eq!(path("/x\u{1}").0, "/x");
        assert_eq!(path("/x?q#f"), ("/x".into(), Some("q".into())));
        let u = parse_path("/x?a b&c=d+e&%zz=%C3%A9&=1&&x");
        assert_eq!(u.query.as_deref(), Some("a%20b&c=d+e&%zz=%C3%A9&=1&&x"));
        assert_eq!(
            search_params(u.query.as_deref().unwrap()),
            [("a b", ""), ("c", "d e"), ("%zz", "é"), ("", "1"), ("x", "")].map(|(a, b)| (a.to_string(), b.to_string()))
        );
        assert_eq!(u.param("c").as_deref(), Some("d e"));
        assert!(u.has_param("x") && !u.has_param("y"));
        assert!(parse_path("/data-manifest?refresh").has_param("refresh"));
    }

    fn host(a: &str) -> Option<(String, String, Option<String>)> {
        parse_absolute(a).map(|u| (u.host, u.pathname, u.query))
    }

    #[test]
    fn absolute_urls_as_node_reads_them() {
        let h = |a: &str| host(a).map(|x| x.0);
        assert_eq!(h("http://LOCALHOST:0080/a").as_deref(), Some("localhost"));
        assert_eq!(h("https://localhost:443").as_deref(), Some("localhost"));
        assert_eq!(h("ws://a:80").as_deref(), Some("a"));
        assert_eq!(h("ftp://a:21/").as_deref(), Some("a"));
        assert_eq!(h("http://localhost:8080/x").as_deref(), Some("localhost:8080"));
        assert_eq!(h("http://0x7f.1/").as_deref(), Some("127.0.0.1"));
        assert_eq!(h("http://127.1/").as_deref(), Some("127.0.0.1"));
        assert_eq!(h("http://[::FFFF:1.2.3.4]:8080/").as_deref(), Some("[::ffff:102:304]:8080"));
        assert_eq!(h("http://[1:0:0:2:0:0:0:3]/").as_deref(), Some("[1:0:0:2::3]"));
        assert_eq!(h("foo://LocalHost:9/x").as_deref(), Some("LocalHost:9"));
        assert_eq!(host("foo:/x"), Some(("".into(), "/x".into(), None)));
        assert_eq!(host("foo:x"), Some(("".into(), "x".into(), None)));
        assert_eq!(h("file://localhost/x").as_deref(), Some(""));
        assert_eq!(h("file://127.0.0.1/x").as_deref(), Some("127.0.0.1"));
        assert_eq!(h("http://u:p@host/x").as_deref(), Some("host"));
        assert_eq!(h("http://a@b@c/").as_deref(), Some("c"));
        assert_eq!(host("http:\\\\\\host\\x"), Some(("host".into(), "/x".into(), None)));
        assert_eq!(h("http:host/x").as_deref(), Some("host"));
        assert_eq!(h("http://%6c%6fcalhost/").as_deref(), Some("localhost"));
        assert_eq!(h("http://a..b/").as_deref(), Some("a..b"));
        assert_eq!(h("http://host:/x").as_deref(), Some("host"));
        assert_eq!(h("HTTP://H/").as_deref(), Some("h"));
        assert_eq!(h("http://*/x").as_deref(), Some("*"));
        assert_eq!(host("http://h?x"), Some(("h".into(), "/".into(), Some("x".into()))));
        assert_eq!(host("foo://"), Some(("".into(), "".into(), None)));
        for bad in [
            "http://1.2.3.4.5/",
            "http://1.2.3.256/",
            "http://xn--/",
            "http://host:65536/",
            "http://h:1a/",
            "http://[::1/",
            "http://a b/",
            "http://a%/",
            "null",
            "*",
            "foo://h:99999/",
            "",
            "1http://x/",
            "http://",
            "http://u@/",
        ] {
            assert_eq!(host(bad), None, "{bad}");
        }
    }

    #[test]
    fn decode_as_decode_uri_component() {
        for (s, d) in [
            ("%41", Some("A")),
            ("%e9", None),
            ("%C3%A9", Some("é")),
            ("%ff", None),
            ("%", None),
            ("%4", None),
            ("%C3", None),
            ("%ED%A0%80", None),
            ("%F4%90%80%80", None),
            ("%C0%AE", None),
            ("a%2fb", Some("a/b")),
            ("%E2%82%AC", Some("€")),
            ("é%20x", Some("é x")),
            ("%ZZ", None),
            ("/a%00b", Some("/a\0b")),
        ] {
            assert_eq!(decode_uri_component(s).as_deref(), d, "{s}");
        }
    }

    /// what the routes read of a target, as JSON, the way the node script below writes it
    fn reading(t: &str, absolute: bool) -> serde_json::Value {
        use serde_json::json;
        let u = if absolute { parse_absolute(t) } else { Some(parse_path(t)) };
        match u {
            None => json!("throws"),
            Some(u) => {
                let search = match u.query.as_deref() {
                    None | Some("") => String::new(),
                    Some(q) => format!("?{q}"),
                };
                let params: Vec<Vec<String>> =
                    u.query.as_deref().map(search_params).unwrap_or_default().into_iter().map(|(k, v)| vec![k, v]).collect();
                json!({ "host": if absolute { u.host.clone() } else { String::new() }, "pathname": u.pathname, "search": search, "params": params,
                    "decoded": decode_uri_component(&u.pathname) })
            }
        }
    }

    fn corpus() -> (Vec<String>, Vec<String>) {
        let mut paths: Vec<String> = [
            "/",
            "/index.html",
            "/data/SPEED2.EXE",
            "/data-blocks/TRACKS/L4RA.BUN?b=0&n=8&m=1700000000&s=123",
            "/%2ftest/play.html",
            "/te%C5%BFt/play.html",
            "/..%2f..%2f..%2fetc/passwd",
            "/%ZZ",
            "/a%00b",
            "/a%5cb",
            "/x/..%2ftest/play.html",
            "/%5ctest/play.html",
            "/./test/play.html",
            "/test/./play.html",
            "/%2e/test/play.html",
            "/data/%252e%252e/%252e%252e/etc/passwd",
            "/data/....//....//etc/passwd",
            "/data/..\\..\\etc\\passwd",
            "/data/SPEED2.EXE%00.txt",
            "/data/.%2e/.%2e/etc/passwd",
            "/data/%c0%ae%c0%ae/etc/passwd",
            "/data/%u002e%u002e/etc/passwd",
            "/DATA/../../etc/passwd",
            "/game.wasm?v=abc&v=def",
            "/game.wasm?v=",
            "/game.wasm?v",
            "/lan?resume",
            "/lan?vip=10.77.0.5&resume",
            "/players?m1-123",
            "/x?a=1&a=2&b=%41%42+c",
            "/x?%",
            "/x?%2",
            "/x?q=%E2%82",
            "/\u{e9}?\u{e9}=\u{fc}",
            "/a b?c d",
            "/a#frag?x",
            "/a?b#c",
            "//",
            "///a",
            "/\\",
            "/.",
            "/..",
            "/...",
            "/.%2E",
            "/%2E.",
            "/a/b/%2e%2E/c",
            "/a\t/b",
            "/a\n\r",
            "/{x}^`\"<>|'",
            "/\u{7f}\u{1}",
            "/\u{1F600}",
            "/%F0%9F%98%80",
            "/%ED%A0%80",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let alphabet: Vec<char> = "/\\.%2eEfF5cC0a?#&=+ \u{e9}\u{17F}\t^{\"'x~".chars().collect();
        let mut seed = 0xDEAD_BEEF_CAFE_F00Du64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for _ in 0..3000 {
            let n = 1 + (next() % 14) as usize;
            let mut s = String::from("/");
            for _ in 0..n {
                s.push(alphabet[(next() % alphabet.len() as u64) as usize]);
            }
            paths.push(s);
        }
        let mut abs: Vec<String> = [
            "http://localhost/x",
            "http://LOCALHOST:8080/a/../b",
            "https://nfsu2.test:443/",
            "http://127.0.0.1:0080",
            "http://[::1]:8080/lan?resume",
            "http://[::ffff:127.0.0.1]/",
            "http://0x7f.0.0.1/",
            "http://2130706433/",
            "http://0177.0.0.1/",
            "http://evil.example/robots.txt",
            "https://localhost:9999",
            "null",
            "file:///etc/passwd",
            "foo://localhost/x",
            "mailto:a@b",
            "http://a:b@localhost/",
            "ws://localhost/lan",
            "http://localhost./",
            "http://local%68ost/",
            "http://xn--bcher-kva.de/",
            "http://_x.y/",
            "http://a.b.c.d.e/",
            "http://1.2.3/",
            "http://1.2.3.4.",
            "http://0x/",
            "http://0xffffffff/",
            "http://0x100000000/",
            "http://256.1/",
            "http://1.0x100/",
            "http:/\\/localhost/x",
            "HtTp://x:65535/",
            "http://x:65536/",
            "http://[1::2::3]/",
            "http://[::1]x/",
            "http://[::1]:/",
            "x:",
            "a+b-c.d://h/",
            "1a://h/",
            "http://h/a?b#c",
            "http://h:8a/",
            "http://%/",
            "http://%41/",
            "http://a^b/",
            "http://a|b/",
            "http://a\\b/",
            "ftp://h:21/",
            "wss://h:443/",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let host_alphabet: Vec<char> = "aZ09.-_:@[]%x41/\\?#^|*".chars().collect();
        for _ in 0..2000 {
            let n = 1 + (next() % 12) as usize;
            let scheme = ["http://", "https://", "foo://", "http:", "ws://"][(next() % 5) as usize];
            let mut s = scheme.to_string();
            for _ in 0..n {
                s.push(host_alphabet[(next() % host_alphabet.len() as u64) as usize]);
            }
            abs.push(s);
        }
        (paths, abs)
    }

    // the Node server's reading of a target (new URL, its pathname, searchParams, decodeURIComponent) against node's
    // own.  A node whose Ada predates "^" in the path set (v23.9.0 does: it leaves "/^{" as "/^%7B", where the Node
    // server's gave "/%5E%7B", see path_set_before_caret) reads every path with a "^" otherwise: with such a node the
    // targets that hold one are left out (and counted), the others still compared
    #[test]
    fn the_same_reading_as_node() {
        let (paths, abs) = corpus();
        let script = r#"
let input = ''; process.stdin.on('data', d => { input += d; }); process.stdin.on('end', () => {
  const { paths, abs } = JSON.parse(input);
  const read = (t, absolute) => {
    let u; try { u = new URL(absolute ? t : 'http://x' + t); } catch { return 'throws'; }
    let decoded; try { decoded = decodeURIComponent(u.pathname); } catch { decoded = null; }
    return { host: absolute ? u.host : '', pathname: u.pathname, search: u.search, params: [...u.searchParams], decoded };
  };
  const caret = new URL('http://x/^{').pathname;
  process.stdout.write(JSON.stringify({ caret, reads: [...paths.map(t => read(t, false)), ...abs.map(t => read(t, true))] }));
});"#;
        let mut child = match std::process::Command::new("node")
            .args(["-e", script])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(_) => {
                eprintln!("no node: the cross-check of the URL reading is skipped");
                return;
            }
        };
        let input = serde_json::json!({ "paths": paths, "abs": abs }).to_string();
        std::io::Write::write_all(child.stdin.as_mut().unwrap(), input.as_bytes()).unwrap();
        drop(child.stdin.take());
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success());
        let answer: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
        let node = answer["reads"].as_array().unwrap();
        let old_caret = answer["caret"] == "/^%7B";
        let ours: Vec<serde_json::Value> = paths.iter().map(|t| reading(t, false)).chain(abs.iter().map(|t| reading(t, true))).collect();
        let targets: Vec<&String> = paths.iter().chain(abs.iter()).collect();
        let (mut differ, mut left_out) = (Vec::new(), 0);
        for ((t, n), o) in targets.iter().zip(node).zip(&ours) {
            if old_caret && t.contains('^') {
                left_out += 1;
                continue;
            }
            if n != o {
                differ.push(format!("{t:?}: node {n} ours {o}"));
            }
        }
        if left_out > 0 {
            eprintln!("node's Ada predates \"^\" in the path set: {left_out} of {} targets (with a \"^\") left out", targets.len());
        }
        assert!(left_out < targets.len() / 2, "most targets compared ({left_out} of {} left out)", targets.len());
        // (a Unicode host is refused here where node writes it as punycode: none in the corpus)
        let compared = targets.len() - left_out;
        assert!(differ.is_empty(), "{} of {compared} differ:\n{}", differ.len(), differ[..differ.len().min(30)].join("\n"));
    }

    #[test]
    fn ipv6_written_as_the_standard_says() {
        let s = |a: &str| ipv6_serialize(&a.parse().unwrap());
        assert_eq!(s("::"), "::");
        assert_eq!(s("::1"), "::1");
        assert_eq!(s("1::"), "1::");
        assert_eq!(s("1:0:0:2:0:0:0:3"), "1:0:0:2::3");
        assert_eq!(s("1:0:2:3:4:5:6:7"), "1:0:2:3:4:5:6:7");
        assert_eq!(s("2001:db8:0:0:1:0:0:1"), "2001:db8::1:0:0:1");
    }
}
