// SPDX-License-Identifier: GPL-3.0-or-later
//! Screen view: streams the screen to a phone, as H.264 video when the
//! phone can decode it, otherwise as changed JPEG rectangles.
//!
//! Each viewer has its own capture thread. The phone acknowledges every
//! frame; with two frames unacknowledged the thread waits, so a slow link
//! gets fewer frames instead of a growing delay.

pub mod capture;
pub mod encode;
pub mod video;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub use capture::Monitor;
use encode::{Quality, Scaler};

/// Frames allowed on the way before waiting for the phone.
const MAX_IN_FLIGHT: u32 = 2;
/// Between frames the pointer is checked this often and sent on its own
/// (a tiny frame), so it follows the finger without waiting for a frame.
const CURSOR_POLL: Duration = Duration::from_millis(16);
/// Stop if the phone hasn't acknowledged anything for this long.
const ACK_TIMEOUT: Duration = Duration::from_secs(15);

pub enum Out {
    Frame(Vec<u8>),
    /// The stream ended on the computer's side.
    Stopped(String),
}

/// How frames are encoded for this viewer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Codec {
    Jpeg,
    H264,
}

impl Codec {
    pub fn name(self) -> &'static str {
        match self {
            Codec::Jpeg => "jpeg",
            Codec::H264 => "h264",
        }
    }
}

#[derive(Default)]
struct Credit {
    sent: u32,
    acked: u32,
}

