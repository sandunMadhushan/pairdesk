// SPDX-License-Identifier: GPL-3.0-or-later
//! Ways for a phone to reach this computer straight from the internet, with
//! no relay at all:
//!
//! - **A port on the router.** Most home routers let programs ask for a
//!   port forward (UPnP IGD; NAT-PMP on some). When the router agrees, the
//!   phone is told `public-ip:port` and tries it first. This only helps
//!   with a public address: behind the provider's own NAT (CGNAT) the
//!   router's "public" address is itself private, and it isn't offered.
//! - **IPv6.** With IPv6 there is no NAT, so the computer's global IPv6
//!   addresses are offered too (many routers still block incoming IPv6, in
//!   which case the phone moves on to the next route).
//!
//! Either way the phone checks the computer's certificate and signs in as
//! on Wi-Fi; the open port only accepts paired phones (and pairing still
//! needs the one-time code shown on this computer).

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, UdpSocket};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use log::info;
use serde::Serialize;

/// How long the router keeps the forward; renewed well before.
const LEASE_SECS: u32 = 3600;
const RENEW_EVERY: Duration = Duration::from_secs(20 * 60);
const SSDP: &str = "239.255.255.250:1900";
const DESCRIPTION: &str = "PairDesk";

#[derive(Debug, Clone, Serialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum PortState {
    #[default]
    Off,
    Trying,
    /// The router forwards `external` to this computer.
    Open,
    /// The router said no, or none answered.
    Failed,
    /// The router's own "public" address is private: the provider's NAT
    /// is in the way, so a forward can't be reached from outside.
    ProviderNat,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct Info {
    pub state: PortState,
    /// `ip:port` phones can use.
    pub external: Option<String>,
    /// "UPnP" or "NAT-PMP".
    pub method: Option<String>,
    pub detail: Option<String>,
    /// Global IPv6 addresses of this computer.
    pub ipv6: Vec<String>,
}

