// SPDX-License-Identifier: GPL-3.0-or-later
//! File and folder permissions, written as SDDL strings.

use std::os::windows::ffi::OsStrExt;
use std::path::Path;

use windows_sys::Win32::Foundation::LocalFree;
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1, SE_FILE_OBJECT,
    SetNamedSecurityInfoW,
};
use windows_sys::Win32::Security::{
    ACL, DACL_SECURITY_INFORMATION, GetSecurityDescriptorDacl, PROTECTED_DACL_SECURITY_INFORMATION,
    PSECURITY_DESCRIPTOR,
};

/// SYSTEM and administrators only; inherited by everything inside.
pub const ADMIN_ONLY: &str = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

/// SYSTEM and administrators, plus read for one user.
pub fn admin_and_reader(user_sid: &str) -> String {
    format!("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;{user_sid})")
}

fn wide(s: impl AsRef<std::ffi::OsStr>) -> Vec<u16> {
    s.as_ref().encode_wide().chain(Some(0)).collect()
}

/// Replaces the permissions of `path` (file or folder) with `sddl`,
/// without inheriting from the parent.
pub fn set(path: &Path, sddl: &str) -> Result<(), String> {
    let sddl_w = wide(sddl);
    let mut sd: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl_w.as_ptr(),
            SDDL_REVISION_1,
            &mut sd,
            std::ptr::null_mut(),
        )
    } == 0
    {
        return Err(format!("bad SDDL: {}", std::io::Error::last_os_error()));
    }
    let mut present = 0;
    let mut defaulted = 0;
    let mut dacl: *mut ACL = std::ptr::null_mut();
    let ok = unsafe { GetSecurityDescriptorDacl(sd, &mut present, &mut dacl, &mut defaulted) };
    let result = if ok == 0 || present == 0 {
        Err("no DACL in the SDDL".to_string())
    } else {
        let path_w = wide(path);
        let rc = unsafe {
            SetNamedSecurityInfoW(
                path_w.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                dacl,
                std::ptr::null(),
            )
        };
        if rc == 0 {
            Ok(())
        } else {
            Err(format!(
                "can't set permissions on {}: {}",
                path.display(),
                std::io::Error::from_raw_os_error(rc as i32)
            ))
        }
    };
    unsafe { LocalFree(sd) };
    result
}

/// Writes `bytes` to `path` and then gives it the permissions `sddl`.
/// The folder is admin-only already, so nobody else sees the file in
/// between.
pub fn write(path: &Path, bytes: &[u8], sddl: &str) -> Result<(), String> {
    crate::config::write_atomic(path, bytes).map_err(|e| e.to_string())?;
    set(path, sddl)
}
