// SPDX-License-Identifier: GPL-3.0-or-later
//! Two-way sound between the computer and a phone.
//!
//! - **Listening** (computer → phone): the computer's sound and/or its
//!   microphone, mixed, as 20 ms Opus packets (48 kHz stereo) in "PDA1"
//!   binary messages. Phones that can't decode Opus get 16-bit PCM.
//! - **Talking** (phone → computer): the phone's microphone as 16 kHz mono
//!   G.711 µ-law in "PDM1" binary messages, played on the speakers. The
//!   speakers open with the first packet and close after a few seconds of
//!   quiet.
//!
//! Binary layout, agent → phone: `"PDA1" | seq u32 BE | payload`. An
//! empty payload is 20 ms of silence (nothing is playing).
//! Phone → agent: `"PDM1" | µ-law bytes`.

pub mod codec;
mod echo;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(windows)]
mod windows;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

#[cfg(target_os = "linux")]
use linux as backend;
#[cfg(windows)]
use windows as backend;

use codec::{CHANNELS, FRAME, Ring, Ticker};

pub const LISTEN_MAGIC: &[u8; 4] = b"PDA1";
pub const TALK_MAGIC: &[u8; 4] = b"PDM1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// Whatever the computer is playing.
    System,
    /// The computer's microphone.
    Microphone,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Codec {
    Opus,
    Pcm,
}

