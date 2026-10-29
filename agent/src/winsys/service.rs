// SPDX-License-Identifier: GPL-3.0-or-later
//! The PairDesk helper service: installing it (elevated), running it under
//! the Windows service manager, and asking for elevation from the agent.

use std::os::windows::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{
    ERROR_SERVICE_DOES_NOT_EXIST, GetLastError, HANDLE, NO_ERROR,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject,
};
use windows_sys::Win32::System::Services::{
    ChangeServiceConfig2W, ChangeServiceConfigW, CloseServiceHandle, ControlService,
    CreateServiceW, DeleteService, OpenSCManagerW, OpenServiceW, QueryServiceStatus,
    RegisterServiceCtrlHandlerExW, SC_ACTION, SC_ACTION_RESTART, SC_HANDLE, SC_MANAGER_ALL_ACCESS,
    SC_MANAGER_CONNECT, SERVICE_ACCEPT_SHUTDOWN, SERVICE_ACCEPT_STOP, SERVICE_ALL_ACCESS,
    SERVICE_AUTO_START, SERVICE_CONFIG_DESCRIPTION, SERVICE_CONFIG_FAILURE_ACTIONS,
    SERVICE_CONTROL_INTERROGATE, SERVICE_CONTROL_SHUTDOWN, SERVICE_CONTROL_STOP,
    SERVICE_DESCRIPTIONW, SERVICE_ERROR_NORMAL, SERVICE_FAILURE_ACTIONSW, SERVICE_NO_CHANGE,
    SERVICE_QUERY_STATUS, SERVICE_RUNNING, SERVICE_START, SERVICE_START_PENDING, SERVICE_STATUS,
    SERVICE_STATUS_HANDLE, SERVICE_STOP_PENDING, SERVICE_STOPPED, SERVICE_TABLE_ENTRYW,
    SERVICE_WIN32_OWN_PROCESS, SetServiceStatus, StartServiceCtrlDispatcherW, StartServiceW,
};

use super::{SERVICE_NAME, acl, session};
use crate::install::Kind;
use crate::update::{Source, Updater};

const DISPLAY_NAME: &str = "PairDesk helper";
const DESCRIPTION: &str = "Lets your paired phone use the Windows sign-in screen and administrator prompts. \
     Turn it off in PairDesk's settings.";

fn wide(s: impl AsRef<std::ffi::OsStr>) -> Vec<u16> {
    s.as_ref().encode_wide().chain(Some(0)).collect()
}

fn last_error() -> String {
    std::io::Error::last_os_error().to_string()
}

/// `%ProgramData%\PairDesk`: SYSTEM and administrators only.
pub fn program_data() -> PathBuf {
    let base = std::env::var_os("ProgramData").unwrap_or_else(|| "C:\\ProgramData".into());
    PathBuf::from(base).join("PairDesk")
}

/// `%ProgramFiles%\PairDesk`: the service's own copy of PairDesk.
fn program_files() -> PathBuf {
    let base = std::env::var_os("ProgramW6432")
        .or_else(|| std::env::var_os("ProgramFiles"))
        .unwrap_or_else(|| "C:\\Program Files".into());
    PathBuf::from(base).join("PairDesk")
}

struct Scm(SC_HANDLE);

impl Drop for Scm {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CloseServiceHandle(self.0) };
        }
    }
}

fn manager(access: u32) -> Result<Scm, String> {
    let h = unsafe { OpenSCManagerW(std::ptr::null(), std::ptr::null(), access) };
    if h.is_null() {
        return Err(format!("can't open the service manager: {}", last_error()));
    }
    Ok(Scm(h))
}

fn open(scm: &Scm, access: u32) -> Option<Scm> {
    let name = wide(SERVICE_NAME);
    let h = unsafe { OpenServiceW(scm.0, name.as_ptr(), access) };
    (!h.is_null()).then_some(Scm(h))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    NotInstalled,
    Stopped,
    Running,
    Starting,
}

impl State {
    pub fn label(self) -> &'static str {
        match self {
            State::NotInstalled => "not_installed",
            State::Stopped => "stopped",
            State::Running => "running",
            State::Starting => "starting",
        }
    }
}

/// The service's state; works without administrator rights.
pub fn state() -> State {
    let Ok(scm) = manager(SC_MANAGER_CONNECT) else {
        return State::NotInstalled;
    };
    let Some(svc) = open(&scm, SERVICE_QUERY_STATUS) else {
        return State::NotInstalled;
    };
    let mut st: SERVICE_STATUS = unsafe { std::mem::zeroed() };
    if unsafe { QueryServiceStatus(svc.0, &mut st) } == 0 {
        return State::Stopped;
    }
    match st.dwCurrentState {
        SERVICE_RUNNING => State::Running,
        SERVICE_START_PENDING => State::Starting,
        _ => State::Stopped,
    }
}

