// SPDX-License-Identifier: GPL-3.0-or-later
//! Optional "keep this computer awake", so phones can reach it from
//! anywhere. A sleeping computer can't answer, and Tailscale can't wake it.
//!
//! - Windows: `SetThreadExecutionState(ES_SYSTEM_REQUIRED | ES_CONTINUOUS)`
//!   held by a small thread. The screen may still turn off, and closing the
//!   lid can still sleep the computer (that's set in Windows power options).
//! - Linux: `systemd-inhibit --what=sleep:idle … sleep infinity`.

use std::sync::Mutex;

#[derive(Default)]
pub struct KeepAwake {
    inner: Mutex<Option<platform::Hold>>,
}

impl KeepAwake {
    pub fn set(&self, on: bool) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        match (on, inner.is_some()) {
            (true, false) => {
                *inner = Some(platform::Hold::start()?);
                log::info!("keeping this computer awake");
            }
            (false, true) => {
                if let Some(h) = inner.take() {
                    h.stop();
                }
                log::info!("no longer keeping this computer awake");
            }
            _ => {}
        }
        Ok(())
    }

    pub fn is_on(&self) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .is_some()
    }
}

impl Drop for KeepAwake {
    fn drop(&mut self) {
        let _ = self.set(false);
    }
}

#[cfg(windows)]
mod platform {
    use std::sync::mpsc;
    use windows_sys::Win32::System::Power::{
        ES_CONTINUOUS, ES_SYSTEM_REQUIRED, SetThreadExecutionState,
    };

    pub struct Hold {
        stop: mpsc::Sender<()>,
        thread: std::thread::JoinHandle<()>,
    }

    impl Hold {
        pub fn start() -> Result<Self, String> {
            let (stop, rx) = mpsc::channel::<()>();
            let (ready_tx, ready_rx) = mpsc::channel::<bool>();
            // The request belongs to the thread that makes it, so a thread
            // holds it and clears it when told to stop.
            let thread = std::thread::Builder::new()
                .name("keep-awake".into())
                .spawn(move || {
                    let ok =
                        unsafe { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) } != 0;
                    let _ = ready_tx.send(ok);
                    let _ = rx.recv();
                    unsafe { SetThreadExecutionState(ES_CONTINUOUS) };
                })
                .map_err(|e| e.to_string())?;
            if ready_rx.recv().unwrap_or(false) {
                Ok(Self { stop, thread })
            } else {
                Err("Windows didn't allow PairDesk to keep the computer awake.".into())
            }
        }

        pub fn stop(self) {
            let _ = self.stop.send(());
            let _ = self.thread.join();
        }
    }
}

#[cfg(not(windows))]
mod platform {
    use std::process::{Child, Stdio};

    pub struct Hold {
        child: Child,
    }

    impl Hold {
        pub fn start() -> Result<Self, String> {
            let mut child = crate::install::host_command("systemd-inhibit")
                .args([
                    "--what=sleep:idle",
                    "--who=PairDesk",
                    "--why=Phones can connect from anywhere",
                    "--mode=block",
                    "sleep",
                    "infinity",
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| {
                    format!("This computer can't be kept awake (systemd-inhibit: {e}).")
                })?;
            // If it exits at once, the inhibitor was refused.
            std::thread::sleep(std::time::Duration::from_millis(150));
            if let Ok(Some(status)) = child.try_wait() {
                return Err(format!(
                    "This computer didn't allow PairDesk to keep it awake (systemd-inhibit {status})."
                ));
            }
            Ok(Self { child })
        }

        pub fn stop(mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}