impl Codec {
    /// The phone's first choice among what it can decode.
    pub fn choose(codecs: &[String]) -> Option<Self> {
        codecs.iter().find_map(|c| match c.as_str() {
            "opus" => Some(Codec::Opus),
            "pcm" => Some(Codec::Pcm),
            _ => None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Codec::Opus => "opus",
            Codec::Pcm => "pcm",
        }
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod backend {
    use super::*;
    pub struct Device;
    pub fn capture(_: Source, _: Arc<Ring>) -> Result<Device, String> {
        Err("sound isn't supported on this system".into())
    }
    pub fn playback(_: Arc<Ring>) -> Result<Device, String> {
        Err("sound isn't supported on this system".into())
    }
}

/// Sends the computer's sound and/or microphone to a phone until dropped.
pub struct Listener {
    pub codec: Codec,
    pub pre_skip: u16,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Listener {
    /// Opens the devices and starts sending. `out` gets each binary
    /// message; it returns false when the phone is gone. `stopped` is
    /// called once if sound ends by itself (a device failed).
    pub fn start(
        sound: bool,
        mic: bool,
        codec: Codec,
        mut out: impl FnMut(Vec<u8>) -> bool + Send + 'static,
        stopped: impl FnOnce(String) + Send + 'static,
    ) -> Result<Self, String> {
        let mut sources = Vec::new();
        let mut devices = Vec::new();
        for (on, source) in [(sound, Source::System), (mic, Source::Microphone)] {
            if on {
                let ring = Arc::new(Ring::new(200));
                devices.push(backend::capture(source, ring.clone())?);
                sources.push(ring);
            }
        }
        if sources.is_empty() {
            return Err("nothing to listen to".into());
        }
        // Music needs more than a voice.
        let mut encoder = match codec {
            Codec::Opus => Some(codec::Encoder::new(if sound { 96_000 } else { 48_000 })?),
            Codec::Pcm => None,
        };
        let pre_skip = encoder.as_ref().map_or(0, |e| e.pre_skip());
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        let thread = std::thread::Builder::new()
            .name("pairdesk-listen".into())
            .spawn(move || {
                let _devices = devices;
                // Removes the phone's own voice when it talks too.
                let mut echo = match echo::EchoCanceller::new() {
                    Ok(e) => Some(e),
                    Err(e) => {
                        log::warn!("{e}; the phone may hear itself while talking");
                        None
                    }
                };
                let mut ticker = Ticker::new();
                let mut mixed = vec![0i16; FRAME * CHANNELS];
                let mut part = vec![0i16; FRAME * CHANNELS];
                let mut seq: u32 = 0;
                while !flag.load(Ordering::Relaxed) {
                    let due = ticker.next();
                    // Waits for the first source's 20 ms, but never past
                    // its time: silence is padded in (Windows loopback
                    // sends nothing while nothing plays).
                    sources[0].wait_for(FRAME * CHANNELS, due);
                    if let Some(wait) = due.checked_duration_since(Instant::now()) {
                        std::thread::sleep(wait);
                    }
                    sources[0].take(&mut mixed);
                    for s in &sources[1..] {
                        s.take(&mut part);
                        codec::mix_into(&mut mixed, &part);
                    }
                    if let Some(e) = echo.as_mut() {
                        e.process(&mut mixed);
                    }
                    // An empty payload means 20 ms of silence.
                    let payload = if codec::is_silent(&mixed) {
                        Vec::new()
                    } else {
                        match encoder.as_mut() {
                            Some(e) => match e.encode(&mixed) {
                                Ok(p) => p,
                                Err(e) => {
                                    stopped(e);
                                    return;
                                }
                            },
                            None => mixed.iter().flat_map(|s| s.to_le_bytes()).collect(),
                        }
                    };
                    let mut msg = Vec::with_capacity(8 + payload.len());
                    msg.extend_from_slice(LISTEN_MAGIC);
                    msg.extend_from_slice(&seq.to_be_bytes());
                    msg.extend_from_slice(&payload);
                    seq = seq.wrapping_add(1);
                    if !out(msg) {
                        return;
                    }
                }
            })
            .map_err(|e| e.to_string())?;
        Ok(Self {
            codec,
            pre_skip,
            stop,
            thread: Some(thread),
        })
    }

    pub fn stop_flag(&self) -> Arc<AtomicBool> {
        self.stop.clone()
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Plays a phone's voice on the computer's speakers.
pub struct Speaker {
    ring: Arc<Ring>,
    last_sample: i16,
    alive: Arc<AtomicBool>,
}

/// The speakers close after this long without voice.
const SPEAKER_IDLE: Duration = Duration::from_secs(3);

impl Speaker {
    pub fn open() -> Result<Self, String> {
        let ring = Arc::new(Ring::for_speakers(400));
        let device = backend::playback(ring.clone())?;
        let alive = Arc::new(AtomicBool::new(true));
        let (flag, watched) = (alive.clone(), ring.clone());
        // Closes the device once the phone stops talking.
        std::thread::Builder::new()
            .name("pairdesk-speaker".into())
            .spawn(move || {
                let _device = device;
                let mut quiet_since = Instant::now();
                while flag.load(Ordering::Relaxed) {
                    std::thread::sleep(Duration::from_millis(200));
                    if watched.len() > 0 {
                        quiet_since = Instant::now();
                    } else if quiet_since.elapsed() > SPEAKER_IDLE {
                        break;
                    }
                }
                flag.store(false, Ordering::Relaxed);
            })
            .map_err(|e| e.to_string())?;
        Ok(Self {
            ring,
            last_sample: 0,
            alive,
        })
    }

    /// False once the speakers closed (idle); open a new one.
    pub fn is_open(&self) -> bool {
        self.alive.load(Ordering::Relaxed)
    }

    /// One "PDM1" payload: µ-law, 16 kHz mono.
    pub fn play(&mut self, ulaw: &[u8]) {
        let pcm = codec::voice_to_working(ulaw, &mut self.last_sample);
        self.ring.push(&pcm);
    }
}

impl Drop for Speaker {
    fn drop(&mut self) {
        self.alive.store(false, Ordering::Relaxed);
        self.ring.clear();
    }
}

/// The payload of a phone's "PDM1" message.
pub fn parse_talk(data: &[u8]) -> Option<&[u8]> {
    data.strip_prefix(TALK_MAGIC.as_slice())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codec_choice_follows_the_phone() {
        let v = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(Codec::choose(&v(&["opus", "pcm"])), Some(Codec::Opus));
        assert_eq!(Codec::choose(&v(&["aac", "pcm"])), Some(Codec::Pcm));
        assert_eq!(Codec::choose(&v(&["aac"])), None);
    }

    #[test]
    fn talk_messages() {
        assert_eq!(parse_talk(b"PDM1abc"), Some(&b"abc"[..]));
        assert_eq!(parse_talk(b"PDF1abc"), None);
    }
}