#[derive(Default)]
pub struct Shared {
    info: Mutex<Info>,
    wake: tokio::sync::Notify,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Shared {
    pub fn info(&self) -> Info {
        lock(&self.info).clone()
    }

    /// Addresses for phones: the router's port, then IPv6.
    pub fn phone_addresses(&self) -> Vec<String> {
        let info = lock(&self.info);
        let mut out = Vec::new();
        if info.state == PortState::Open
            && let Some(e) = &info.external
        {
            out.push(e.clone());
        }
        for a in &info.ipv6 {
            out.push(format!("[{a}]"));
        }
        out
    }

    pub fn settings_changed(&self) {
        self.wake.notify_one();
    }
}

/// IPv6 addresses that can be reached from the internet: global unicast,
/// not on virtual adapters. At most two.
fn global_ipv6() -> Vec<Ipv6Addr> {
    let Ok(list) = local_ip_address::list_afinet_netifas() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for (name, ip) in list {
        let IpAddr::V6(v6) = ip else { continue };
        if is_global_v6(v6) && !crate::net::is_virtual_adapter(&name) && !out.contains(&v6) {
            out.push(v6);
        }
    }
    out.truncate(2);
    out
}

pub fn is_global_v6(ip: Ipv6Addr) -> bool {
    // 2000::/3, minus documentation (2001:db8::/32).
    let s = ip.segments();
    (s[0] & 0xe000) == 0x2000 && !(s[0] == 0x2001 && s[1] == 0x0db8)
}

/// Private, shared (CGNAT) or otherwise unroutable IPv4 addresses.
pub fn is_private_v4(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    ip.is_private()
        || ip.is_loopback()
        || ip.is_link_local()
        || ip.is_unspecified()
        || (a == 100 && (64..=127).contains(&b))
}

/// Keeps the router's port forward and the IPv6 list up to date.
pub async fn run(state: Arc<crate::state::AppState>) {
    let mut mapped: Option<Mapping> = None;
    loop {
        let wanted = state.prefs().get().router_port;
        let ipv6: Vec<String> = global_ipv6().iter().map(|a| a.to_string()).collect();
        let before = state.portmap.phone_addresses();
        if wanted {
            if lock(&state.portmap.info).state == PortState::Off {
                lock(&state.portmap.info).state = PortState::Trying;
            }
            let port = state.port;
            let previous = mapped.clone();
            let result = tokio::task::spawn_blocking(move || map_port(port, previous.as_ref()))
                .await
                .unwrap_or_else(|_| Err("stopped".into()));
            let mut info = lock(&state.portmap.info);
            match result {
                Ok(m) if is_private_v4(*m.external.ip()) => {
                    info.state = PortState::ProviderNat;
                    info.external = None;
                    info.detail = Some(format!(
                        "The router's internet address ({}) is itself private: your provider puts \
                         you behind its own NAT, so a port forward can't be reached from outside.",
                        m.external.ip()
                    ));
                    info.method = Some(m.method.into());
                    mapped = Some(m);
                }
                Ok(m) => {
                    if info.state != PortState::Open
                        || info.external != Some(m.external.to_string())
                    {
                        info!(
                            "the router forwards {} to this computer ({})",
                            m.external, m.method
                        );
                    }
                    info.state = PortState::Open;
                    info.external = Some(m.external.to_string());
                    info.method = Some(m.method.into());
                    info.detail = None;
                    mapped = Some(m);
                }
                Err(e) => {
                    if info.state != PortState::Failed {
                        info!("router port: {e}");
                    }
                    info.state = PortState::Failed;
                    info.external = None;
                    info.method = None;
                    info.detail = Some(e);
                    mapped = None;
                }
            }
            info.ipv6 = ipv6;
        } else {
            if let Some(m) = mapped.take() {
                let _ = tokio::task::spawn_blocking(move || unmap(&m)).await;
                info!("router port closed");
            }
            let mut info = lock(&state.portmap.info);
            *info = Info {
                ipv6,
                ..Info::default()
            };
        }
        if state.portmap.phone_addresses() != before {
            state.broadcast_addresses();
        }
        tokio::select! {
            _ = tokio::time::sleep(RENEW_EVERY) => {}
            _ = state.portmap.wake.notified() => {}
        }
    }
}

#[derive(Debug, Clone)]
struct Mapping {
    method: &'static str,
    external: SocketAddrV4,
    internal: SocketAddrV4,
    /// UPnP: the control URL and service type, for renewing and removing.
    upnp: Option<(String, String)>,
    gateway: Ipv4Addr,
}

/// Asks the router for the forward, by UPnP and then NAT-PMP. Blocking.
fn map_port(port: u16, previous: Option<&Mapping>) -> Result<Mapping, String> {
    let upnp = match upnp_map(port, previous) {
        Ok(m) => return Ok(m),
        Err(e) => e,
    };
    match natpmp_map(port) {
        Ok(m) => Ok(m),
        Err(e) => Err(format!("{upnp} {e}")),
    }
}

fn unmap(m: &Mapping) {
    if let Some((url, service)) = &m.upnp {
        let args = format!(
            "<NewRemoteHost></NewRemoteHost><NewExternalPort>{}</NewExternalPort><NewProtocol>TCP</NewProtocol>",
            m.external.port()
        );
        let _ = soap(url, service, "DeletePortMapping", &args);
    } else {
        let _ = natpmp_request(m.gateway, m.internal.port(), 0, 0);
    }
}

/// The address this computer uses to reach `to`.
fn local_ip_towards(to: Ipv4Addr) -> Option<Ipv4Addr> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect((to, 9)).ok()?;
    match s.local_addr().ok()?.ip() {
        IpAddr::V4(v4) if !v4.is_unspecified() => Some(v4),
        _ => None,
    }
}

// ---------- UPnP IGD ----------

