// SPDX-License-Identifier: GPL-3.0-or-later
//! Receiving a screen from PipeWire (what the screen-cast portal hands out).
//!
//! libpipewire is loaded when first needed, not linked, so the agent still
//! starts on computers without it (X11 sessions on older systems). Only a
//! handful of functions are used; the structures below mirror PipeWire 1.x
//! (`pw_stream_events` version 0, `pw_buffer`, `spa_buffer`, `spa_data`,
//! `spa_meta_cursor`) and haven't changed since 0.3.
//!
//! The stream runs on PipeWire's own thread. Each new picture replaces the
//! last; the screen-view loop takes the newest whenever it wants one.

use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::os::fd::{IntoRawFd, OwnedFd};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use libloading::Library;

use super::pod;

type Ptr = *mut c_void;

#[allow(non_snake_case)]
struct Api {
    _lib: Library,
    pw_init: unsafe extern "C" fn(*mut c_int, *mut *mut *mut c_char),
    pw_thread_loop_new: unsafe extern "C" fn(*const c_char, *const c_void) -> Ptr,
    pw_thread_loop_get_loop: unsafe extern "C" fn(Ptr) -> Ptr,
    pw_thread_loop_start: unsafe extern "C" fn(Ptr) -> c_int,
    pw_thread_loop_stop: unsafe extern "C" fn(Ptr),
    pw_thread_loop_destroy: unsafe extern "C" fn(Ptr),
    pw_thread_loop_lock: unsafe extern "C" fn(Ptr),
    pw_thread_loop_unlock: unsafe extern "C" fn(Ptr),
    pw_context_new: unsafe extern "C" fn(Ptr, Ptr, usize) -> Ptr,
    pw_context_destroy: unsafe extern "C" fn(Ptr),
    pw_context_connect_fd: unsafe extern "C" fn(Ptr, c_int, Ptr, usize) -> Ptr,
    pw_core_disconnect: unsafe extern "C" fn(Ptr) -> c_int,
    pw_properties_new_string: unsafe extern "C" fn(*const c_char) -> Ptr,
    pw_stream_new: unsafe extern "C" fn(Ptr, *const c_char, Ptr) -> Ptr,
    pw_stream_add_listener: unsafe extern "C" fn(Ptr, Ptr, *const StreamEvents, Ptr),
    pw_stream_connect: unsafe extern "C" fn(Ptr, u32, u32, u32, *mut *const u8, u32) -> c_int,
    pw_stream_update_params: unsafe extern "C" fn(Ptr, *mut *const u8, u32) -> c_int,
    pw_stream_dequeue_buffer: unsafe extern "C" fn(Ptr) -> *mut PwBuffer,
    pw_stream_queue_buffer: unsafe extern "C" fn(Ptr, *mut PwBuffer) -> c_int,
    pw_stream_destroy: unsafe extern "C" fn(Ptr),
}

fn api() -> Result<&'static Api, String> {
    static API: OnceLock<Result<Api, String>> = OnceLock::new();
    API.get_or_init(|| unsafe { load() })
        .as_ref()
        .map_err(Clone::clone)
}