fn stop_and_wait(svc: &Scm) {
    let mut st: SERVICE_STATUS = unsafe { std::mem::zeroed() };
    unsafe { ControlService(svc.0, SERVICE_CONTROL_STOP, &mut st) };
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if unsafe { QueryServiceStatus(svc.0, &mut st) } == 0
            || st.dwCurrentState == SERVICE_STOPPED
        {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

/// `--install-service` (as administrator): copies this program to Program
/// Files, protects PairDesk's ProgramData folder, registers and starts the
/// service. Installing again updates it.
pub fn install() -> Result<(), String> {
    let scm = manager(SC_MANAGER_ALL_ACCESS)
        .map_err(|e| format!("{e} (this needs administrator rights)"))?;
    let existing = open(&scm, SERVICE_ALL_ACCESS);
    if let Some(svc) = &existing {
        stop_and_wait(svc);
    }

    // Our own copy, where only administrators can change it: a service
    // must never run a program the user (or anything running as the user)
    // can replace.
    let dir = program_files();
    std::fs::create_dir_all(&dir).map_err(|e| format!("can't create {}: {e}", dir.display()))?;
    let exe = dir.join("pairdesk-agent.exe");
    let me = std::env::current_exe().map_err(|e| e.to_string())?;
    if me != exe {
        let _ = std::fs::remove_file(&exe);
        std::fs::copy(&me, &exe)
            .map_err(|e| format!("can't copy PairDesk to {}: {e}", dir.display()))?;
    }

    let data = program_data();
    for d in [
        data.clone(),
        data.join("bridge"),
        super::system_data_dir(&data),
    ] {
        std::fs::create_dir_all(&d).map_err(|e| format!("can't create {}: {e}", d.display()))?;
    }
    acl::set(&data, acl::ADMIN_ONLY)?;

    let cmd = wide(format!("\"{}\" --service", exe.display()));
    let svc = match existing {
        Some(svc) => {
            let ok = unsafe {
                ChangeServiceConfigW(
                    svc.0,
                    SERVICE_NO_CHANGE,
                    SERVICE_AUTO_START,
                    SERVICE_NO_CHANGE,
                    cmd.as_ptr(),
                    std::ptr::null(),
                    std::ptr::null_mut(),
                    std::ptr::null(),
                    std::ptr::null(),
                    std::ptr::null(),
                    std::ptr::null(),
                )
            };
            if ok == 0 {
                return Err(format!("can't update the service: {}", last_error()));
            }
            svc
        }
        None => {
            let (name, display) = (wide(SERVICE_NAME), wide(DISPLAY_NAME));
            let h = unsafe {
                CreateServiceW(
                    scm.0,
                    name.as_ptr(),
                    display.as_ptr(),
                    SERVICE_ALL_ACCESS,
                    SERVICE_WIN32_OWN_PROCESS,
                    SERVICE_AUTO_START,
                    SERVICE_ERROR_NORMAL,
                    cmd.as_ptr(),
                    std::ptr::null(),
                    std::ptr::null_mut(),
                    std::ptr::null(),
                    std::ptr::null(), // LocalSystem
                    std::ptr::null(),
                )
            };
            if h.is_null() {
                return Err(format!("can't create the service: {}", last_error()));
            }
            Scm(h)
        }
    };
    let mut desc_text = wide(DESCRIPTION);
    let desc = SERVICE_DESCRIPTIONW {
        lpDescription: desc_text.as_mut_ptr(),
    };
    unsafe {
        ChangeServiceConfig2W(
            svc.0,
            SERVICE_CONFIG_DESCRIPTION,
            (&desc as *const SERVICE_DESCRIPTIONW).cast(),
        )
    };
    // Restart after a crash, or after an update (which exits on purpose).
    let mut actions = [SC_ACTION {
        Type: SC_ACTION_RESTART,
        Delay: 3000,
    }; 3];
    let failure = SERVICE_FAILURE_ACTIONSW {
        dwResetPeriod: 24 * 60 * 60,
        lpRebootMsg: std::ptr::null_mut(),
        lpCommand: std::ptr::null_mut(),
        cActions: actions.len() as u32,
        lpsaActions: actions.as_mut_ptr(),
    };
    unsafe {
        ChangeServiceConfig2W(
            svc.0,
            SERVICE_CONFIG_FAILURE_ACTIONS,
            (&failure as *const SERVICE_FAILURE_ACTIONSW).cast(),
        )
    };
    start(Some(&svc))?;
    drop(svc);
    drop(scm);
    log::info!("service installed from {}", exe.display());
    Ok(())
}

/// Starts the service through a fresh connection; the service manager can
/// be briefly locked right after a change.
fn start(created: Option<&Scm>) -> Result<(), String> {
    const ERROR_SERVICE_ALREADY_RUNNING: i32 = 1056;
    const ERROR_SERVICE_DATABASE_LOCKED: i32 = 1055;
    const ERROR_SERVICE_REQUEST_TIMEOUT: i32 = 1053;
    let mut last = String::new();
    for attempt in 0..40 {
        // The handle that created or changed it first; then fresh ones.
        let fresh;
        let svc = match created {
            Some(h) if attempt < 20 => h,
            _ => {
                let scm = manager(SC_MANAGER_CONNECT)?;
                let Some(svc) = open(&scm, SERVICE_START) else {
                    last = format!("can't open the service: {}", last_error());
                    std::thread::sleep(Duration::from_millis(500));
                    continue;
                };
                fresh = (scm, svc);
                &fresh.1
            }
        };
        if unsafe { StartServiceW(svc.0, 0, std::ptr::null()) } != 0 {
            return Ok(());
        }
        let e = std::io::Error::last_os_error();
        match e.raw_os_error() {
            Some(ERROR_SERVICE_ALREADY_RUNNING) => return Ok(()),
            // Locked right after a change, or slow to answer the first
            // time: try again (a started service then says "running").
            Some(ERROR_SERVICE_DATABASE_LOCKED) | Some(ERROR_SERVICE_REQUEST_TIMEOUT) => {
                last = e.to_string();
                std::thread::sleep(Duration::from_millis(500));
            }
            _ => return Err(format!("can't start the service: {e}")),
        }
    }
    Err(format!("can't start the service: {last}"))
}

/// `--uninstall-service` (as administrator).
pub fn uninstall() -> Result<(), String> {
    let scm = manager(SC_MANAGER_ALL_ACCESS)
        .map_err(|e| format!("{e} (this needs administrator rights)"))?;
    match open(&scm, SERVICE_ALL_ACCESS) {
        Some(svc) => {
            stop_and_wait(&svc);
            if unsafe { DeleteService(svc.0) } == 0 {
                return Err(format!("can't remove the service: {}", last_error()));
            }
        }
        None if unsafe { GetLastError() } == ERROR_SERVICE_DOES_NOT_EXIST => {}
        None => return Err(format!("can't open the service: {}", last_error())),
    }
    let _ = std::fs::remove_dir_all(program_files());
    let _ = std::fs::remove_dir_all(program_data());
    Ok(())
}

/// Runs `this program args` as administrator (Windows asks the owner) and
/// waits for it. Used by the settings page.
pub fn run_elevated(args: &str) -> Result<(), String> {
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, INFINITE, WaitForSingleObject,
    };
    use windows_sys::Win32::UI::Shell::{
        SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW,
    };
    let exe = wide(std::env::current_exe().map_err(|e| e.to_string())?);
    let verb = wide("runas");
    let params = wide(args);
    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    info.fMask = SEE_MASK_NOCLOSEPROCESS;
    info.lpVerb = verb.as_ptr();
    info.lpFile = exe.as_ptr();
    info.lpParameters = params.as_ptr();
    info.nShow = 0;
    if unsafe { ShellExecuteExW(&mut info) } == 0 {
        let e = std::io::Error::last_os_error();
        return Err(if e.raw_os_error() == Some(1223) {
            "The administrator prompt was cancelled.".into()
        } else {
            format!("can't ask for administrator rights: {e}")
        });
    }
    let process = session::Handle(info.hProcess);
    unsafe { WaitForSingleObject(process.0, INFINITE) };
    let mut code = 1u32;
    unsafe { GetExitCodeProcess(process.0, &mut code) };
    if code == 0 {
        Ok(())
    } else {
        Err(format!(
            "it didn't work (code {code}); see %ProgramData%\\PairDesk\\service.log"
        ))
    }
}

// ------------------------------------------------------------- the service

static STOP: AtomicBool = AtomicBool::new(false);
static mut STATUS_HANDLE: SERVICE_STATUS_HANDLE = std::ptr::null_mut();

fn report(state: u32, exit: u32) {
    let st = SERVICE_STATUS {
        dwServiceType: SERVICE_WIN32_OWN_PROCESS,
        dwCurrentState: state,
        dwControlsAccepted: if state == SERVICE_RUNNING {
            SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN
        } else {
            0
        },
        dwWin32ExitCode: exit,
        dwServiceSpecificExitCode: 0,
        dwCheckPoint: 0,
        dwWaitHint: if state == SERVICE_RUNNING { 0 } else { 10_000 },
    };
    // SAFETY: set once in service_main before any report.
    unsafe { SetServiceStatus(STATUS_HANDLE, &st) };
}

unsafe extern "system" fn handler(
    control: u32,
    _: u32,
    _: *mut core::ffi::c_void,
    _: *mut core::ffi::c_void,
) -> u32 {
    match control {
        SERVICE_CONTROL_STOP | SERVICE_CONTROL_SHUTDOWN => {
            report(SERVICE_STOP_PENDING, NO_ERROR);
            STOP.store(true, Ordering::Relaxed);
            NO_ERROR
        }
        SERVICE_CONTROL_INTERROGATE => NO_ERROR,
        _ => 120, // ERROR_CALL_NOT_IMPLEMENTED
    }
}

unsafe extern "system" fn service_main(_argc: u32, _argv: *mut windows_sys::core::PWSTR) {
    let name = wide(SERVICE_NAME);
    let h =
        unsafe { RegisterServiceCtrlHandlerExW(name.as_ptr(), Some(handler), std::ptr::null()) };
    if h.is_null() {
        return;
    }
    unsafe { STATUS_HANDLE = h };
    report(SERVICE_RUNNING, NO_ERROR);
    work();
    report(SERVICE_STOPPED, NO_ERROR);
}

/// `--service`: hands this process to the service manager.
pub fn run() -> ! {
    let mut name = wide(SERVICE_NAME);
    let table = [
        SERVICE_TABLE_ENTRYW {
            lpServiceName: name.as_mut_ptr(),
            lpServiceProc: Some(service_main),
        },
        SERVICE_TABLE_ENTRYW {
            lpServiceName: std::ptr::null_mut(),
            lpServiceProc: None,
        },
    ];
    if unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) } == 0 {
        eprintln!(
            "--service is for the Windows service manager: {}",
            last_error()
        );
        std::process::exit(1);
    }
    std::process::exit(0);
}

