// SPDX-License-Identifier: GPL-3.0-or-later
//! Windows: starts WebView2 without Microsoft's `WebView2Loader.dll`.
//!
//! The WebView2 bindings that wry uses import two functions from
//! `WebView2Loader.dll`, a separate closed-source file that would have to
//! ship next to the .exe; without it Windows wouldn't even start PairDesk.
//! Its job is small: find the WebView2 runtime that Windows keeps up to
//! date, and ask it to make a browser environment. This does the same,
//! like the open-source `webview` library's built-in loader.
//!
//! The functions are provided under the names the bindings import
//! (`__imp_…`), so the linker uses these and never imports the DLL.

use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, HMODULE};
use windows_sys::Win32::System::Com::CoTaskMemAlloc;
use windows_sys::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
use windows_sys::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ, RRF_SUBKEY_WOW6432KEY, RegGetValueW,
};

type Hresult = i32;
const S_OK: Hresult = 0;
/// HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND): no WebView2 runtime.
const NOT_FOUND: Hresult = (0x8007_0000u32 | ERROR_FILE_NOT_FOUND) as Hresult;
const E_POINTER: Hresult = 0x8000_4003u32 as Hresult;
const E_OUTOFMEMORY: Hresult = 0x8007_000Eu32 as Hresult;

/// The stable WebView2 runtime ("Evergreen"), as registered by Edge Update.
const CLIENT_STATE: &str =
    r"SOFTWARE\Microsoft\EdgeUpdate\ClientState\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
enum RuntimeKind {
    /// Installed and kept up to date by Windows.
    Installed = 0,
    /// A "fixed version" copy in a folder of its own.
    Embedded = 1,
}

#[derive(Debug, PartialEq, Eq)]
struct Client {
    dll: PathBuf,
    version: String,
    kind: RuntimeKind,
}

#[cfg(target_arch = "x86_64")]
const ARCH: &str = "x64";
#[cfg(target_arch = "aarch64")]
const ARCH: &str = "arm64";
#[cfg(target_arch = "x86")]
const ARCH: &str = "x86";

/// `<runtime folder>\EBWebView\<arch>\EmbeddedBrowserWebView.dll`
fn client_dll(folder: &Path) -> PathBuf {
    folder
        .join("EBWebView")
        .join(ARCH)
        .join("EmbeddedBrowserWebView.dll")
}

/// The runtime's version: its folder's name, e.g. `131.0.2903.70`.
fn version_of(folder: &Path) -> String {
    folder
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// A NUL-terminated wide string from the caller, if any.
unsafe fn from_wide(p: *const u16) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let mut n = 0;
    while unsafe { *p.add(n) } != 0 {
        n += 1;
    }
    let s = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(p, n) });
    (!s.is_empty()).then_some(s)
}

fn registry_string(root: HKEY, key: &str, value: &str) -> Option<String> {
    let key = wide(key);
    let value = wide(value);
    let mut buf = vec![0u16; 1024];
    let mut size = (buf.len() * 2) as u32;
    let r = unsafe {
        RegGetValueW(
            root,
            key.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_SZ | RRF_SUBKEY_WOW6432KEY,
            std::ptr::null_mut(),
            buf.as_mut_ptr().cast(),
            &mut size,
        )
    };
    if r != 0 {
        return None;
    }
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    let s = String::from_utf16_lossy(&buf[..len]);
    (!s.is_empty()).then_some(s)
}

/// The WebView2 runtime to use: the caller's folder or
/// `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` (a fixed-version copy), else the
/// one installed for all users, else for this user.
fn find_client(folder: Option<String>) -> Option<Client> {
    let embedded = folder.or_else(|| {
        std::env::var("WEBVIEW2_BROWSER_EXECUTABLE_FOLDER")
            .ok()
            .filter(|f| !f.is_empty())
    });
    if let Some(folder) = embedded {
        let folder = PathBuf::from(folder);
        let dll = client_dll(&folder);
        return dll.is_file().then(|| Client {
            dll,
            version: version_of(&folder),
            kind: RuntimeKind::Embedded,
        });
    }
    [HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER]
        .into_iter()
        .filter_map(|root| registry_string(root, CLIENT_STATE, "EBWebView"))
        .map(PathBuf::from)
        .map(|folder| Client {
            dll: client_dll(&folder),
            version: version_of(&folder),
            kind: RuntimeKind::Installed,
        })
        .find(|c| c.dll.is_file())
}

/// `CreateWebViewEnvironmentWithOptionsInternal`, exported by the runtime.
type CreateInternal = unsafe extern "system" fn(
    check_running_instance: bool,
    kind: RuntimeKind,
    user_data_folder: *const u16,
    options: *mut c_void,
    handler: *mut c_void,
) -> Hresult;

