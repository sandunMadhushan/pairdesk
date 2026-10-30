// SPDX-License-Identifier: GPL-3.0-or-later
//! Linux: sound through PulseAudio's "simple" API, which PipeWire also
//! provides (pipewire-pulse) on current desktops. The library is loaded
//! at run time, so PairDesk still starts where it's missing.
//!
//! The computer's sound is recorded from the default output's monitor
//! (`@DEFAULT_MONITOR@`); PulseAudio converts every stream to and from
//! 48 kHz stereo 16-bit for us.

use std::ffi::{CString, c_char, c_int, c_void};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use super::Source;
use super::codec::{CHANNELS, RATE, Ring};

#[repr(C)]
struct SampleSpec {
    format: c_int,
    rate: u32,
    channels: u8,
}

#[repr(C)]
struct BufferAttr {
    maxlength: u32,
    tlength: u32,
    prebuf: u32,
    minreq: u32,
    fragsize: u32,
}

const PA_STREAM_PLAYBACK: c_int = 1;
const PA_STREAM_RECORD: c_int = 2;
const PA_SAMPLE_S16LE: c_int = 3;

type NewFn = unsafe extern "C" fn(
    server: *const c_char,
    name: *const c_char,
    dir: c_int,
    dev: *const c_char,
    stream_name: *const c_char,
    ss: *const SampleSpec,
    map: *const c_void,
    attr: *const BufferAttr,
    error: *mut c_int,
) -> *mut c_void;
type ReadFn = unsafe extern "C" fn(
    s: *mut c_void,
    data: *mut c_void,
    bytes: usize,
    error: *mut c_int,
) -> c_int;
type WriteFn = unsafe extern "C" fn(
    s: *mut c_void,
    data: *const c_void,
    bytes: usize,
    error: *mut c_int,
) -> c_int;
type FreeFn = unsafe extern "C" fn(s: *mut c_void);
type StrerrorFn = unsafe extern "C" fn(error: c_int) -> *const c_char;

struct Lib {
    _lib: libloading::Library,
    _pulse: Option<libloading::Library>,
    new: NewFn,
    read: ReadFn,
    write: WriteFn,
    free: FreeFn,
    strerror: Option<StrerrorFn>,
}

fn lib() -> Result<&'static Lib, String> {
    static LIB: std::sync::OnceLock<Result<Lib, String>> = std::sync::OnceLock::new();
    LIB.get_or_init(|| unsafe {
        let simple = libloading::Library::new("libpulse-simple.so.0").map_err(|e| {
            format!("PulseAudio isn't available ({e}). Sound needs PulseAudio or PipeWire.")
        })?;
        let pulse = libloading::Library::new("libpulse.so.0").ok();
        let strerror = pulse
            .as_ref()
            .and_then(|p| p.get::<StrerrorFn>(b"pa_strerror\0").ok().map(|f| *f));
        let get = |name: &[u8]| -> Result<*mut c_void, String> {
            simple
                .get::<*mut c_void>(name)
                .map(|s| *s)
                .map_err(|e| format!("PulseAudio: {e}"))
        };
        Ok(Lib {
            new: std::mem::transmute::<*mut c_void, NewFn>(get(b"pa_simple_new\0")?),
            read: std::mem::transmute::<*mut c_void, ReadFn>(get(b"pa_simple_read\0")?),
            write: std::mem::transmute::<*mut c_void, WriteFn>(get(b"pa_simple_write\0")?),
            free: std::mem::transmute::<*mut c_void, FreeFn>(get(b"pa_simple_free\0")?),
            strerror,
            _lib: simple,
            _pulse: pulse,
        })
    })
    .as_ref()
    .map_err(|e| e.clone())
}

fn error_text(lib: &Lib, err: c_int) -> String {
    lib.strerror
        .and_then(|f| unsafe {
            let p = f(err);
            (!p.is_null()).then(|| std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned())
        })
        .unwrap_or_else(|| format!("error {err}"))
}

struct Stream {
    lib: &'static Lib,
    s: *mut c_void,
}