/// A job that ends every helper when the service process ends.
struct Job(HANDLE);

impl Job {
    fn new() -> Option<Self> {
        let h = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if h.is_null() {
            return None;
        }
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        unsafe {
            SetInformationJobObject(
                h,
                JobObjectExtendedLimitInformation,
                (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        };
        Some(Job(h))
    }
}

fn work() {
    let base = program_data();
    let exe = std::env::current_exe().unwrap_or_default();
    let job = Job::new();
    let mut helper: Option<(u32, session::Child)> = None;
    let updater = Updater::new(Kind::Service, Source::github(), base.join("updates"));
    let mut next_update_check = Instant::now() + Duration::from_secs(120);
    log::info!("service started ({})", env!("CARGO_PKG_VERSION"));

    while !STOP.load(Ordering::Relaxed) {
        if let Some(sess) = session::active_console_session() {
            let alive = helper
                .as_ref()
                .is_some_and(|(s, c)| *s == sess && c.alive());
            if !alive {
                if let Some((_, old)) = helper.take() {
                    old.kill();
                }
                match session::spawn_system_in_session(sess, &exe, "--session-helper") {
                    Ok(child) => {
                        if let Some(job) = &job {
                            unsafe { AssignProcessToJobObject(job.0, child_handle(&child)) };
                        }
                        log::info!("helper started in session {sess} (pid {})", child.pid);
                        helper = Some((sess, child));
                    }
                    Err(e) => log::warn!("can't start the helper in session {sess}: {e}"),
                }
            }
            // The signed-in user's pairing, for the sign-in screen.
            if let Some(token) = session::user_token(sess)
                && let Some(appdata) = session::roaming_appdata(&token)
                && let Err(e) =
                    super::mirror(&appdata.join("PairDesk"), &super::system_data_dir(&base))
            {
                log::warn!("can't copy the pairing for the sign-in screen: {e}");
            }
        }
        if Instant::now() >= next_update_check {
            next_update_check = Instant::now() + Duration::from_secs(24 * 60 * 60);
            if updater.check().unwrap_or(false) {
                let quit: std::sync::Arc<dyn Fn() + Send + Sync> = std::sync::Arc::new(|| {
                    // Exiting without "stopped" makes the service manager
                    // start the new program in a few seconds.
                    log::info!("updated; restarting the service");
                    std::process::exit(2);
                });
                if let Err(e) = updater.install(quit) {
                    log::warn!("service update: {e}");
                }
            }
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    if let Some((_, c)) = helper {
        c.kill();
    }
    log::info!("service stopped");
}

fn child_handle(c: &session::Child) -> HANDLE {
    c.handle()
}
