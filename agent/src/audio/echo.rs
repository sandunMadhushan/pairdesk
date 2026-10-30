// SPDX-License-Identifier: GPL-3.0-or-later
//! Echo cancelling, so a phone and the computer can talk both ways at once.
//!
//! The phone's voice comes out of the computer's speakers and goes back in
//! through its microphone (and, digitally, through the recorded computer
//! sound). Without cancelling, the person on the phone hears themselves a
//! moment later. This removes it with WebRTC's echo canceller (AEC3, the
//! one in Chrome and Meet), using the phone's voice as the reference.
//!
//! It only runs while the phone has talked recently: plain listening to
//! music is never touched.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use aec3::nodes::audio::AudioFormat;
use aec3::pipelines::linear::{self, LinearPipeline};

use super::codec::{CHANNELS, FRAME};

/// The phone's voice, 16 kHz mono.
const REF_RATE: u32 = 16_000;
const REF_10MS: usize = (REF_RATE / 100) as usize;
const CAP_10MS: usize = FRAME / 2 * CHANNELS;
/// Keeps cancelling this long after the phone last talked (the echo tail,
/// and the next sentence).
const STAY_ON: Duration = Duration::from_secs(3);

struct Reference {
    samples: VecDeque<i16>,
    last_voice: Option<Instant>,
}

static REFERENCE: Mutex<Reference> = Mutex::new(Reference {
    samples: VecDeque::new(),
    last_voice: None,
});

fn reference() -> std::sync::MutexGuard<'static, Reference> {
    REFERENCE.lock().unwrap_or_else(|p| p.into_inner())
}

/// What the speakers take, as they take it (48 kHz stereo; the phone's
/// voice, upsampled from 16 kHz mono, so every third left sample is the
/// original). Silence keeps the timeline but doesn't count as talking.
pub fn played(stereo: &[i16]) {
    let voice: Vec<i16> = stereo.chunks(CHANNELS).step_by(3).map(|f| f[0]).collect();
    let talking = voice.iter().any(|&s| s.unsigned_abs() > 8);
    push(&voice, talking);
}

/// The phone's voice as it goes to the speakers (16 kHz mono).
#[cfg(test)]
pub fn push_reference(voice: &[i16]) {
    push(voice, true);
}

fn push(voice: &[i16], talking: bool) {
    let mut r = reference();
    r.samples.extend(voice);
    // More than a second waiting: nobody is listening; keep it short.
    let max = REF_RATE as usize;
    if r.samples.len() > max {
        let drop = r.samples.len() - max / 4;
        r.samples.drain(..drop);
    }
    if talking {
        r.last_voice = Some(Instant::now());
    }
}

/// Takes `n` reference samples (silence where there are none), and
/// whether the phone talked recently.
fn take_reference(n: usize) -> (Vec<f32>, bool) {
    let mut r = reference();

    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        out.push(r.samples.pop_front().map_or(0.0, |s| s as f32 / 32768.0));
    }
    let recent = r.last_voice.is_some_and(|t| t.elapsed() < STAY_ON);
    (out, recent)
}

/// Forgets old voice (a new listener starts).
fn clear_reference() {
    reference().samples.clear();
}

pub struct EchoCanceller {
    pipe: LinearPipeline,
    /// The canceller has seen the voice and is working.
    engaged: bool,
}

impl EchoCanceller {
    pub fn new() -> Result<Self, String> {
        // For troubleshooting (and tests that check the echo is there).
        if std::env::var_os("PAIRDESK_NO_ECHO_CANCEL").is_some() {
            return Err("echo cancelling is turned off (PAIRDESK_NO_ECHO_CANCEL)".into());
        }
        let render = AudioFormat::ten_ms(REF_RATE, 1);
        let capture = AudioFormat::ten_ms(super::codec::RATE, CHANNELS as u16);
        // Only the echo canceller: noise suppression, gain control and
        // filters would change music and voices that aren't echo.
        let pipe = linear::builder(render, capture)
            .enable_noise_suppression(false)
            .enable_gain_controller2(false)
            .enable_high_pass_filter(false)
            .enable_post_filter(false)
            .initial_delay_ms(100)
            .build()
            .map_err(|e| format!("echo canceller: {e:?}"))?;
        clear_reference();
        Ok(Self {
            pipe,
            engaged: false,
        })
    }

    /// Removes the phone's echo from 20 ms of outgoing sound (48 kHz
    /// stereo, in place).
    pub fn process(&mut self, mixed: &mut [i16]) {
        debug_assert_eq!(mixed.len(), FRAME * CHANNELS);
        let (render, recent) = take_reference(REF_10MS * 2);
        if !recent {
            self.engaged = false;
            return;
        }
        self.engaged = true;
        let mut capture = [0f32; CAP_10MS];
        let mut output = [0f32; CAP_10MS];
        for half in 0..2 {
            if self
                .pipe
                .handle_render_frame(&render[half * REF_10MS..][..REF_10MS])
                .is_err()
            {
                return;
            }
            let part = &mut mixed[half * CAP_10MS..][..CAP_10MS];
            for (c, s) in capture.iter_mut().zip(part.iter()) {
                *c = *s as f32 / 32768.0;
            }
            if let Ok(true) = self.pipe.process_capture_frame(&capture, &mut output) {
                for (s, o) in part.iter_mut().zip(output.iter()) {
                    *s = super::codec::f32_to_i16(*o);
                }
            }
        }
    }

