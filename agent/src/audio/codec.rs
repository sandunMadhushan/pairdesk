// SPDX-License-Identifier: GPL-3.0-or-later
//! Sound formats: Opus (computer → phone), G.711 µ-law (phone voice →
//! computer), and the conversions between device formats and PairDesk's
//! working format: 48 kHz, stereo, 16-bit.

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use unsafe_libopus::{
    OPUS_APPLICATION_AUDIO, OPUS_GET_LOOKAHEAD_REQUEST, OPUS_OK, OPUS_SET_BITRATE_REQUEST,
    OPUS_SET_COMPLEXITY_REQUEST, OPUS_SET_INBAND_FEC_REQUEST, OpusEncoder, opus_encode,
    opus_encoder_create, opus_encoder_ctl, opus_encoder_destroy,
};
#[cfg(test)]
use unsafe_libopus::{OpusDecoder, opus_decode, opus_decoder_create, opus_decoder_destroy};

/// PairDesk's working format.
pub const RATE: u32 = 48_000;
pub const CHANNELS: usize = 2;
/// One packet: 20 ms.
pub const FRAME_MS: u32 = 20;
pub const FRAME: usize = (RATE / 1000 * FRAME_MS) as usize; // 960 frames

// ---------------------------------------------------------------- Opus

pub struct Encoder {
    enc: *mut OpusEncoder,
    lookahead: i32,
}

// The encoder is used from one thread at a time.
unsafe impl Send for Encoder {}

impl Encoder {
    /// 48 kHz stereo. `bitrate` in bit/s.
    pub fn new(bitrate: i32) -> Result<Self, String> {
        let mut err = 0;
        let enc = unsafe {
            opus_encoder_create(
                RATE as i32,
                CHANNELS as i32,
                OPUS_APPLICATION_AUDIO,
                &mut err,
            )
        };
        if enc.is_null() || err != OPUS_OK {
            return Err(format!("Opus encoder: error {err}"));
        }
        let mut lookahead = 0i32;
        unsafe {
            opus_encoder_ctl!(enc, OPUS_SET_BITRATE_REQUEST, bitrate);
            // Plenty for 48 kHz stereo on any computer, even this
            // translated-to-Rust Opus.
            opus_encoder_ctl!(enc, OPUS_SET_COMPLEXITY_REQUEST, 5);
            opus_encoder_ctl!(enc, OPUS_SET_INBAND_FEC_REQUEST, 0);
            opus_encoder_ctl!(enc, OPUS_GET_LOOKAHEAD_REQUEST, &mut lookahead);
        }
        Ok(Self { enc, lookahead })
    }

    /// Samples the decoder should drop at the start (Ogg "pre-skip").
    pub fn pre_skip(&self) -> u16 {
        self.lookahead.clamp(0, u16::MAX as i32) as u16
    }

    /// Encodes one 20 ms frame (FRAME × 2 interleaved samples).
    pub fn encode(&mut self, pcm: &[i16]) -> Result<Vec<u8>, String> {
        debug_assert_eq!(pcm.len(), FRAME * CHANNELS);
        let mut out = vec![0u8; 1500];
        let n = unsafe {
            opus_encode(
                self.enc,
                pcm.as_ptr(),
                FRAME as i32,
                out.as_mut_ptr(),
                out.len() as i32,
            )
        };
        if n < 0 {
            return Err(format!("Opus encode: error {n}"));
        }
        out.truncate(n as usize);
        Ok(out)
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        unsafe { opus_encoder_destroy(self.enc) };
    }
}

/// For tests (the phone decodes with Android's own decoder).
#[cfg(test)]
pub struct Decoder {
    dec: *mut OpusDecoder,
}

#[cfg(test)]
impl Decoder {
    pub fn new() -> Result<Self, String> {
        let mut err = 0;
        let dec = unsafe { opus_decoder_create(RATE as i32, CHANNELS as i32, &mut err) };
        if dec.is_null() || err != OPUS_OK {
            return Err(format!("Opus decoder: error {err}"));
        }
        Ok(Self { dec })
    }

    pub fn decode(&mut self, packet: &[u8]) -> Result<Vec<i16>, String> {
        let mut pcm = vec![0i16; FRAME * CHANNELS * 6];
        let n = unsafe {
            opus_decode(
                self.dec,
                packet.as_ptr(),
                packet.len() as i32,
                pcm.as_mut_ptr(),
                (pcm.len() / CHANNELS) as i32,
                0,
            )
        };
        if n < 0 {
            return Err(format!("Opus decode: error {n}"));
        }
        pcm.truncate(n as usize * CHANNELS);
        Ok(pcm)
    }
}