unsafe fn load() -> Result<Api, String> {
    let lib = unsafe { Library::new("libpipewire-0.3.so.0") }
        .map_err(|_| "PipeWire isn't installed on this computer (libpipewire-0.3)".to_string())?;
    macro_rules! sym {
        ($name:ident) => {
            *unsafe { lib.get(concat!(stringify!($name), "\0").as_bytes()) }
                .map_err(|e| format!("PipeWire is too old: {e}"))?
        };
    }
    let api = Api {
        pw_init: sym!(pw_init),
        pw_thread_loop_new: sym!(pw_thread_loop_new),
        pw_thread_loop_get_loop: sym!(pw_thread_loop_get_loop),
        pw_thread_loop_start: sym!(pw_thread_loop_start),
        pw_thread_loop_stop: sym!(pw_thread_loop_stop),
        pw_thread_loop_destroy: sym!(pw_thread_loop_destroy),
        pw_thread_loop_lock: sym!(pw_thread_loop_lock),
        pw_thread_loop_unlock: sym!(pw_thread_loop_unlock),
        pw_context_new: sym!(pw_context_new),
        pw_context_destroy: sym!(pw_context_destroy),
        pw_context_connect_fd: sym!(pw_context_connect_fd),
        pw_core_disconnect: sym!(pw_core_disconnect),
        pw_properties_new_string: sym!(pw_properties_new_string),
        pw_stream_new: sym!(pw_stream_new),
        pw_stream_add_listener: sym!(pw_stream_add_listener),
        pw_stream_connect: sym!(pw_stream_connect),
        pw_stream_update_params: sym!(pw_stream_update_params),
        pw_stream_dequeue_buffer: sym!(pw_stream_dequeue_buffer),
        pw_stream_queue_buffer: sym!(pw_stream_queue_buffer),
        pw_stream_destroy: sym!(pw_stream_destroy),
        _lib: lib,
    };
    unsafe { (api.pw_init)(std::ptr::null_mut(), std::ptr::null_mut()) };
    Ok(api)
}

// ------------------------------------------------------------ C structures

#[repr(C)]
struct StreamEvents {
    version: u32,
    destroy: Option<unsafe extern "C" fn(Ptr)>,
    state_changed: Option<unsafe extern "C" fn(Ptr, c_int, c_int, *const c_char)>,
    control_info: Option<unsafe extern "C" fn(Ptr, u32, Ptr)>,
    io_changed: Option<unsafe extern "C" fn(Ptr, u32, Ptr, u32)>,
    param_changed: Option<unsafe extern "C" fn(Ptr, u32, *const u8)>,
    add_buffer: Option<unsafe extern "C" fn(Ptr, Ptr)>,
    remove_buffer: Option<unsafe extern "C" fn(Ptr, Ptr)>,
    process: Option<unsafe extern "C" fn(Ptr)>,
    drained: Option<unsafe extern "C" fn(Ptr)>,
}

#[repr(C)]
struct PwBuffer {
    buffer: *mut SpaBuffer,
    // user_data, size, requested, time: not used.
}

#[repr(C)]
struct SpaBuffer {
    n_metas: u32,
    n_datas: u32,
    metas: *mut SpaMeta,
    datas: *mut SpaData,
}

#[repr(C)]
struct SpaMeta {
    ty: u32,
    size: u32,
    data: Ptr,
}

#[repr(C)]
struct SpaData {
    ty: u32,
    flags: u32,
    fd: i64,
    mapoffset: u32,
    maxsize: u32,
    data: Ptr,
    chunk: *mut SpaChunk,
}

#[repr(C)]
struct SpaChunk {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
}

#[repr(C)]
struct SpaMetaCursor {
    id: u32,
    flags: u32,
    x: i32,
    y: i32,
    hotspot_x: i32,
    hotspot_y: i32,
    bitmap_offset: u32,
}

const STATE_ERROR: c_int = -1;
const STATE_STREAMING: c_int = 3;
const DIRECTION_INPUT: u32 = 0;
const FLAG_AUTOCONNECT: u32 = 1;
const FLAG_MAP_BUFFERS: u32 = 4;
const CHUNK_CORRUPTED: i32 = 1;

static EVENTS: StreamEvents = StreamEvents {
    version: 0,
    destroy: None,
    state_changed: Some(on_state_changed),
    control_info: None,
    io_changed: None,
    param_changed: Some(on_param_changed),
    add_buffer: None,
    remove_buffer: None,
    process: Some(on_process),
    drained: None,
};

// ------------------------------------------------------------- the stream

/// The newest picture and pointer, shared with PipeWire's thread.
#[derive(Default)]
struct Latest {
    format: Option<pod::VideoFormat>,
    /// BGRA, tightly packed.
    frame: Option<(u32, u32, Vec<u8>)>,
    frames: u64,
    /// Pointer on this stream, `None` when it's elsewhere.
    cursor: Option<(i32, i32)>,
    error: Option<String>,
}

struct Shared {
    latest: Mutex<Latest>,
    changed: Condvar,
    /// Set right after creation; read by the callbacks.
    stream: Mutex<Ptr>,
}