impl Stream {
    fn open(record: bool, device: Option<&str>, what: &str) -> Result<Self, String> {
        let lib = lib()?;
        let spec = SampleSpec {
            format: PA_SAMPLE_S16LE,
            rate: RATE,
            channels: CHANNELS as u8,
        };
        let ms10 = (RATE / 100) * CHANNELS as u32 * 2;
        let attr = if record {
            BufferAttr {
                maxlength: u32::MAX,
                tlength: u32::MAX,
                prebuf: u32::MAX,
                minreq: u32::MAX,
                fragsize: ms10,
            }
        } else {
            BufferAttr {
                maxlength: u32::MAX,
                tlength: ms10 * 8,
                prebuf: u32::MAX,
                minreq: ms10,
                fragsize: u32::MAX,
            }
        };
        let app = CString::new("PairDesk").expect("no NUL");
        let name = CString::new(what).expect("no NUL");
        let dev = device.map(|d| CString::new(d).expect("no NUL"));
        let mut err = 0;
        let s = unsafe {
            (lib.new)(
                std::ptr::null(),
                app.as_ptr(),
                if record {
                    PA_STREAM_RECORD
                } else {
                    PA_STREAM_PLAYBACK
                },
                dev.as_ref().map_or(std::ptr::null(), |d| d.as_ptr()),
                name.as_ptr(),
                &spec,
                std::ptr::null(),
                &attr,
                &mut err,
            )
        };
        if s.is_null() {
            return Err(format!("can't open the {what}: {}", error_text(lib, err)));
        }
        Ok(Self { lib, s })
    }

    fn read(&self, buf: &mut [i16]) -> Result<(), String> {
        let mut err = 0;
        let r =
            unsafe { (self.lib.read)(self.s, buf.as_mut_ptr().cast(), buf.len() * 2, &mut err) };
        if r < 0 {
            return Err(error_text(self.lib, err));
        }
        Ok(())
    }

    fn write(&self, buf: &[i16]) -> Result<(), String> {
        let mut err = 0;
        let r = unsafe { (self.lib.write)(self.s, buf.as_ptr().cast(), buf.len() * 2, &mut err) };
        if r < 0 {
            return Err(error_text(self.lib, err));
        }
        Ok(())
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        unsafe { (self.lib.free)(self.s) };
    }
}

/// A device thread; stops and is joined when dropped.
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

/// Opens a stream on its own thread; returns once it's open (or failed).
fn spawn(
    what: &'static str,
    open: impl FnOnce() -> Result<Stream, String> + Send + 'static,
    run: impl FnOnce(Stream, &AtomicBool) + Send + 'static,
) -> Result<Device, String> {
    let stop = Arc::new(AtomicBool::new(false));
    let (tx, rx) = std::sync::mpsc::channel();
    let flag = stop.clone();
    let thread = std::thread::Builder::new()
        .name(format!("pairdesk-{what}"))
        .spawn(move || match open() {
            Ok(s) => {
                let _ = tx.send(Ok(()));
                run(s, &flag);
            }
            Err(e) => {
                let _ = tx.send(Err(e));
            }
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
    let (device, what) = match source {
        Source::System => (Some("@DEFAULT_MONITOR@"), "computer sound"),
        Source::Microphone => (None, "microphone"),
    };
    spawn(
        what,
        move || Stream::open(true, device, what),
        move |s, stop| {
            let mut buf = vec![0i16; (RATE / 100) as usize * CHANNELS];
            while !stop.load(Ordering::Relaxed) {
                if let Err(e) = s.read(&mut buf) {
                    log::warn!("{what}: {e}");
                    break;
                }
                ring.push(&buf);
            }
        },
    )
}

pub fn playback(ring: Arc<Ring>) -> Result<Device, String> {
    spawn(
        "speakers",
        || Stream::open(false, None, "speakers"),
        move |s, stop| {
            let chunk = (RATE / 100) as usize * CHANNELS; // 10 ms
            let prebuffer = chunk * 6; // 60 ms after running dry
            let mut buf = vec![0i16; chunk];
            let mut playing = false;
            while !stop.load(Ordering::Relaxed) {
                if !playing {
                    ring.wait_for(prebuffer, Instant::now() + Duration::from_millis(10));
                    playing = ring.len() >= prebuffer;
                }
                if playing {
                    let real = ring.take(&mut buf);
                    playing = real == chunk;
                } else {
                    buf.fill(0);
                }
                // Blocks while PulseAudio's buffer is full: real-time pace.
                if let Err(e) = s.write(&buf) {
                    log::warn!("speakers: {e}");
                    break;
                }
            }
        },
    )
}
