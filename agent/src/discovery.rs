// SPDX-License-Identifier: GPL-3.0-or-later
//! Announces this computer on the local network (mDNS / DNS-SD) as
//! `_pairdesk._tcp`, so a paired phone can find it again after its IP
//! address changes. Discovery only helps find the address; the phone
//! still checks the pinned certificate before trusting it.

use mdns_sd::{ServiceDaemon, ServiceInfo};

pub const SERVICE_TYPE: &str = "_pairdesk._tcp.local.";

pub struct Announcer {
    daemon: ServiceDaemon,
    fullname: String,
}

impl Announcer {
    pub fn start(name: &str, short_id: &str, port: u16) -> Result<Self, String> {
        let daemon = ServiceDaemon::new().map_err(|e| e.to_string())?;
        // DNS labels allow letters, digits and hyphens.
        let host_label: String = name
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .take(40)
            .collect();
        let host = format!("{}-{}.local.", host_label.trim_matches('-'), &short_id[..6]);
        let instance: String = format!("{} {}", name, &short_id[..4])
            .chars()
            .take(60)
            .collect();
        let props = [("id", short_id), ("v", "2")];
        let info = ServiceInfo::new(SERVICE_TYPE, &instance, &host, "", port, &props[..])
            .map_err(|e| e.to_string())?
            .enable_addr_auto();
        let fullname = info.get_fullname().to_string();
        daemon.register(info).map_err(|e| e.to_string())?;
        Ok(Self { daemon, fullname })
    }

    pub fn stop(self) {
        if let Ok(rx) = self.daemon.unregister(&self.fullname) {
            let _ = rx.recv_timeout(std::time::Duration::from_millis(500));
        }
        let _ = self.daemon.shutdown();
    }
}