// The raw pointer is only touched under PipeWire's loop lock or on its thread.
unsafe impl Send for Shared {}
unsafe impl Sync for Shared {}

pub struct Stream {
    api: &'static Api,
    lp: Ptr,
    context: Ptr,
    core: Ptr,
    stream: Ptr,
    /// `spa_hook`: 6 pointers, kept at a fixed address.
    _hook: Box<[usize; 6]>,
    shared: Arc<Shared>,
}

unsafe impl Send for Stream {}

impl Stream {
    /// Connects to `node` through `remote` (from the portal's
    /// `OpenPipeWireRemote`).
    pub fn connect(remote: OwnedFd, node: u32) -> Result<Stream, String> {
        let api = api()?;
        let shared = Arc::new(Shared {
            latest: Mutex::new(Latest::default()),
            changed: Condvar::new(),
            stream: Mutex::new(std::ptr::null_mut()),
        });
        unsafe {
            let name = CString::new("pairdesk-screen").unwrap();
            let lp = (api.pw_thread_loop_new)(name.as_ptr(), std::ptr::null());
            if lp.is_null() {
                return Err("PipeWire: no loop".into());
            }
            let context =
                (api.pw_context_new)((api.pw_thread_loop_get_loop)(lp), std::ptr::null_mut(), 0);
            if context.is_null() {
                (api.pw_thread_loop_destroy)(lp);
                return Err("PipeWire: no context".into());
            }
            if (api.pw_thread_loop_start)(lp) < 0 {
                (api.pw_context_destroy)(context);
                (api.pw_thread_loop_destroy)(lp);
                return Err("PipeWire: loop didn't start".into());
            }
            let mut me = Stream {
                api,
                lp,
                context,
                core: std::ptr::null_mut(),
                stream: std::ptr::null_mut(),
                _hook: Box::new([0; 6]),
                shared,
            };
            (api.pw_thread_loop_lock)(lp);
            let result = me.open(remote, node);
            (api.pw_thread_loop_unlock)(lp);
            result.map(|_| me)
        }
    }

    /// With the loop locked.
    unsafe fn open(&mut self, remote: OwnedFd, node: u32) -> Result<(), String> {
        let api = self.api;
        unsafe {
            self.core = (api.pw_context_connect_fd)(
                self.context,
                remote.into_raw_fd(),
                std::ptr::null_mut(),
                0,
            );
            if self.core.is_null() {
                return Err("PipeWire: can't connect to the screen".into());
            }
            let props =
                CString::new("media.type=Video media.category=Capture media.role=Screen").unwrap();
            let name = CString::new("PairDesk").unwrap();
            self.stream = (api.pw_stream_new)(
                self.core,
                name.as_ptr(),
                (api.pw_properties_new_string)(props.as_ptr()),
            );
            if self.stream.is_null() {
                return Err("PipeWire: no stream".into());
            }
            *self.shared.stream.lock().unwrap() = self.stream;
            (api.pw_stream_add_listener)(
                self.stream,
                self._hook.as_mut_ptr() as Ptr,
                &EVENTS,
                Arc::as_ptr(&self.shared) as Ptr,
            );
            let format = pod::enum_format();
            let mut params = [format.as_ptr()];
            let r = (api.pw_stream_connect)(
                self.stream,
                DIRECTION_INPUT,
                node,
                FLAG_AUTOCONNECT | FLAG_MAP_BUFFERS,
                params.as_mut_ptr(),
                1,
            );
            if r < 0 {
                return Err(format!("PipeWire: can't open the screen ({r})"));
            }
        }
        Ok(())
    }

