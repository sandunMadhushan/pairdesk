// SPDX-License-Identifier: GPL-3.0-or-later
//! Windows: sound through WASAPI (cpal). The computer's sound is recorded
//! with loopback capture on the default output device; devices' own
//! formats are converted to and from 48 kHz stereo 16-bit here.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Data, SampleFormat};

use super::Source;
use super::codec::{CHANNELS, RATE, Resampler, Ring, f32_to_i16, i16_to_f32, to_stereo};

pub struct Device {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Drop for Device {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Samples of any format as f32.
fn samples(data: &Data) -> Option<Vec<f32>> {
    Some(match data.sample_format() {
        SampleFormat::F32 => data.as_slice::<f32>()?.to_vec(),
        SampleFormat::I16 => data
            .as_slice::<i16>()?
            .iter()
            .map(|&s| i16_to_f32(s))
            .collect(),
        SampleFormat::I32 => data
            .as_slice::<i32>()?
            .iter()
            .map(|&s| s as f32 / 2_147_483_648.0)
            .collect(),
        SampleFormat::U16 => data
            .as_slice::<u16>()?
            .iter()
            .map(|&s| (s as f32 - 32768.0) / 32768.0)
            .collect(),
        _ => return None,
    })
}

/// Runs a stream on its own thread (cpal streams stay where they're made);
/// returns once it plays (or failed).
fn spawn(
    what: &'static str,
    build: impl FnOnce() -> Result<cpal::Stream, String> + Send + 'static,
) -> Result<Device, String> {
    let stop = Arc::new(AtomicBool::new(false));
    let (tx, rx) = std::sync::mpsc::channel();
    let flag = stop.clone();
    let thread = std::thread::Builder::new()
        .name(format!("pairdesk-{what}"))
        .spawn(move || {
            let stream = match build().and_then(|s| s.play().map(|_| s).map_err(|e| e.to_string()))
            {
                Ok(s) => s,
                Err(e) => {
                    let _ = tx.send(Err(format!("can't open the {what}: {e}")));
                    return;
                }
            };
            let _ = tx.send(Ok(()));
            while !flag.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(50));
            }
            drop(stream);
        })
        .map_err(|e| e.to_string())?;
    match rx.recv_timeout(Duration::from_secs(5)) {
        Ok(Ok(())) => Ok(Device {
            stop,
            thread: Some(thread),
        }),
        Ok(Err(e)) => {
            let _ = thread.join();
            Err(e)
        }
        Err(_) => {
            stop.store(true, Ordering::Relaxed);
            Err(format!("the {what} didn't open in time"))
        }
    }
}

pub fn capture(source: Source, ring: Arc<Ring>) -> Result<Device, String> {
    let what = match source {
        Source::System => "computer sound",
        Source::Microphone => "microphone",
    };
    spawn(what, move || {
        let host = cpal::default_host();
        // An output device used for input records what it plays (loopback).
        let device = match source {
            Source::System => host.default_output_device(),
            Source::Microphone => host.default_input_device(),
        }
        .ok_or("no such device")?;
        let config = match source {
            Source::System => device.default_output_config(),
            Source::Microphone => device.default_input_config(),
        }
        .map_err(|e| e.to_string())?;
        let channels = config.channels() as usize;
        let mut resampler = Resampler::new(config.sample_rate(), RATE);
        let mut out = Vec::with_capacity(4096);
        device
            .build_input_stream_raw(
                config.config(),
                config.sample_format(),
                move |data: &Data, _: &cpal::InputCallbackInfo| {
                    let Some(input) = samples(data) else { return };
                    out.clear();
                    resampler.process(input.chunks(channels.max(1)).map(to_stereo), |f| {
                        out.push(f32_to_i16(f[0]));
                        out.push(f32_to_i16(f[1]));
                    });
                    ring.push(&out);
                },
                move |e| log::warn!("{what}: {e}"),
                None,
            )
            .map_err(|e| e.to_string())
    })
}

pub fn playback(ring: Arc<Ring>) -> Result<Device, String> {
    spawn("speakers", move || {
        let host = cpal::default_host();
        let device = host.default_output_device().ok_or("no speakers")?;
        let config = device.default_output_config().map_err(|e| e.to_string())?;
        let channels = config.channels() as usize;
        let format = config.sample_format();
        let mut resampler = Resampler::new(RATE, config.sample_rate());
        // Converted frames waiting for the device.
        let mut pending: std::collections::VecDeque<[f32; 2]> = Default::default();
        let mut chunk = vec![0i16; (RATE / 100) as usize * CHANNELS];
        let prebuffer = chunk.len() * 6;
        let mut playing = false;
        let mut fill = move |frames: usize| -> Vec<[f32; 2]> {
            let mut out = Vec::with_capacity(frames);
            while out.len() < frames {
                if let Some(f) = pending.pop_front() {
                    out.push(f);
                    continue;
                }
                if !playing {
                    playing = ring.len() >= prebuffer;
                }
                if playing {
                    let real = ring.take(&mut chunk);
                    playing = real == chunk.len();
                } else {
                    chunk.fill(0);
                }
                resampler.process(
                    chunk
                        .chunks(2)
                        .map(|f| [i16_to_f32(f[0]), i16_to_f32(f[1])]),
                    |f| pending.push_back(f),
                );
            }
            out
        };
        device
            .build_output_stream_raw(
                config.config(),
                format,
                move |data: &mut Data, _: &cpal::OutputCallbackInfo| {
                    let frames = data.len() / channels.max(1);
                    let stereo = fill(frames);
                    // Left and right on the first two channels, nothing on the rest.
                    let value = |i: usize| -> f32 {
                        let f = stereo[i / channels];
                        match (channels, i % channels) {
                            (1, _) => (f[0] + f[1]) / 2.0,
                            (_, 0) => f[0],
                            (_, 1) => f[1],
                            _ => 0.0,
                        }
                    };
                    match data.sample_format() {
                        SampleFormat::F32 => {
                            if let Some(s) = data.as_slice_mut::<f32>() {
                                for (i, v) in s.iter_mut().enumerate() {
                                    *v = value(i);
                                }
                            }
                        }
                        SampleFormat::I16 => {
                            if let Some(s) = data.as_slice_mut::<i16>() {
                                for (i, v) in s.iter_mut().enumerate() {
                                    *v = f32_to_i16(value(i));
                                }
                            }
                        }
                        SampleFormat::I32 => {
                            if let Some(s) = data.as_slice_mut::<i32>() {
                                for (i, v) in s.iter_mut().enumerate() {
                                    *v = (value(i).clamp(-1.0, 1.0) * 2_147_483_647.0) as i32;
                                }
                            }
                        }
                        _ => {}
                    }
                },
                |e| log::warn!("speakers: {e}"),
                None,
            )
            .map_err(|e| e.to_string())
    })
}