fn upnp_map(port: u16, previous: Option<&Mapping>) -> Result<Mapping, String> {
    let (url, service, gateway) =
        match previous.and_then(|m| m.upnp.clone().map(|u| (u, m.gateway))) {
            Some(((url, service), gw)) => (url, service, gw),
            None => discover()?,
        };
    let internal_ip = local_ip_towards(gateway).ok_or("no route to the router")?;
    let external_ip: Ipv4Addr = soap(&url, &service, "GetExternalIPAddress", "")
        .ok()
        .and_then(|r| tag(&r, "NewExternalIPAddress"))
        .and_then(|s| s.trim().parse().ok())
        .ok_or("the router didn't say its internet address (UPnP)")?;
    // The same outside port if it's free, else a few others.
    let first = previous.map_or(port, |m| m.external.port());
    let mut last_err = String::new();
    for external in [first, port, port + 1, port + 2, port + 3] {
        for lease in [LEASE_SECS, 0] {
            let args = format!(
                "<NewRemoteHost></NewRemoteHost><NewExternalPort>{external}</NewExternalPort>\
                 <NewProtocol>TCP</NewProtocol><NewInternalPort>{port}</NewInternalPort>\
                 <NewInternalClient>{internal_ip}</NewInternalClient><NewEnabled>1</NewEnabled>\
                 <NewPortMappingDescription>{DESCRIPTION}</NewPortMappingDescription>\
                 <NewLeaseDuration>{lease}</NewLeaseDuration>"
            );
            match soap(&url, &service, "AddPortMapping", &args) {
                Ok(_) => {
                    return Ok(Mapping {
                        method: "UPnP",
                        external: SocketAddrV4::new(external_ip, external),
                        internal: SocketAddrV4::new(internal_ip, port),
                        upnp: Some((url, service)),
                        gateway,
                    });
                }
                // 725: only permanent forwards; try again without a lease.
                Err(e) if e.contains("725") && lease != 0 => continue,
                Err(e) => {
                    last_err = e;
                    break;
                }
            }
        }
    }
    Err(format!(
        "the router refused the port forward (UPnP: {last_err})."
    ))
}

/// Finds the router's WAN connection service: (control URL, service type,
/// router address).
fn discover() -> Result<(String, String, Ipv4Addr), String> {
    let socket = UdpSocket::bind("0.0.0.0:0").map_err(|e| e.to_string())?;
    socket
        .set_read_timeout(Some(Duration::from_millis(400)))
        .map_err(|e| e.to_string())?;
    for st in [
        "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
        "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
    ] {
        let msg = format!(
            "M-SEARCH * HTTP/1.1\r\nHOST: {SSDP}\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: {st}\r\n\r\n"
        );
        let _ = socket.send_to(msg.as_bytes(), SSDP);
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    let mut buf = [0u8; 2048];
    let mut tried = Vec::new();
    while std::time::Instant::now() < deadline {
        let Ok((n, from)) = socket.recv_from(&mut buf) else {
            continue;
        };
        let text = String::from_utf8_lossy(&buf[..n]);
        let Some(location) = header(&text, "location") else {
            continue;
        };
        if tried.contains(&location) {
            continue;
        }
        tried.push(location.clone());
        let IpAddr::V4(gateway) = from.ip() else {
            continue;
        };
        // Only ask the device that answered, never a URL pointing elsewhere.
        if url_host(&location) != Some(gateway) {
            continue;
        }
        if let Some((url, service)) = wan_service(&location) {
            return Ok((url, service, gateway));
        }
    }
    Err("no router answered (UPnP is off or not supported).".into())
}

fn header(response: &str, name: &str) -> Option<String> {
    response.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.trim()
            .eq_ignore_ascii_case(name)
            .then(|| v.trim().to_string())
    })
}

fn url_host(url: &str) -> Option<Ipv4Addr> {
    let rest = url.strip_prefix("http://")?;
    let host = rest.split(['/', ':']).next()?;
    host.parse().ok()
}

/// "http://host:port" of a URL.
fn url_base(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("http://")?;
    let end = rest.find('/').map_or(url.len(), |i| i + 7);
    Some(&url[..end])
}

fn http() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(3)))
        .http_status_as_error(false)
        .build()
        .into()
}