    /// The newest picture (BGRA), waiting up to `wait` for the first one.
    pub fn frame(&self, wait: Duration) -> Result<(u32, u32, Vec<u8>), String> {
        let deadline = Instant::now() + wait;
        let mut l = self.shared.latest.lock().unwrap_or_else(|p| p.into_inner());
        loop {
            if let Some(e) = &l.error {
                return Err(e.clone());
            }
            if let Some((w, h, data)) = &l.frame {
                return Ok((*w, *h, data.clone()));
            }
            let left = deadline
                .checked_duration_since(Instant::now())
                .ok_or("the screen didn't arrive")?;
            l = self
                .shared
                .changed
                .wait_timeout(l, left)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
    }

    /// Pointer position on this stream's picture, if it's on it.
    pub fn cursor(&self) -> Option<(i32, i32)> {
        self.shared
            .latest
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .cursor
    }

    /// Pictures received so far.
    #[allow(dead_code)]
    pub fn frames(&self) -> u64 {
        self.shared
            .latest
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .frames
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        let api = self.api;
        unsafe {
            (api.pw_thread_loop_lock)(self.lp);
            if !self.stream.is_null() {
                *self.shared.stream.lock().unwrap_or_else(|p| p.into_inner()) =
                    std::ptr::null_mut();
                (api.pw_stream_destroy)(self.stream);
            }
            if !self.core.is_null() {
                (api.pw_core_disconnect)(self.core);
            }
            (api.pw_thread_loop_unlock)(self.lp);
            (api.pw_thread_loop_stop)(self.lp);
            (api.pw_context_destroy)(self.context);
            (api.pw_thread_loop_destroy)(self.lp);
        }
    }
}

// ---------------------------------------------------------------- callbacks
// All run on PipeWire's thread with the loop locked.

fn shared<'a>(data: Ptr) -> &'a Shared {
    unsafe { &*(data as *const Shared) }
}

unsafe extern "C" fn on_state_changed(data: Ptr, _old: c_int, state: c_int, error: *const c_char) {
    let s = shared(data);
    if state == STATE_ERROR {
        let msg = if error.is_null() {
            "unknown error".to_string()
        } else {
            unsafe { CStr::from_ptr(error) }
                .to_string_lossy()
                .into_owned()
        };
        log::warn!("screen stream failed: {msg}");
        s.latest.lock().unwrap_or_else(|p| p.into_inner()).error =
            Some(format!("The screen stream stopped: {msg}"));
        s.changed.notify_all();
    } else if state == STATE_STREAMING {
        log::debug!("screen stream running");
    }
}

unsafe extern "C" fn on_param_changed(data: Ptr, id: u32, param: *const u8) {
    if id != pod::PARAM_FORMAT || param.is_null() {
        return;
    }
    let s = shared(data);
    let bytes = unsafe {
        let size = u32::from_ne_bytes(*(param as *const [u8; 4])) as usize;
        std::slice::from_raw_parts(param, size + 8)
    };
    let format = pod::parse_format(bytes);
    log::info!("screen stream format: {format:?}");
    s.latest.lock().unwrap_or_else(|p| p.into_inner()).format = format;
    let stream = *s.stream.lock().unwrap_or_else(|p| p.into_inner());
    if let (Ok(api), false) = (api(), stream.is_null()) {
        let meta = pod::cursor_meta();
        let buffers = pod::buffers();
        let mut params = [meta.as_ptr(), buffers.as_ptr()];
        unsafe { (api.pw_stream_update_params)(stream, params.as_mut_ptr(), 2) };
    }
}

unsafe extern "C" fn on_process(data: Ptr) {
    let s = shared(data);
    let Ok(api) = api() else { return };
    let stream = *s.stream.lock().unwrap_or_else(|p| p.into_inner());
    if stream.is_null() {
        return;
    }
    // Only the newest buffer matters; give the older ones straight back.
    let mut newest: *mut PwBuffer = std::ptr::null_mut();
    loop {
        let b = unsafe { (api.pw_stream_dequeue_buffer)(stream) };
        if b.is_null() {
            break;
        }
        if !newest.is_null() {
            unsafe { (api.pw_stream_queue_buffer)(stream, newest) };
        }
        newest = b;
    }
    if newest.is_null() {
        return;
    }
    unsafe {
        take(s, newest);
        (api.pw_stream_queue_buffer)(stream, newest);
    }
}

unsafe fn take(s: &Shared, pwb: *mut PwBuffer) {
    let buf = unsafe { &*(*pwb).buffer };
    let mut l = s.latest.lock().unwrap_or_else(|p| p.into_inner());

    // Pointer position (metadata), even when the picture didn't change.
    for i in 0..buf.n_metas as usize {
        let meta = unsafe { &*buf.metas.add(i) };
        if meta.ty == pod::META_CURSOR
            && meta.size as usize >= std::mem::size_of::<SpaMetaCursor>()
            && !meta.data.is_null()
        {
            let c = unsafe { &*(meta.data as *const SpaMetaCursor) };
            l.cursor = (c.id != 0).then_some((c.x, c.y));
        }
    }

    let Some(fmt) = l.format else { return };
    if buf.n_datas == 0 || fmt.gpu {
        return;
    }
    let d = unsafe { &*buf.datas };
    if d.data.is_null() || d.chunk.is_null() {
        return;
    }
    let chunk = unsafe { &*d.chunk };
    if chunk.size == 0 || chunk.flags & CHUNK_CORRUPTED != 0 {
        return; // pointer-only update
    }
    let (w, h) = (fmt.width as usize, fmt.height as usize);
    let stride = if chunk.stride > 0 {
        chunk.stride as usize
    } else {
        w * 4
    };
    let offset = (chunk.offset % d.maxsize.max(1)) as usize;
    if offset + stride * (h - 1) + w * 4 > d.maxsize as usize {
        return;
    }
    let src = unsafe {
        std::slice::from_raw_parts((d.data as *const u8).add(offset), stride * (h - 1) + w * 4)
    };
    let mut out = match l.frame.take() {
        Some((fw, fh, v)) if (fw, fh) == (fmt.width, fmt.height) => v,
        _ => vec![0; w * h * 4],
    };
    copy_rows(src, stride, &mut out, w, h, fmt.format);
    l.frame = Some((fmt.width, fmt.height, out));
    l.frames += 1;
    drop(l);
    s.changed.notify_all();
}

/// Copies rows into a packed BGRA picture, swapping red and blue for RGB
/// formats.
fn copy_rows(src: &[u8], stride: usize, out: &mut [u8], w: usize, h: usize, format: u32) {
    let rgb = matches!(format, pod::VIDEO_RGBX | pod::VIDEO_RGBA);
    for y in 0..h {
        let row = &src[y * stride..y * stride + w * 4];
        let dst = &mut out[y * w * 4..(y + 1) * w * 4];
        dst.copy_from_slice(row);
        if rgb {
            for px in dst.as_chunks_mut::<4>().0 {
                px.swap(0, 2);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn structures_match_pipewire() {
        // Sizes and offsets printed from the C headers (PipeWire 1.0).
        assert_eq!(std::mem::size_of::<SpaBuffer>(), 24);
        assert_eq!(std::mem::size_of::<SpaData>(), 40);
        assert_eq!(std::mem::offset_of!(SpaData, data), 24);
        assert_eq!(std::mem::offset_of!(SpaData, chunk), 32);
        assert_eq!(std::mem::size_of::<SpaMeta>(), 16);
        assert_eq!(std::mem::size_of::<SpaMetaCursor>(), 28);
        assert_eq!(std::mem::offset_of!(StreamEvents, state_changed), 16);
        assert_eq!(std::mem::offset_of!(StreamEvents, param_changed), 40);
        assert_eq!(std::mem::offset_of!(StreamEvents, process), 64);
    }

    #[test]
    fn copies_rows_and_swaps_rgb() {
        // 2×2, stride 12 (4 bytes of padding per row).
        let src: Vec<u8> = vec![
            1, 2, 3, 0, 4, 5, 6, 0, 9, 9, 9, 9, //
            7, 8, 9, 0, 10, 11, 12, 0,
        ];
        let mut out = vec![0; 16];
        copy_rows(&src, 12, &mut out, 2, 2, pod::VIDEO_BGRX);
        assert_eq!(out, vec![1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0]);
        copy_rows(&src, 12, &mut out, 2, 2, pod::VIDEO_RGBA);
        assert_eq!(out, vec![3, 2, 1, 0, 6, 5, 4, 0, 9, 8, 7, 0, 12, 11, 10, 0]);
    }
}
