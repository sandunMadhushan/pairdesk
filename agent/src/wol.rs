// SPDX-License-Identifier: GPL-3.0-or-later
//! Wake-on-LAN: the computer tells paired phones its network addresses (MACs)
//! and sends "magic packets" for a sleeping computer on its own network.
//!
//! A sleeping computer runs no PairDesk, so something else has to send the
//! packet: the phone itself (same Wi-Fi) or another PairDesk computer on that
//! network (from anywhere, through the relay).

use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};

/// Most addresses one wake request or announcement carries.
pub const MAX_MACS: usize = 4;

pub type Mac = [u8; 6];

/// "aa:bb:cc:dd:ee:ff" (also with "-"). Not the all-zero or broadcast address.
pub fn parse_mac(s: &str) -> Option<Mac> {
    let parts: Vec<&str> = s.trim().split([':', '-']).collect();
    if parts.len() != 6 {
        return None;
    }
    let mut mac = [0u8; 6];
    for (i, p) in parts.iter().enumerate() {
        if p.len() != 2 {
            return None;
        }
        mac[i] = u8::from_str_radix(p, 16).ok()?;
    }
    (mac != [0; 6] && mac != [0xFF; 6]).then_some(mac)
}

pub fn format_mac(mac: &Mac) -> String {
    mac.iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(":")
}

/// 6 bytes of 0xFF, then the MAC 16 times.
pub fn magic_packet(mac: &Mac) -> [u8; 102] {
    let mut p = [0xFFu8; 102];
    for i in 0..16 {
        p[6 + i * 6..12 + i * 6].copy_from_slice(mac);
    }
    p
}

/// Sends the magic packet for each MAC to every destination. Returns how many
/// packets went out.
pub fn send_to(macs: &[Mac], destinations: &[SocketAddr]) -> usize {
    let Ok(sock) = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)) else {
        return 0;
    };
    let _ = sock.set_broadcast(true);
    let mut sent = 0;
    for mac in macs.iter().take(MAX_MACS) {
        let packet = magic_packet(mac);
        for dest in destinations {
            if sock.send_to(&packet, dest).is_ok() {
                sent += 1;
            }
        }
    }
    sent
}

/// Where to send on this network: the global broadcast and the /24 broadcast
/// of each local IPv4 address, on the usual ports 9 and 7.
pub fn broadcast_targets() -> Vec<SocketAddr> {
    let mut ips = vec![Ipv4Addr::BROADCAST];
    if let Ok(list) = local_ip_address::list_afinet_netifas() {
        for (_, ip) in list {
            if let IpAddr::V4(v4) = ip {
                if v4.is_loopback() || v4.is_link_local() {
                    continue;
                }
                let o = v4.octets();
                let b = Ipv4Addr::new(o[0], o[1], o[2], 255);
                if !ips.contains(&b) {
                    ips.push(b);
                }
            }
        }
    }
    ips.into_iter()
        .flat_map(|ip| [SocketAddr::from((ip, 9)), SocketAddr::from((ip, 7))])
        .collect()
}

/// Wakes the computers with these MACs on this network.
pub fn wake(macs: &[Mac]) -> usize {
    send_to(macs, &broadcast_targets())
}

/// This computer's network addresses that could wake it: wired first, only
/// adapters that are up. Empty when it can't tell.
pub fn own_macs() -> Vec<String> {
    // Asked on every phone connection and slow on Windows: keep it a while.
    static CACHE: std::sync::Mutex<Option<(std::time::Instant, Vec<String>)>> =
        std::sync::Mutex::new(None);
    if let Ok(cache) = CACHE.lock()
        && let Some((at, macs)) = cache.as_ref()
        && at.elapsed() < std::time::Duration::from_secs(300)
    {
        return macs.clone();
    }
    let macs = read_own_macs();
    if let Ok(mut cache) = CACHE.lock() {
        *cache = Some((std::time::Instant::now(), macs.clone()));
    }
    macs
}

fn read_own_macs() -> Vec<String> {
    let mut found = platform_macs();
    found.dedup();
    found
        .into_iter()
        .take(MAX_MACS)
        .map(|m| format_mac(&m))
        .collect()
}