fn wan_service(location: &str) -> Option<(String, String)> {
    let xml = http()
        .get(location)
        .call()
        .ok()?
        .body_mut()
        .with_config()
        .limit(256 * 1024)
        .read_to_string()
        .ok()?;
    let base = tag(&xml, "URLBase").unwrap_or_else(|| url_base(location).unwrap_or("").to_string());
    for block in xml.split("<service>").skip(1) {
        let service = tag(block, "serviceType")?;
        if !(service.contains("WANIPConnection") || service.contains("WANPPPConnection")) {
            continue;
        }
        let control = tag(block, "controlURL")?;
        let url = if control.starts_with("http://") {
            control
        } else {
            let base = base.trim_end_matches('/');
            let path = control.trim_start_matches('/');
            format!("{base}/{path}")
        };
        // Same device only.
        if url_host(&url) != url_host(location) {
            continue;
        }
        return Some((url, service));
    }
    None
}

fn tag(xml: &str, name: &str) -> Option<String> {
    let open = format!("<{name}>");
    let start = xml.find(&open)? + open.len();
    let end = xml[start..].find(&format!("</{name}>"))? + start;
    Some(xml[start..end].trim().to_string())
}

fn soap(url: &str, service: &str, action: &str, args: &str) -> Result<String, String> {
    let body = format!(
        "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" \
         s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>\
         <u:{action} xmlns:u=\"{service}\">{args}</u:{action}></s:Body></s:Envelope>"
    );
    let mut resp = http()
        .post(url)
        .header("Content-Type", "text/xml; charset=\"utf-8\"")
        .header("SOAPAction", format!("\"{service}#{action}\""))
        .send(body.as_bytes())
        .map_err(|e| e.to_string())?;
    let ok = resp.status().is_success();
    let text = resp
        .body_mut()
        .with_config()
        .limit(64 * 1024)
        .read_to_string()
        .unwrap_or_default();
    if ok {
        Ok(text)
    } else {
        Err(tag(&text, "errorCode").unwrap_or_else(|| resp.status().to_string()))
    }
}

// ---------- NAT-PMP (RFC 6886) ----------

fn natpmp_map(port: u16) -> Result<Mapping, String> {
    // NAT-PMP needs the router's address; the usual ".1" of each home network.
    for a in crate::net::addresses() {
        if a.kind != crate::net::Kind::Lan {
            continue;
        }
        let [x, y, z, _] = a.ip.octets();
        let gateway = Ipv4Addr::new(x, y, z, 1);
        if gateway == a.ip {
            continue;
        }
        let Ok(external_port) = natpmp_request(gateway, port, port, LEASE_SECS) else {
            continue;
        };
        let external_ip = natpmp_address(gateway).ok_or("NAT-PMP: no address")?;
        return Ok(Mapping {
            method: "NAT-PMP",
            external: SocketAddrV4::new(external_ip, external_port),
            internal: SocketAddrV4::new(a.ip, port),
            upnp: None,
            gateway,
        });
    }
    Err("NAT-PMP: no answer.".into())
}

fn natpmp_exchange(gateway: Ipv4Addr, req: &[u8], want: u8) -> Option<Vec<u8>> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect(SocketAddr::from((gateway, 5351))).ok()?;
    let mut buf = [0u8; 32];
    for wait in [250u64, 500] {
        s.set_read_timeout(Some(Duration::from_millis(wait))).ok()?;
        s.send(req).ok()?;
        if let Ok(n) = s.recv(&mut buf)
            && n >= 8
            && buf[1] == want
        {
            return Some(buf[..n].to_vec());
        }
    }
    None
}

/// Returns the mapped outside port. A lifetime of 0 removes the forward.
fn natpmp_request(
    gateway: Ipv4Addr,
    internal: u16,
    external: u16,
    lifetime: u32,
) -> Result<u16, ()> {
    let mut req = vec![0, 2, 0, 0];
    req.extend_from_slice(&internal.to_be_bytes());
    req.extend_from_slice(&external.to_be_bytes());
    req.extend_from_slice(&lifetime.to_be_bytes());
    let r = natpmp_exchange(gateway, &req, 130).ok_or(())?;
    if r.len() < 16 || u16::from_be_bytes([r[2], r[3]]) != 0 {
        return Err(());
    }
    Ok(u16::from_be_bytes([r[10], r[11]]))
}