#[cfg(test)]
impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe { opus_decoder_destroy(self.dec) };
    }
}

// --------------------------------------------------------------- µ-law

/// G.711 µ-law byte → 16-bit sample.
pub fn ulaw_decode(b: u8) -> i16 {
    let u = !b;
    let sign = u & 0x80;
    let exponent = (u >> 4) & 0x07;
    let mantissa = u & 0x0f;
    let magnitude = ((((mantissa as i32) << 3) + 0x84) << exponent) - 0x84;
    if sign != 0 {
        -magnitude as i16
    } else {
        magnitude as i16
    }
}

/// 16-bit sample → G.711 µ-law byte (the phone's side, here for tests).
#[cfg(test)]
pub fn ulaw_encode(sample: i16) -> u8 {
    const BIAS: i32 = 0x84;
    const CLIP: i32 = 32635;
    let mut s = sample as i32;
    let sign = if s < 0 {
        s = -s;
        0x80
    } else {
        0
    };
    let s = s.min(CLIP) + BIAS;
    let exponent = (31 - (s as u32).leading_zeros() as i32 - 7).clamp(0, 7);
    let mantissa = (s >> (exponent + 3)) & 0x0f;
    !(sign | (exponent << 4) | mantissa) as u8
}

/// Phone voice (16 kHz mono µ-law) → 48 kHz stereo, by linear
/// interpolation; `last` carries the previous sample across packets.
pub fn voice_to_working(ulaw: &[u8], last: &mut i16) -> Vec<i16> {
    let mut out = Vec::with_capacity(ulaw.len() * 3 * CHANNELS);
    for &b in ulaw {
        let s = ulaw_decode(b) as i32;
        let p = *last as i32;
        for k in 1..=3 {
            let v = (p * (3 - k) + s * k) / 3;
            out.push(v as i16);
            out.push(v as i16);
        }
        *last = s as i16;
    }
    out
}

// ---------------------------------------------------------- resampling

/// Any device format → 48 kHz stereo i16 (capture), or back (playback):
/// channel mapping plus linear interpolation between rates.
#[cfg_attr(not(windows), allow(dead_code))]
pub struct Resampler {
    /// Input frames per output frame.
    step: f64,
    pos: f64,
    prev: [f32; 2],
    cur: [f32; 2],
    have_cur: bool,
}

#[cfg_attr(not(windows), allow(dead_code))]
impl Resampler {
    pub fn new(rate_in: u32, rate_out: u32) -> Self {
        Self {
            step: rate_in as f64 / rate_out as f64,
            pos: 0.0,
            prev: [0.0; 2],
            cur: [0.0; 2],
            have_cur: false,
        }
    }

    /// Feeds stereo frames (f32, -1..1); pushes the resampled frames.
    pub fn process(
        &mut self,
        input: impl IntoIterator<Item = [f32; 2]>,
        mut out: impl FnMut([f32; 2]),
    ) {
        for frame in input {
            if !self.have_cur {
                self.cur = frame;
                self.prev = frame;
                self.have_cur = true;
                continue;
            }
            self.prev = self.cur;
            self.cur = frame;
            // Emit every output frame that falls between prev and cur.
            while self.pos < 1.0 {
                let t = self.pos as f32;
                out([
                    self.prev[0] + (self.cur[0] - self.prev[0]) * t,
                    self.prev[1] + (self.cur[1] - self.prev[1]) * t,
                ]);
                self.pos += self.step;
            }
            self.pos -= 1.0;
        }
    }
}

/// Device frame (any number of channels) → stereo. 5.1 and up fold the
/// centre and rear channels in.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn to_stereo(frame: &[f32]) -> [f32; 2] {
    match frame.len() {
        0 => [0.0; 2],
        1 => [frame[0]; 2],
        2..=5 => [frame[0], frame[1]],
        _ => {
            let c = frame[2] * 0.7;
            [
                (frame[0] + c + frame[4] * 0.7).clamp(-1.0, 1.0),
                (frame[1] + c + frame[5] * 0.7).clamp(-1.0, 1.0),
            ]
        }
    }
}

#[cfg_attr(not(windows), allow(dead_code))]
pub fn f32_to_i16(v: f32) -> i16 {
    (v.clamp(-1.0, 1.0) * 32767.0) as i16
}

