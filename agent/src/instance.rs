// SPDX-License-Identifier: GPL-3.0-or-later
//! One PairDesk per computer, and upgrades that just work.
//!
//! When the phone port is already taken it's almost always PairDesk itself.
//! If that copy is an older release (the user just downloaded a new one),
//! the new copy asks it to stop through its settings page and takes its
//! place. Otherwise the running copy stays and its settings page is shown.
//!
//! The settings page has answered `GET api/state` (with `version`) and
//! `POST api/quit` since 0.2.0, so this works for every older release.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::time::Duration;

/// The copy of PairDesk that holds the port.
#[derive(Debug, PartialEq)]
pub struct Running {
    /// Its settings page.
    pub url: String,
    /// Its release, when its settings page answered.
    pub version: Option<String>,
}

/// Finds the running copy through the settings address it saved.
pub fn find(settings_url_file: &Path) -> Option<Running> {
    let url = std::fs::read_to_string(settings_url_file).ok()?;
    let url = url.trim().to_string();
    if url.is_empty() {
        return None;
    }
    let version = request(&url, "GET", "api/state")
        .ok()
        .filter(|(status, _)| *status == 200)
        .and_then(|(_, body)| serde_json::from_str::<serde_json::Value>(&body).ok())
        .and_then(|v| v.get("version")?.as_str().map(str::to_string));
    Some(Running { url, version })
}

/// True when `running` is an older release than `ours` ("0.2.0" < "0.5.1").
pub fn is_older(running: &str, ours: &str) -> bool {
    fn parts(v: &str) -> Option<Vec<u64>> {
        v.trim()
            .split(['.', '-', '+'])
            .take(3)
            .map(|p| p.parse().ok())
            .collect()
    }
    match (parts(running), parts(ours)) {
        (Some(a), Some(b)) => a < b,
        _ => false,
    }
}

/// Asks the running copy to stop (what its Stop button does).
pub fn ask_to_quit(url: &str) -> Result<(), String> {
    match request(url, "POST", "api/quit")? {
        (200, _) => Ok(()),
        (status, _) => Err(format!("it answered {status}")),
    }
}

/// Asks the running PairDesk to show itself (its window, on Windows).
pub fn ask_to_show(url: &str) -> Result<(), String> {
    match request(url, "POST", "api/show")? {
        (200, _) => Ok(()),
        (status, _) => Err(format!("it answered {status}")),
    }
}

/// A minimal HTTP/1.0 request to the settings page on 127.0.0.1.
/// `url` is the page address, e.g. `http://127.0.0.1:50123/<secret>/`.
fn request(url: &str, method: &str, path: &str) -> Result<(u16, String), String> {
    request_with(url, method, path, "")
}

/// Asks the running PairDesk to send files to the connected phone(s).
pub fn send_paths(url: &str, paths: &[std::path::PathBuf]) -> Result<String, String> {
    let body = serde_json::json!({
        "paths": paths.iter().map(|p| p.display().to_string()).collect::<Vec<_>>(),
    })
    .to_string();
    match request_with(url, "POST", "api/send-paths", &body)? {
        (200, answer) => Ok(answer),
        (_, msg) => Err(msg),
    }
}