fn natpmp_address(gateway: Ipv4Addr) -> Option<Ipv4Addr> {
    let r = natpmp_exchange(gateway, &[0, 0], 128)?;
    if r.len() < 12 || u16::from_be_bytes([r[2], r[3]]) != 0 {
        return None;
    }
    Some(Ipv4Addr::new(r[8], r[9], r[10], r[11]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_kinds() {
        assert!(is_global_v6("2a02:1234::5".parse().unwrap()));
        assert!(!is_global_v6("fe80::1".parse().unwrap()));
        assert!(!is_global_v6("fd00::1".parse().unwrap()));
        assert!(!is_global_v6("2001:db8::1".parse().unwrap()));
        assert!(is_private_v4("100.72.1.1".parse().unwrap()));
        assert!(is_private_v4("192.168.1.1".parse().unwrap()));
        assert!(!is_private_v4("203.0.113.9".parse().unwrap()));
    }

    #[test]
    fn router_description_is_read() {
        let xml = "<root><URLBase>http://192.168.1.1:5000</URLBase><device><serviceList>\
            <service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>\
            <controlURL>/ctl/L3F</controlURL></service>\
            <service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>\
            <controlURL>/ctl/IPConn</controlURL></service></serviceList></device></root>";
        assert_eq!(tag(xml, "URLBase").unwrap(), "http://192.168.1.1:5000");
        let block = xml.split("<service>").nth(2).unwrap();
        assert_eq!(tag(block, "controlURL").unwrap(), "/ctl/IPConn");
        assert_eq!(
            url_host("http://192.168.1.1:5000/rootDesc.xml"),
            Some(Ipv4Addr::new(192, 168, 1, 1))
        );
        assert_eq!(
            url_base("http://192.168.1.1:5000/rootDesc.xml"),
            Some("http://192.168.1.1:5000")
        );
        assert_eq!(
            header("HTTP/1.1 200 OK\r\nLOCATION: http://x/y\r\n", "location").as_deref(),
            Some("http://x/y")
        );
    }

    /// A pretend router on this computer: discovery is skipped, but the
    /// SOAP calls go over real HTTP.
    #[test]
    fn asks_a_router_for_the_forward() {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let port = server.server_addr().to_ip().unwrap().port();
        let seen = std::sync::Arc::new(Mutex::new(Vec::<String>::new()));
        let log = seen.clone();
        std::thread::spawn(move || {
            for mut req in server.incoming_requests() {
                let mut body = String::new();
                let _ = req.as_reader().read_to_string(&mut body);
                let answer = if body.contains("GetExternalIPAddress") {
                    "<NewExternalIPAddress>203.0.113.7</NewExternalIPAddress>".to_string()
                } else if body.contains("<NewLeaseDuration>3600") {
                    log.lock().unwrap().push("lease".into());
                    // Only permanent forwards on this one.
                    let _ = req.respond(
                        tiny_http::Response::from_string("<errorCode>725</errorCode>")
                            .with_status_code(500),
                    );
                    continue;
                } else {
                    log.lock().unwrap().push("permanent".into());
                    String::new()
                };
                let _ = req.respond(tiny_http::Response::from_string(answer));
            }
        });
        let url = format!("http://127.0.0.1:{port}/ctl");
        let previous = Mapping {
            method: "UPnP",
            external: SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 47800),
            internal: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 47800),
            upnp: Some((url, "urn:schemas-upnp-org:service:WANIPConnection:1".into())),
            gateway: Ipv4Addr::LOCALHOST,
        };
        let m = upnp_map(47800, Some(&previous)).unwrap();
        assert_eq!(
            m.external,
            SocketAddrV4::new(Ipv4Addr::new(203, 0, 113, 7), 47800)
        );
        assert_eq!(*seen.lock().unwrap(), vec!["lease", "permanent"]);
    }
}