#[cfg_attr(not(windows), allow(dead_code))]
pub fn i16_to_f32(v: i16) -> f32 {
    v as f32 / 32768.0
}

// ---------------------------------------------------------- ring buffer

/// Interleaved 48 kHz stereo samples between a device thread and the
/// mixer (or the network and a playback device). Old samples are dropped
/// when it fills, to keep the delay short.
pub struct Ring {
    buf: Mutex<VecDeque<i16>>,
    ready: Condvar,
    max: usize,
    /// The speakers' ring: what's taken is the echo canceller's reference.
    speakers: bool,
}

impl Ring {
    /// Holds at most `max_ms` of sound.
    pub fn new(max_ms: u32) -> Self {
        Self {
            buf: Mutex::new(VecDeque::new()),
            ready: Condvar::new(),
            max: (RATE / 1000 * max_ms) as usize * CHANNELS,
            speakers: false,
        }
    }

    /// The ring the speakers play from. Each block the device takes is
    /// handed to the echo canceller at that moment, so its timing matches
    /// what really comes out of the speakers.
    pub fn for_speakers(max_ms: u32) -> Self {
        Self {
            speakers: true,
            ..Self::new(max_ms)
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, VecDeque<i16>> {
        self.buf.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn push(&self, samples: &[i16]) {
        let mut b = self.lock();
        b.extend(samples);
        if b.len() > self.max {
            // Far behind: keep only the newest 40 ms.
            let keep = (RATE / 1000 * 40) as usize * CHANNELS;
            let drop = b.len() - keep;
            b.drain(..drop);
        }
        drop(b);
        self.ready.notify_all();
    }

    /// Samples waiting.
    pub fn len(&self) -> usize {
        self.lock().len()
    }

    /// Takes exactly `out.len()` samples, padding with silence if fewer
    /// are there. Returns how many were real.
    pub fn take(&self, out: &mut [i16]) -> usize {
        let mut b = self.lock();
        let n = out.len().min(b.len());
        for (o, s) in out.iter_mut().zip(b.drain(..n)) {
            *o = s;
        }
        out[n..].fill(0);
        drop(b);
        if self.speakers {
            super::echo::played(out);
        }
        n
    }

    /// Waits until `n` samples are there or `deadline` passes.
    pub fn wait_for(&self, n: usize, deadline: Instant) {
        let mut b = self.lock();
        while b.len() < n {
            let now = Instant::now();
            if now >= deadline {
                return;
            }
            b = match self.ready.wait_timeout(b, deadline - now) {
                Ok((g, _)) => g,
                Err(p) => p.into_inner().0,
            };
        }
    }

    pub fn clear(&self) {
        self.lock().clear();
    }
}

/// Nothing to hear: only tiny values (dither, rounding). Such frames are
/// sent as empty packets, which the phone plays as silence; this Opus
/// would otherwise spend as much on silence as on music.
pub fn is_silent(samples: &[i16]) -> bool {
    samples.iter().all(|&s| s.unsigned_abs() <= 8)
}

/// Adds `src` into `dst` (saturating).
pub fn mix_into(dst: &mut [i16], src: &[i16]) {
    for (d, s) in dst.iter_mut().zip(src) {
        *d = d.saturating_add(*s);
    }
}

/// Loudness of a block, 0..1 (RMS), for tests.
#[cfg(test)]
pub fn level(samples: &[i16]) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f64 = samples.iter().map(|&s| (s as f64 / 32768.0).powi(2)).sum();
    (sum / samples.len() as f64).sqrt()
}

/// Paces a loop to real time in 20 ms steps without drifting.
pub struct Ticker {
    start: Instant,
    n: u64,
}

impl Ticker {
    pub fn new() -> Self {
        Self {
            start: Instant::now(),
            n: 0,
        }
    }

    /// When the next 20 ms frame is due.
    pub fn next(&mut self) -> Instant {
        self.n += 1;
        let due = self.start + Duration::from_millis(FRAME_MS as u64 * self.n);
        // Fell far behind (the computer was asleep): start counting again.
        if Instant::now() > due + Duration::from_millis(500) {
            self.start = Instant::now();
            self.n = 0;
            return self.start;
        }
        due
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(freq: f32, frames: usize, amp: f32) -> Vec<i16> {
        (0..frames)
            .flat_map(|i| {
                let v = f32_to_i16(
                    (i as f32 * freq * 2.0 * std::f32::consts::PI / RATE as f32).sin() * amp,
                );
                [v, v]
            })
            .collect()
    }

    #[test]
    fn opus_round_trip_keeps_the_sound() {
        let mut enc = Encoder::new(96_000).unwrap();
        let mut dec = Decoder::new().unwrap();
        assert!(enc.pre_skip() > 0 && enc.pre_skip() < 1000);
        let pcm = tone(440.0, FRAME * 10, 0.5);
        let mut out = Vec::new();
        let mut sizes = Vec::new();
        for chunk in pcm.chunks(FRAME * CHANNELS) {
            let packet = enc.encode(chunk).unwrap();
            sizes.push(packet.len());
            out.extend(dec.decode(&packet).unwrap());
        }
        assert_eq!(out.len(), pcm.len());
        // Skip the codec's start-up; then the level matches the input.
        let (a, b) = (level(&pcm[FRAME * 4..]), level(&out[FRAME * 4..]));
        assert!((a - b).abs() < 0.05, "in {a}, out {b}");
        // 96 kbit/s at 20 ms is about 240 bytes a packet.
        let avg = sizes.iter().sum::<usize>() / sizes.len();
        assert!((100..400).contains(&avg), "{avg} bytes");
        // (Silence isn't encoded at all: see `is_silent`.)
        assert!(is_silent(&[0; 8]) && !is_silent(&[0, 0, 40, 0]));
    }

    #[test]
    fn ulaw_round_trip_is_close() {
        for s in [-32768i16, -20000, -1000, -10, 0, 10, 1000, 20000, 32767] {
            let back = ulaw_decode(ulaw_encode(s));
            let err = (back as i32 - s as i32).abs();
            assert!(err <= (s as i32).abs() / 16 + 8, "{s} -> {back}");
        }
        // Known G.711 values.
        assert_eq!(ulaw_encode(0), 0xff);
        assert_eq!(ulaw_decode(0xff), 0);
        assert_eq!(ulaw_decode(0x80), 32124);
    }

    #[test]
    fn voice_is_upsampled_to_48k_stereo() {
        let bytes: Vec<u8> = (0..320)
            .map(|i| ulaw_encode(((i as f32 / 10.0).sin() * 8000.0) as i16))
            .collect();
        let mut last = 0;
        let out = voice_to_working(&bytes, &mut last);
        assert_eq!(out.len(), 320 * 3 * 2);
        assert!(level(&out) > 0.1);
        // Left and right are the same.
        assert!(out.chunks(2).all(|f| f[0] == f[1]));
    }

    #[test]
    fn resampler_converts_rates() {
        let mut r = Resampler::new(44_100, 48_000);
        let mut n = 0;
        r.process((0..44_100).map(|_| [0.5, -0.5]), |f| {
            assert!((f[0] - 0.5).abs() < 1e-4 && (f[1] + 0.5).abs() < 1e-4);
            n += 1;
        });
        assert!((47_990..=48_000).contains(&n), "{n}");
        let mut r = Resampler::new(48_000, 16_000);
        let mut n = 0;
        r.process((0..4800).map(|_| [0.0, 0.0]), |_| n += 1);
        assert!((1598..=1600).contains(&n), "{n}");
    }

    #[test]
    fn channel_mapping() {
        assert_eq!(to_stereo(&[0.3]), [0.3, 0.3]);
        assert_eq!(to_stereo(&[0.1, 0.2]), [0.1, 0.2]);
        let s = to_stereo(&[0.1, 0.2, 0.0, 0.0, 0.0, 0.0]);
        assert_eq!(s, [0.1, 0.2]);
    }

    #[test]
    fn ring_drops_old_sound_and_pads_with_silence() {
        let r = Ring::new(100);
        r.push(&vec![1; FRAME * CHANNELS * 10]); // 200 ms > 100 ms
        assert_eq!(r.len(), (RATE / 1000 * 40) as usize * CHANNELS);
        let mut out = vec![9; FRAME * CHANNELS * 3];
        let real = r.take(&mut out);
        assert_eq!(real, (RATE / 1000 * 40) as usize * CHANNELS);
        assert!(out[real..].iter().all(|&s| s == 0));
        let t = Instant::now();
        r.wait_for(10, Instant::now() + Duration::from_millis(30));
        assert!(t.elapsed() >= Duration::from_millis(25));
    }
}