#[cfg(target_os = "linux")]
fn platform_macs() -> Vec<Mac> {
    use std::path::Path;
    let mut wired = Vec::new();
    let mut wireless = Vec::new();
    let Ok(dir) = std::fs::read_dir("/sys/class/net") else {
        return Vec::new();
    };
    for entry in dir.flatten() {
        let p = entry.path();
        // Physical adapters have a `device` link; bridges, VPNs and
        // containers don't.
        if !p.join("device").exists() {
            continue;
        }
        let up = std::fs::read_to_string(p.join("operstate")).is_ok_and(|s| s.trim() == "up");
        if !up {
            continue;
        }
        let Some(mac) = std::fs::read_to_string(p.join("address"))
            .ok()
            .and_then(|s| parse_mac(&s))
        else {
            continue;
        };
        if Path::new(&p.join("wireless")).exists() {
            wireless.push(mac);
        } else {
            wired.push(mac);
        }
    }
    wired.sort();
    wireless.sort();
    wired.extend(wireless);
    wired
}

#[cfg(windows)]
fn platform_macs() -> Vec<Mac> {
    use std::os::windows::process::CommandExt;
    // `getmac` lists connected adapters with a \Device\Tcpip_{GUID} transport
    // name; disconnected ones say "Media disconnected" (translated), so the
    // transport name is what is matched, not the words.
    let out = std::process::Command::new("getmac")
        .args(["/fo", "csv", "/nh"])
        .creation_flags(0x0800_0000)
        .output();
    let Ok(out) = out else { return Vec::new() };
    parse_getmac(&String::from_utf8_lossy(&out.stdout))
}

#[cfg(not(any(target_os = "linux", windows)))]
fn platform_macs() -> Vec<Mac> {
    Vec::new()
}

/// Reads `getmac /fo csv /nh` output.
#[cfg_attr(not(windows), allow(dead_code))]
fn parse_getmac(text: &str) -> Vec<Mac> {
    text.lines()
        .filter(|l| l.contains("Tcpip_{"))
        .filter_map(|l| l.split(',').next())
        .filter_map(|f| parse_mac(f.trim().trim_matches('"')))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn macs_parse_with_colons_or_dashes() {
        assert_eq!(
            parse_mac("AA:bb:0c:01:02:03"),
            Some([0xaa, 0xbb, 0x0c, 1, 2, 3])
        );
        assert_eq!(
            parse_mac("aa-bb-0c-01-02-03"),
            Some([0xaa, 0xbb, 0x0c, 1, 2, 3])
        );
        assert_eq!(parse_mac("aa:bb:0c:01:02"), None);
        assert_eq!(parse_mac("aa:bb:0c:01:02:zz"), None);
        assert_eq!(parse_mac("00:00:00:00:00:00"), None);
        assert_eq!(parse_mac("ff:ff:ff:ff:ff:ff"), None);
        assert_eq!(
            format_mac(&[0xaa, 0xbb, 0x0c, 1, 2, 3]),
            "aa:bb:0c:01:02:03"
        );
    }

    #[test]
    fn the_magic_packet_is_six_ff_then_the_mac_sixteen_times() {
        let mac = [1, 2, 3, 4, 5, 6];
        let p = magic_packet(&mac);
        assert_eq!(&p[..6], &[0xFF; 6]);
        for i in 0..16 {
            assert_eq!(&p[6 + i * 6..12 + i * 6], &mac);
        }
        assert_eq!(p.len(), 102);
    }

    #[test]
    fn a_packet_arrives_on_a_socket() {
        let rx = UdpSocket::bind("127.0.0.1:0").unwrap();
        rx.set_read_timeout(Some(std::time::Duration::from_secs(2)))
            .unwrap();
        let dest = rx.local_addr().unwrap();
        let mac = [9, 8, 7, 6, 5, 4];
        assert_eq!(send_to(&[mac], &[dest]), 1);
        let mut buf = [0u8; 200];
        let n = rx.recv(&mut buf).unwrap();
        assert_eq!(&buf[..n], &magic_packet(&mac)[..]);
    }

    #[test]
    fn getmac_output_keeps_only_connected_adapters() {
        let text = "\"A0-B1-C2-D3-E4-F5\",\"\\Device\\Tcpip_{1234-ABCD}\"\r\n\
                    \"00-11-22-33-44-55\",\"Media disconnected\"\r\n";
        assert_eq!(
            parse_getmac(text),
            vec![[0xa0, 0xb1, 0xc2, 0xd3, 0xe4, 0xf5]]
        );
    }
}