fn request_with(url: &str, method: &str, path: &str, body: &str) -> Result<(u16, String), String> {
    let rest = url
        .strip_prefix("http://")
        .ok_or("not a local settings address")?;
    let (host, base) = rest.split_once('/').unwrap_or((rest, ""));
    let addr = host
        .to_socket_addrs()
        .map_err(|e| e.to_string())?
        .find(|a| a.ip().is_loopback())
        .ok_or("not a local settings address")?;
    let mut stream =
        TcpStream::connect_timeout(&addr, Duration::from_secs(2)).map_err(|e| e.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .and_then(|_| stream.set_write_timeout(Some(Duration::from_secs(3))))
        .map_err(|e| e.to_string())?;
    let base = base.trim_end_matches('/');
    let mut req = format!("{method} /{base}/{path} HTTP/1.0\r\nHost: {host}\r\n");
    if method == "POST" {
        req.push_str(&format!(
            "X-PairDesk: 1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n",
            body.len()
        ));
    }
    req.push_str("\r\n");
    req.push_str(body);
    stream
        .write_all(req.as_bytes())
        .map_err(|e| e.to_string())?;

    let mut raw = Vec::new();
    stream
        .take(256 * 1024)
        .read_to_end(&mut raw)
        .map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&raw);
    let (head, body) = text.split_once("\r\n\r\n").ok_or("no answer")?;
    let status = head
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or("no answer")?;
    Ok((status, body.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufRead;
    use std::net::TcpListener;
    use std::sync::mpsc;

    #[test]
    fn compares_releases() {
        assert!(is_older("0.2.0", "0.5.1"));
        assert!(is_older("0.5.0", "0.5.1"));
        assert!(is_older("0.9.9", "1.0.0"));
        assert!(!is_older("0.5.1", "0.5.1"));
        assert!(!is_older("0.6.0", "0.5.1"));
        assert!(!is_older("0.10.0", "0.9.0"), "numbers, not text");
        assert!(!is_older("garbage", "0.5.1"));
    }

    /// A fake settings page: answers each request with `answers`, and
    /// passes on the request lines it saw.
    fn fake_page(answers: Vec<&'static str>) -> (String, mpsc::Receiver<String>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/s3cret/", l.local_addr().unwrap());
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            for answer in answers {
                let (mut s, _) = l.accept().unwrap();
                let mut r = std::io::BufReader::new(s.try_clone().unwrap());
                let mut seen = String::new();
                loop {
                    let mut line = String::new();
                    r.read_line(&mut line).unwrap();
                    if line == "\r\n" || line.is_empty() {
                        break;
                    }
                    seen.push_str(&line);
                }
                tx.send(seen).unwrap();
                s.write_all(answer.as_bytes()).unwrap();
            }
        });
        (url, rx)
    }

    #[test]
    fn finds_the_running_version_and_asks_it_to_quit() {
        let (url, seen) = fake_page(vec![
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"version\":\"0.2.0\",\"name\":\"pc\"}",
            "HTTP/1.1 200 OK\r\n\r\nstopping",
        ]);
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("settings-url.txt");
        std::fs::write(&file, format!("{url}\n")).unwrap();

        let running = find(&file).unwrap();
        assert_eq!(running.url, url);
        assert_eq!(running.version.as_deref(), Some("0.2.0"));
        let host = url.trim_start_matches("http://").split('/').next().unwrap();
        let get = seen.recv().unwrap();
        assert!(
            get.starts_with("GET /s3cret/api/state HTTP/1.0\r\n"),
            "{get}"
        );
        assert!(get.contains(&format!("Host: {host}\r\n")), "{get}");

        ask_to_quit(&running.url).unwrap();
        let post = seen.recv().unwrap();
        assert!(
            post.starts_with("POST /s3cret/api/quit HTTP/1.0\r\n"),
            "{post}"
        );
        assert!(post.contains("X-PairDesk: 1\r\n"), "{post}");
    }

    #[test]
    fn unknown_when_the_page_does_not_answer() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("settings-url.txt");
        assert_eq!(find(&file), None, "no file");

        // A stale address: nothing listens there any more.
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let url = format!("http://127.0.0.1:{port}/x/");
        std::fs::write(&file, &url).unwrap();
        assert_eq!(
            find(&file),
            Some(Running {
                url: url.clone(),
                version: None
            })
        );
        assert!(ask_to_quit(&url).is_err());
    }

    #[test]
    fn only_talks_to_this_computer() {
        assert!(request("http://192.0.2.1:80/x/", "GET", "api/state").is_err());
        assert!(request("https://127.0.0.1:80/x/", "GET", "api/state").is_err());
    }
}