    /// Whether it's cancelling right now (for tests and logs).
    #[cfg(test)]
    pub fn engaged(&self) -> bool {
        self.engaged
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::codec::level;

    // The reference is shared by the whole process: one test at a time.
    static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

    /// Speech-like noise: random, with a syllable rhythm.
    fn voice(n: usize, seed: &mut u32) -> Vec<i16> {
        (0..n)
            .map(|i| {
                *seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                let noise = ((*seed >> 16) as i16 as f32) / 32768.0;
                let envelope = (0.5
                    + 0.5 * (i as f32 * 2.0 * std::f32::consts::PI * 4.0 / 16_000.0).sin())
                .powi(2);
                (noise * envelope * 12_000.0) as i16
            })
            .collect()
    }

    /// Power of one frequency in a block (Goertzel), left channel.
    fn power_at(stereo: &[i16], freq: f32) -> f64 {
        let k = 2.0 * (2.0 * std::f64::consts::PI * freq as f64 / 48_000.0).cos();
        let (mut a, mut b) = (0.0f64, 0.0f64);
        for s in stereo.iter().step_by(2) {
            let x = *s as f64 / 32768.0;
            (a, b) = (x + k * a - b, a);
        }
        a * a + b * b - k * a * b
    }

    #[test]
    fn the_phone_hears_the_room_but_not_its_own_echo() {
        let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|p| p.into_inner());
        let mut aec = EchoCanceller::new().unwrap();
        let mut seed = 7;
        // The phone's voice comes back 80 ms later, half as loud. From 6 s,
        // someone at the computer talks too (a 500 Hz tone).
        let delay = 16_000 * 80 / 1000;
        let mut far: VecDeque<i16> = std::iter::repeat_n(0, delay).collect();
        let mut t = 0usize;
        let (mut echo_in, mut echo_out) = (0.0, 0.0);
        let (mut room_in, mut room_out, mut hiss_in, mut hiss_out) = (0.0, 0.0, 0.0, 0.0);
        for frame in 0..450 {
            let voice_now = voice(320, &mut seed);
            push_reference(&voice_now);
            far.extend(&voice_now);
            let room_on = frame >= 300;
            let mut mixed = vec![0i16; FRAME * CHANNELS];
            for i in 0..FRAME {
                let e = far[i / 3] / 2;
                let r = if room_on {
                    (4000.0 * (t as f32 * 2.0 * std::f32::consts::PI * 500.0 / 48_000.0).sin())
                        as i16
                } else {
                    0
                };
                t += 1;
                mixed[i * 2] = e.saturating_add(r);
                mixed[i * 2 + 1] = e.saturating_add(r);
            }
            far.drain(..320);
            let before = mixed.clone();
            aec.process(&mut mixed);
            assert!(aec.engaged());
            if (150..300).contains(&frame) {
                // Only the echo: how much is left after converging.
                echo_in += level(&before);
                echo_out += level(&mixed);
            }
            if frame >= 350 {
                // Both talking: the room's tone stays, the echo (measured
                // away from the tone, at 2.5 kHz) is still reduced.
                room_in += power_at(&before, 500.0);
                room_out += power_at(&mixed, 500.0);
                hiss_in += power_at(&before, 2500.0);
                hiss_out += power_at(&mixed, 2500.0);
            }
        }
        let echo_db = 20.0 * (echo_in / echo_out.max(1e-12)).log10();
        let room_db = 10.0 * (room_out / room_in).log10();
        let double_db = 10.0 * (hiss_in / hiss_out.max(1e-12)).log10();
        eprintln!(
            "echo -{echo_db:.1} dB; while both talk: room voice {room_db:+.1} dB, echo -{double_db:.1} dB"
        );
        assert!(echo_db > 25.0, "echo only reduced by {echo_db:.1} dB");
        assert!(
            room_db > -6.0,
            "the person at the computer got {room_db:.1} dB quieter"
        );
        assert!(
            double_db > 6.0,
            "echo while both talk only reduced by {double_db:.1} dB"
        );
    }

    #[test]
    fn plain_listening_is_untouched() {
        let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|p| p.into_inner());
        reference().last_voice = None;
        let mut aec = EchoCanceller::new().unwrap();
        let mut music: Vec<i16> = (0..FRAME * CHANNELS)
            .map(|i| ((i * 37) % 2000) as i16 - 1000)
            .collect();
        let original = music.clone();
        aec.process(&mut music);
        assert!(!aec.engaged());
        assert_eq!(music, original);
    }
}
