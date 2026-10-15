// SPDX-License-Identifier: GPL-3.0-or-later
//! This computer's addresses, sorted into home-network (LAN) and
//! Tailscale addresses, without the virtual adapters that Docker, WSL,
//! VirtualBox and friends create (phones can never reach those).

use std::net::{IpAddr, Ipv4Addr};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Lan,
    Tailscale,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Addr {
    pub ip: Ipv4Addr,
    pub interface: String,
    pub kind: Kind,
}

/// Tailscale gives devices addresses in 100.64.0.0/10 (the CGNAT range).
pub fn in_tailscale_range(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    a == 100 && (64..=127).contains(&b)
}

/// Adapters that only exist inside this computer.
pub fn is_virtual_adapter(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    const PREFIXES: &[&str] = &[
        "docker", "br-", "veth", "virbr", "vboxnet", "vmnet", "lxcbr", "lxdbr", "podman", "cni",
        "flannel", "zt",
    ];
    const ANYWHERE: &[&str] = &[
        "vethernet",
        "wsl",
        "virtualbox",
        "vmware",
        "hyper-v",
        "loopback",
    ];
    PREFIXES.iter().any(|p| n.starts_with(p)) || ANYWHERE.iter().any(|p| n.contains(p))
}

/// Sorts interface addresses: home network first, then Tailscale.
pub fn classify(interfaces: &[(String, IpAddr)]) -> Vec<Addr> {
    let mut out: Vec<Addr> = Vec::new();
    for (name, ip) in interfaces {
        let IpAddr::V4(v4) = *ip else { continue };
        if v4.is_loopback() || v4.is_link_local() || v4.is_unspecified() || v4.is_multicast() {
            continue;
        }
        if out.iter().any(|a| a.ip == v4) {
            continue;
        }
        // A 100.64/10 address on a mobile hotspot is just carrier NAT; only
        // the Tailscale adapter's address is a Tailscale address.
        let kind = if in_tailscale_range(v4) && name.to_ascii_lowercase().contains("tailscale") {
            Kind::Tailscale
        } else {
            if is_virtual_adapter(name) {
                continue;
            }
            Kind::Lan
        };
        out.push(Addr {
            ip: v4,
            interface: name.clone(),
            kind,
        });
    }
    out.sort_by_key(|a| a.kind == Kind::Tailscale);
    out
}

/// The addresses phones can try, home network first.
pub fn addresses() -> Vec<Addr> {
    match local_ip_address::list_afinet_netifas() {
        Ok(list) => classify(&list),
        Err(_) => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v4(s: &str) -> IpAddr {
        IpAddr::V4(s.parse().unwrap())
    }

    #[test]
    fn recognises_tailscale_range() {
        assert!(in_tailscale_range("100.64.0.1".parse().unwrap()));
        assert!(in_tailscale_range("100.101.102.103".parse().unwrap()));
        assert!(in_tailscale_range("100.127.255.254".parse().unwrap()));
        assert!(!in_tailscale_range("100.63.0.1".parse().unwrap()));
        assert!(!in_tailscale_range("100.128.0.1".parse().unwrap()));
        assert!(!in_tailscale_range("192.168.1.5".parse().unwrap()));
    }

    #[test]
    fn sorts_lan_first_and_drops_virtual_adapters() {
        let list = vec![
            ("Tailscale".to_string(), v4("100.101.102.103")),
            ("lo".to_string(), v4("127.0.0.1")),
            ("docker0".to_string(), v4("172.17.0.1")),
            ("vEthernet (WSL)".to_string(), v4("172.29.80.1")),
            (
                "VirtualBox Host-Only Network".to_string(),
                v4("192.168.56.1"),
            ),
            ("Wi-Fi".to_string(), v4("192.168.1.5")),
            ("wlp2s0".to_string(), v4("10.0.0.7")),
            ("Ethernet".to_string(), v4("169.254.3.3")),
            ("rmnet_data0".to_string(), v4("100.70.1.2")),
            ("Wi-Fi".to_string(), v4("192.168.1.5")),
        ];
        let got = classify(&list);
        let summary: Vec<_> = got.iter().map(|a| (a.ip.to_string(), a.kind)).collect();
        assert_eq!(
            summary,
            vec![
                ("192.168.1.5".into(), Kind::Lan),
                ("10.0.0.7".into(), Kind::Lan),
                ("100.70.1.2".into(), Kind::Lan),
                ("100.101.102.103".into(), Kind::Tailscale),
            ]
        );
    }

    #[test]
    fn real_adapters_are_not_virtual() {
        for name in [
            "Wi-Fi",
            "Ethernet",
            "wlan0",
            "eth0",
            "enp3s0",
            "wlp2s0",
            "Tailscale",
            "tailscale0",
        ] {
            assert!(!is_virtual_adapter(name), "{name}");
        }
        for name in [
            "docker0",
            "br-1a2b",
            "veth12",
            "virbr0",
            "vEthernet (WSL)",
            "vmnet8",
            "VMware Network Adapter VMnet1",
        ] {
            assert!(is_virtual_adapter(name), "{name}");
        }
    }
}