pub struct Viewer {
    pub monitor: Monitor,
    pub size: (u32, u32),
    pub codec: Codec,
    stop: Arc<AtomicBool>,
    refresh: Arc<AtomicBool>,
    credit: Arc<(Mutex<Credit>, Condvar)>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Viewer {
    /// Starts streaming `monitor` (or the main one), as H.264 if `codecs`
    /// (what the phone can decode) includes "h264". `out` returns false when
    /// the phone is gone.
    pub fn start(
        monitor: Option<u32>,
        quality: Quality,
        codecs: &[String],
        out: impl Fn(Out) -> bool + Send + 'static,
    ) -> Result<(Viewer, Vec<Monitor>), String> {
        if let Some(reason) = capture::unsupported_reason() {
            return Err(reason);
        }
        let monitors = capture::monitors()?;
        let chosen = monitor
            .and_then(|i| monitors.iter().find(|m| m.index == i))
            .or_else(|| monitors.iter().find(|m| m.primary))
            .unwrap_or(&monitors[0])
            .clone();
        let size = encode::scaled_size(chosen.width, chosen.height, quality.max_width);
        let video = if codecs.iter().any(|c| c == "h264") {
            match video::VideoEncoder::new(size.0, size.1, &quality) {
                Ok(e) => Some(e),
                Err(e) => {
                    log::warn!("{e}; sending JPEG instead");
                    None
                }
            }
        } else {
            None
        };
        let codec = if video.is_some() {
            Codec::H264
        } else {
            Codec::Jpeg
        };

        let stop = Arc::new(AtomicBool::new(false));
        let refresh = Arc::new(AtomicBool::new(false));
        let credit = Arc::new((Mutex::new(Credit::default()), Condvar::new()));
        let thread = {
            let (stop, refresh, credit, mon) = (
                stop.clone(),
                refresh.clone(),
                credit.clone(),
                chosen.clone(),
            );
            std::thread::Builder::new()
                .name("screen-view".into())
                .spawn(move || {
                    let reason = run(mon, size, quality, video, &stop, &refresh, &credit, &out);
                    if let Some(reason) = reason {
                        out(Out::Stopped(reason));
                    }
                })
                .map_err(|e| e.to_string())?
        };
        Ok((
            Viewer {
                monitor: chosen,
                size,
                codec,
                stop,
                refresh,
                credit,
                thread: Some(thread),
            },
            monitors,
        ))
    }

    pub fn ack(&self, seq: u32) {
        let (lock, cv) = &*self.credit;
        let mut c = lock.lock().unwrap_or_else(|p| p.into_inner());
        if seq > c.acked && seq <= c.sent {
            c.acked = seq;
        }
        cv.notify_all();
    }

    /// Sends the whole screen again on the next frame.
    pub fn refresh(&self) {
        self.refresh.store(true, Ordering::Relaxed);
    }

    pub fn stop_flag(&self) -> Arc<AtomicBool> {
        self.stop.clone()
    }

    /// Maps a point on the shown image (0..1) to virtual-desktop pixels.
    pub fn to_desktop(&self, x: f64, y: f64) -> (i32, i32) {
        let m = &self.monitor;
        let x = x.clamp(0.0, 1.0) * (m.width.saturating_sub(1)) as f64;
        let y = y.clamp(0.0, 1.0) * (m.height.saturating_sub(1)) as f64;
        (m.x + x.round() as i32, m.y + y.round() as i32)
    }
}

impl Drop for Viewer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.credit.1.notify_all();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// The capture loop. Returns why it stopped, if the phone should be told.
#[allow(clippy::too_many_arguments)]
fn run(
    monitor: Monitor,
    (w, h): (u32, u32),
    quality: Quality,
    mut video: Option<video::VideoEncoder>,
    stop: &AtomicBool,
    refresh: &AtomicBool,
    credit: &(Mutex<Credit>, Condvar),
    out: &dyn Fn(Out) -> bool,
) -> Option<String> {
    let mut capturer = match capture::Capturer::new(monitor.clone()) {
        Ok(c) => c,
        Err(e) => return Some(format!("Can't capture the screen: {e}")),
    };
    let mut scaler = Scaler::default();
    let fps = if video.is_some() {
        quality.video_fps
    } else {
        quality.fps
    };
    let interval = Duration::from_millis(1000 / fps.max(1) as u64);
    // A frame that only moves the cursor.
    let cursor_frame = |seq: u32, cursor: Option<(i32, i32)>, video: bool| {
        if video {
            video::frame_message(seq, w, h, cursor, false, &[])
        } else {
            encode::frame_message(seq, w, h, cursor, &[])
        }
    };
    let mut prev: Option<Vec<u8>> = None;
    let mut last_cursor: Option<(i32, i32)> = None;
    let mut flush_pending = false;
    let mut seq: u32 = 0;
    let mut failing_since: Option<Instant> = None;
    log::info!(
        "screen view started: {} ({}×{} → {w}×{h}, {}, {fps} fps)",
        monitor.name,
        monitor.width,
        monitor.height,
        if video.is_some() {
            format!("H.264 {} kbit/s", quality.bitrate / 1000)
        } else {
            format!("JPEG quality {}", quality.jpeg)
        },
    );

    loop {
        if stop.load(Ordering::Relaxed) {
            return None;
        }
        // Wait while the phone is behind.
        {
            let (lock, cv) = credit;
            let mut c = lock.lock().unwrap_or_else(|p| p.into_inner());
            let waiting_since = Instant::now();
            while c.sent.wrapping_sub(c.acked) >= MAX_IN_FLIGHT && !stop.load(Ordering::Relaxed) {
                if waiting_since.elapsed() > ACK_TIMEOUT {
                    return Some("The phone stopped receiving the screen.".into());
                }
                c = cv
                    .wait_timeout(c, Duration::from_millis(250))
                    .unwrap_or_else(|p| p.into_inner())
                    .0;
            }
        }
        if stop.load(Ordering::Relaxed) {
            return None;
        }

        let started = Instant::now();
        let frame = match capturer.capture() {
            Ok(f) => {
                failing_since = None;
                f
            }
            Err(e) => {
                // Lock screen, UAC prompt, display switching… keep trying.
                if failing_since.is_none() {
                    log::warn!("screen capture failed: {e}");
                }
                failing_since.get_or_insert_with(Instant::now);
                std::thread::sleep(Duration::from_millis(500));
                continue;
            }
        };
        let scaled = match scaler.scale(&frame.data, frame.width, frame.height, w, h) {
            Ok(s) => s,
            Err(e) => return Some(format!("Can't scale the screen: {e}")),
        };
        if refresh.swap(false, Ordering::Relaxed) {
            prev = None;
        }
        let m = capturer.monitor();
        let cursor = encode::scale_cursor(capturer.cursor(), m.x, m.y, m.width, m.height, w, h);

        // The message to send, if anything changed, and whether the picture
        // went out (so `prev` moves on).
        let message = if let Some(enc) = video.as_mut() {
            let changed = prev.as_deref() != Some(&scaled[..]);
            let mut picture = Vec::new();
            let mut key = false;
            // One repeat after a change: some phone decoders show a picture
            // only when the next one arrives. A repeat is a few bytes.
            let flush = !changed && std::mem::take(&mut flush_pending);
            if changed || flush {
                // No previous picture: first frame or a refresh, so a key frame.
                match enc.encode(&scaled, prev.is_none()) {
                    Ok((data, k)) => (picture, key) = (data, k),
                    Err(e) => return Some(format!("Can't encode the screen: {e}")),
                }
            }
            let sent_picture = !picture.is_empty();
            if sent_picture && changed {
                flush_pending = true;
            }
            (sent_picture || cursor != last_cursor).then(|| {
                let seq = seq.wrapping_add(1);
                (
                    video::frame_message(seq, w, h, cursor, key, &picture),
                    sent_picture,
                )
            })
        } else {
            let rects = encode::changed_rects(prev.as_deref(), &scaled, w, h);
            if !rects.is_empty() || cursor != last_cursor {
                let mut parts = Vec::with_capacity(rects.len());
                for r in rects {
                    match encode::encode_rect(&scaled, w, r, quality.jpeg) {
                        Ok(jpeg) => parts.push((r, jpeg)),
                        Err(e) => return Some(format!("Can't encode the screen: {e}")),
                    }
                }
                let seq = seq.wrapping_add(1);
                Some((encode::frame_message(seq, w, h, cursor, &parts), true))
            } else {
                None
            }
        };
        if let Some((message, picture_sent)) = message {
            seq = seq.wrapping_add(1);
            {
                let mut c = credit.0.lock().unwrap_or_else(|p| p.into_inner());
                c.sent = seq;
            }
            if !out(Out::Frame(message)) {
                return None;
            }
            if picture_sent {
                prev = Some(scaled);
            }
            last_cursor = cursor;
        }

        // Until the next frame: just the pointer, when it moves.
        let next = started + interval;
        while let Some(left) = next.checked_duration_since(Instant::now()) {
            std::thread::sleep(left.min(CURSOR_POLL));
            if stop.load(Ordering::Relaxed) {
                return None;
            }
            let m = capturer.monitor();
            let cursor = encode::scale_cursor(capturer.cursor(), m.x, m.y, m.width, m.height, w, h);
            if cursor == last_cursor {
                continue;
            }
            {
                let mut c = credit.0.lock().unwrap_or_else(|p| p.into_inner());
                if c.sent.wrapping_sub(c.acked) >= MAX_IN_FLIGHT {
                    continue;
                }
                seq = seq.wrapping_add(1);
                c.sent = seq;
            }
            if !out(Out::Frame(cursor_frame(seq, cursor, video.is_some()))) {
                return None;
            }
            last_cursor = cursor;
        }
    }
}