unsafe extern "system" fn create_environment(
    browser_folder: *const u16,
    user_data_folder: *const u16,
    options: *mut c_void,
    handler: *mut c_void,
) -> Hresult {
    if handler.is_null() {
        return E_POINTER;
    }
    let Some(client) = find_client(unsafe { from_wide(browser_folder) }) else {
        log::warn!("WebView2: no runtime found");
        return NOT_FOUND;
    };
    let path: Vec<u16> = client
        .dll
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    // Stays loaded: the environment lives in it.
    let module: HMODULE = unsafe { LoadLibraryW(path.as_ptr()) };
    if module.is_null() {
        let e = std::io::Error::last_os_error();
        log::warn!("WebView2: can't load {}: {e}", client.dll.display());
        return e
            .raw_os_error()
            .map(|c| (0x8007_0000u32 | (c as u32 & 0xffff)) as Hresult)
            .unwrap_or(NOT_FOUND);
    }
    let Some(create) = (unsafe {
        GetProcAddress(
            module,
            c"CreateWebViewEnvironmentWithOptionsInternal"
                .as_ptr()
                .cast(),
        )
    }) else {
        log::warn!("WebView2 {}: entry point missing", client.version);
        return NOT_FOUND;
    };
    let create: CreateInternal = unsafe { std::mem::transmute(create) };
    unsafe { create(true, client.kind, user_data_folder, options, handler) }
}

unsafe extern "system" fn browser_version(
    browser_folder: *const u16,
    out: *mut *mut u16,
) -> Hresult {
    if out.is_null() {
        return E_POINTER;
    }
    unsafe { *out = std::ptr::null_mut() };
    let Some(client) = find_client(unsafe { from_wide(browser_folder) }) else {
        return NOT_FOUND;
    };
    // Freed by the caller with CoTaskMemFree.
    let w = wide(&client.version);
    let p = unsafe { CoTaskMemAlloc(w.len() * 2) } as *mut u16;
    if p.is_null() {
        return E_OUTOFMEMORY;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(w.as_ptr(), p, w.len());
        *out = p;
    }
    S_OK
}

// What the bindings call instead of the loader's. Defined under both the
// plain name (MSVC links the loader statically) and the import slot (MinGW
// imports it from the DLL): either way the linker finds these first and
// leaves Microsoft's loader out.

#[unsafe(no_mangle)]
pub unsafe extern "system" fn CreateCoreWebView2EnvironmentWithOptions(
    browser_folder: *const u16,
    user_data_folder: *const u16,
    options: *mut c_void,
    handler: *mut c_void,
) -> Hresult {
    unsafe { create_environment(browser_folder, user_data_folder, options, handler) }
}

#[unsafe(no_mangle)]
pub unsafe extern "system" fn GetAvailableCoreWebView2BrowserVersionString(
    browser_folder: *const u16,
    out: *mut *mut u16,
) -> Hresult {
    unsafe { browser_version(browser_folder, out) }
}

#[allow(non_upper_case_globals)]
#[unsafe(no_mangle)]
pub static __imp_CreateCoreWebView2EnvironmentWithOptions: unsafe extern "system" fn(
    *const u16,
    *const u16,
    *mut c_void,
    *mut c_void,
) -> Hresult = create_environment;

#[allow(non_upper_case_globals)]
#[unsafe(no_mangle)]
pub static __imp_GetAvailableCoreWebView2BrowserVersionString:
    unsafe extern "system" fn(*const u16, *mut *mut u16) -> Hresult = browser_version;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_paths() {
        let folder =
            Path::new(r"C:\Program Files (x86)\Microsoft\EdgeWebView\Application\131.0.2903.70");
        assert_eq!(version_of(folder), "131.0.2903.70");
        let dll = client_dll(folder);
        assert!(dll.ends_with(format!(
            r"131.0.2903.70\EBWebView\{ARCH}\EmbeddedBrowserWebView.dll"
        )));
    }

    #[test]
    fn a_missing_runtime_is_reported_not_crashed_on() {
        // A folder without the runtime: "not found", and no string handed out.
        let folder = wide(r"C:\nowhere\131.0.0.0");
        let mut out: *mut u16 = 1 as _;
        let r = unsafe { browser_version(folder.as_ptr(), &mut out) };
        assert_eq!(r, NOT_FOUND);
        assert!(out.is_null());
        let r = unsafe {
            create_environment(
                folder.as_ptr(),
                std::ptr::null(),
                std::ptr::null_mut(),
                1 as _,
            )
        };
        assert_eq!(r, NOT_FOUND);
    }
}
