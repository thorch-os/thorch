use std::collections::{HashMap, HashSet};
use std::env;
use std::ffi::c_char;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

const EV_KEY: u16 = 1;
const EV_SYN: u16 = 0;
const EV_ABS: u16 = 3;
const SYN_REPORT: u16 = 0;
const KEY_VOLUMEDOWN: u16 = 114;
const KEY_VOLUMEUP: u16 = 115;
const KEY_RECORD: u16 = 167;
const KEY_F24: u16 = 194;
const BTN_BACK: u16 = 278;
const BTN_SOUTH: u16 = 304;
const BTN_EAST: u16 = 305;
const BTN_NORTH: u16 = 307;
const BTN_WEST: u16 = 308;
const BTN_TL: u16 = 310;
const BTN_SELECT: u16 = 314;
const BTN_START: u16 = 315;
const BTN_MODE: u16 = 316;
const BTN_TOUCH: u16 = 330;
const BTN_DPAD_UP: u16 = 544;
const BTN_DPAD_DOWN: u16 = 545;
const BTN_DPAD_LEFT: u16 = 546;
const BTN_DPAD_RIGHT: u16 = 547;
const ABS_HAT0X: u16 = 16;
const ABS_HAT0Y: u16 = 17;
const EVIOCGRAB: usize = 0x40044590;
const UI_SET_EVBIT: usize = 0x40045564;
const UI_SET_KEYBIT: usize = 0x40045565;
const UI_DEV_CREATE: usize = 0x5501;
const UI_DEV_DESTROY: usize = 0x5502;
const POLLIN: i16 = 0x0001;
const IN_NONBLOCK: i32 = 0x00000800;
const IN_CLOEXEC: i32 = 0x00080000;
const IN_CREATE: u32 = 0x00000100;
const IN_DELETE: u32 = 0x00000200;
const IN_MOVED_FROM: u32 = 0x00000040;
const IN_MOVED_TO: u32 = 0x00000080;
const IN_ATTRIB: u32 = 0x00000004;

#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

#[link(name = "c")]
extern "C" {
    fn poll(fds: *mut PollFd, nfds: usize, timeout: i32) -> i32;
    fn ioctl(fd: i32, request: usize, ...) -> i32;
    fn inotify_init1(flags: i32) -> i32;
    fn inotify_add_watch(fd: i32, pathname: *const c_char, mask: u32) -> i32;
}

struct OpenedDevice {
    file: File,
    path: PathBuf,
    name: String,
    grab_allowed: bool,
}

struct InputWatcher {
    file: File,
}

struct UInputKeyboard {
    file: File,
}

struct Config {
    input_root: PathBuf,
    event_root: PathBuf,
    device_names: HashSet<String>,
    brightness_modifiers: HashSet<u16>,
    led_modifiers: HashSet<u16>,
    rocknix_hotkey_modifiers: HashSet<u16>,
    repeat_delay: Duration,
    backlight: String,
    brightness_target: String,
    brightness_step: String,
    rgb: String,
    rfkill: String,
    nmcli: String,
    volume: String,
    screenshot: String,
    mangohud: String,
    screen_switch: String,
    game_guide: String,
    keyboard_signal: String,
    kill_data: PathBuf,
    dpad_events: bool,
    touch_events: bool,
    f24_relay: bool,
}

fn key_code(name: &str) -> Option<u16> {
    if let Ok(code) = name.parse::<u16>() {
        return Some(code);
    }

    match name {
        "KEY_VOLUMEDOWN" => Some(KEY_VOLUMEDOWN),
        "KEY_VOLUMEUP" => Some(KEY_VOLUMEUP),
        "KEY_RECORD" => Some(KEY_RECORD),
        "KEY_F24" => Some(KEY_F24),
        "BTN_BACK" => Some(BTN_BACK),
        "BTN_SOUTH" => Some(BTN_SOUTH),
        "BTN_EAST" => Some(BTN_EAST),
        "BTN_NORTH" => Some(BTN_NORTH),
        "BTN_WEST" => Some(BTN_WEST),
        "BTN_TL" => Some(BTN_TL),
        "BTN_SELECT" => Some(BTN_SELECT),
        "BTN_START" => Some(BTN_START),
        "BTN_MODE" => Some(BTN_MODE),
        "BTN_TOUCH" => Some(BTN_TOUCH),
        "BTN_DPAD_UP" => Some(BTN_DPAD_UP),
        "BTN_DPAD_DOWN" => Some(BTN_DPAD_DOWN),
        "BTN_DPAD_LEFT" => Some(BTN_DPAD_LEFT),
        "BTN_DPAD_RIGHT" => Some(BTN_DPAD_RIGHT),
        _ => None,
    }
}

fn env_value(names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| env::var(name).ok())
}

fn env_or(names: &[&str], default: &str) -> String {
    env_value(names).unwrap_or_else(|| default.to_string())
}

fn env_bool(names: &[&str], default: bool) -> bool {
    match env_value(names).as_deref() {
        Some("1" | "true" | "yes" | "on") => true,
        Some("0" | "false" | "no" | "off") => false,
        _ => default,
    }
}

fn parse_key_set(env_names: &[&str], defaults: &[&str]) -> HashSet<u16> {
    let raw = env_value(env_names);
    let names: Vec<String> = raw
        .as_deref()
        .map(|value| value.split_whitespace().map(str::to_owned).collect())
        .unwrap_or_else(|| defaults.iter().map(|value| value.to_string()).collect());

    names.iter().filter_map(|name| key_code(name)).collect()
}

fn parse_name_set(env_names: &[&str], defaults: &[&str]) -> HashSet<String> {
    env_value(env_names)
        .map(|value| value.split_whitespace().map(str::to_owned).collect())
        .unwrap_or_else(|| defaults.iter().map(|value| value.to_string()).collect())
}

impl Config {
    fn load() -> Self {
        let repeat_seconds = env_or(&["THORCH_INPUTD_REPEAT_SECONDS", "THORCH_HWCONTROLD_REPEAT_SECONDS"], "0.08")
            .parse::<f64>()
            .unwrap_or(0.08);

        Self {
            input_root: PathBuf::from(env_or(
                &["THORCH_INPUTD_INPUT_ROOT", "THORCH_HWCONTROLD_INPUT_ROOT"],
                "/sys/class/input",
            )),
            event_root: PathBuf::from(env_or(
                &["THORCH_INPUTD_EVENT_ROOT", "THORCH_HWCONTROLD_EVENT_ROOT"],
                "/dev/input",
            )),
            device_names: parse_name_set(
                &["THORCH_INPUTD_DEVICE_NAMES", "THORCH_HWCONTROLD_DEVICE_NAMES"],
                &[
                    "gpio-keys",
                    "pmic_resin",
                    "AYN Odin2 Gamepad",
                    "RSInput Gamepad",
                    "InputPlumber Keyboard",
                    "Microsoft Xbox Series S|X Controller",
                ],
            ),
            brightness_modifiers: parse_key_set(
                &["THORCH_INPUTD_BRIGHTNESS_MODIFIERS", "THORCH_HWCONTROLD_MODIFIERS"],
                &["BTN_MODE"],
            ),
            led_modifiers: parse_key_set(
                &["THORCH_INPUTD_LED_MODIFIERS", "THORCH_HWCONTROLD_LED_MODIFIERS"],
                &["BTN_START"],
            ),
            rocknix_hotkey_modifiers: parse_key_set(&["THORCH_INPUTD_HOTKEY_A_MODIFIERS"], &["BTN_TL"]),
            repeat_delay: Duration::from_secs_f64(repeat_seconds),
            backlight: env_or(
                &["THORCH_INPUTD_BACKLIGHT", "THORCH_HWCONTROLD_BACKLIGHT"],
                "/usr/bin/thorch-backlight",
            ),
            brightness_target: env_or(
                &["THORCH_INPUTD_BRIGHTNESS_TARGET", "THORCH_HWCONTROLD_BRIGHTNESS_TARGET"],
                "all",
            ),
            brightness_step: env_or(
                &[
                    "THORCH_INPUTD_BRIGHTNESS_STEP_PERCENT",
                    "THORCH_HWCONTROLD_BRIGHTNESS_STEP_PERCENT",
                ],
                "5",
            ),
            rgb: env_or(&["THORCH_INPUTD_RGB", "THORCH_HWCONTROLD_RGB"], "/usr/bin/thorch-rgb"),
            rfkill: env_or(&["THORCH_INPUTD_RFKILL", "THORCH_HWCONTROLD_RFKILL"], "/usr/bin/rfkill"),
            nmcli: env_or(&["THORCH_INPUTD_NMCLI", "THORCH_HWCONTROLD_NMCLI"], "/usr/bin/nmcli"),
            volume: env_or(&["THORCH_INPUTD_VOLUME"], "/usr/bin/pactl"),
            screenshot: env_or(&["THORCH_INPUTD_SCREENSHOT"], "/usr/bin/rocknix-screenshot"),
            mangohud: env_or(&["THORCH_INPUTD_MANGOHUD"], "/usr/bin/mangohud_set"),
            screen_switch: env_or(&["THORCH_INPUTD_SCREEN_SWITCH"], "/usr/bin/screen_switch"),
            game_guide: env_or(&["THORCH_INPUTD_GAME_GUIDE"], "/usr/bin/game-guides-tool"),
            keyboard_signal: env_or(&["THORCH_INPUTD_KEYBOARD_SIGNAL"], "/usr/bin/pkill"),
            kill_data: PathBuf::from(env_or(&["THORCH_INPUTD_KILL_DATA"], "/tmp/.process-kill-data")),
            dpad_events: env_bool(&["THORCH_INPUTD_DPAD_EVENTS"], true),
            touch_events: env_bool(&["THORCH_INPUTD_TOUCH_EVENTS"], false),
            f24_relay: env_bool(&["THORCH_INPUTD_F24_RELAY"], true),
        }
    }
}

fn input_devices(config: &Config) -> Vec<PathBuf> {
    let mut devices = Vec::new();
    let entries = match fs::read_dir(&config.input_root) {
        Ok(entries) => entries,
        Err(_) => return devices,
    };

    let mut names: Vec<_> = entries.filter_map(Result::ok).collect();
    names.sort_by_key(|entry| entry.file_name());

    for entry in names {
        let file_name = entry.file_name();
        let event_name = file_name.to_string_lossy();
        if !event_name.starts_with("event") {
            continue;
        }

        let name_path = entry.path().join("device/name");
        let name = match fs::read_to_string(name_path) {
            Ok(name) => name.trim().to_string(),
            Err(_) => continue,
        };
        if config.device_names.contains(&name) {
            devices.push(config.event_root.join(event_name.as_ref()));
        }
    }

    devices
}

fn input_device_name(config: &Config, event_name: &str) -> String {
    fs::read_to_string(config.input_root.join(event_name).join("device/name"))
        .map(|name| name.trim().to_string())
        .unwrap_or_default()
}

fn log(message: &str) {
    eprintln!("thorch-inputd: {message}");
}

fn can_grab_device(name: &str) -> bool {
    !matches!(name, "pmic_pwrkey" | "gpio-keys" | "pmic_resin")
}

fn should_grab_on_open(name: &str) -> bool {
    matches!(name, "gpio-keys" | "pmic_resin")
}

fn run_command(program: &str, args: &[&str]) {
    let _ = Command::new(program).args(args).status();
}

fn run_capture(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn thorch_user() -> String {
    let mut candidates = Vec::new();
    if let Ok(entries) = fs::read_dir("/etc/sddm.conf.d") {
        for entry in entries.filter_map(Result::ok) {
            candidates.push(entry.path());
        }
    }
    candidates.push(PathBuf::from("/etc/sddm.conf"));

    for path in candidates {
        let Ok(text) = fs::read_to_string(path) else {
            continue;
        };
        let mut autologin = false;
        for line in text.lines() {
            let line = line.trim();
            if line.starts_with('[') {
                autologin = line == "[Autologin]";
                continue;
            }
            if autologin {
                if let Some((key, value)) = line.split_once('=') {
                    if key.trim() == "User" {
                        return value.trim().to_string();
                    }
                }
            }
        }
    }

    "thorch".to_string()
}

fn passwd_home(user: &str) -> Option<String> {
    let text = fs::read_to_string("/etc/passwd").ok()?;
    for line in text.lines() {
        let parts: Vec<_> = line.split(':').collect();
        if parts.len() >= 6 && parts[0] == user {
            return Some(parts[5].to_string());
        }
    }
    None
}

fn run_as_user(program: &str, args: &[&str]) -> bool {
    let user = thorch_user();
    let Some(home) = passwd_home(&user) else {
        return false;
    };
    let Some(uid) = run_capture("id", &["-u", &user]) else {
        return false;
    };
    Command::new("runuser")
        .arg("-u")
        .arg(&user)
        .arg("--")
        .arg("env")
        .arg(format!("HOME={home}"))
        .arg(format!("XDG_RUNTIME_DIR=/run/user/{uid}"))
        .arg(format!("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus"))
        .arg(program)
        .args(args)
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn run_backlight(config: &Config, direction: &str) {
    run_command(
        &config.backlight,
        &[direction, &config.brightness_target, &config.brightness_step],
    );
}

fn run_rgb(config: &Config, enabled: bool) {
    run_command(&config.rgb, &[if enabled { "battery" } else { "off" }]);
}

fn run_wifi(config: &Config, enabled: bool) {
    if enabled {
        run_command(&config.rfkill, &["unblock", "wifi"]);
        run_command(&config.nmcli, &["radio", "wifi", "on"]);
    } else {
        run_command(&config.nmcli, &["radio", "wifi", "off"]);
        run_command(&config.rfkill, &["block", "wifi"]);
    }
}

fn run_volume(config: &Config, direction: &str) {
    let value = if direction == "up" { "+5%" } else { "-5%" };
    if direction == "up" {
        let mute_args = ["set-sink-mute", "@DEFAULT_SINK@", "false"];
        if !run_as_user(&config.volume, &mute_args) {
            run_command(&config.volume, &mute_args);
        }
    }
    let args = ["set-sink-volume", "@DEFAULT_SINK@", value];
    if !run_as_user(&config.volume, &args) {
        run_command(&config.volume, &args);
    }
}

fn execute_kill(config: &Config) {
    let Ok(name) = fs::read_to_string(&config.kill_data) else {
        return;
    };
    let name = name.trim();
    if !name.is_empty() {
        run_command("killall", &[name]);
    }
}

fn toggle_keyboard(config: &Config) {
    run_command(&config.keyboard_signal, &["-34", "wvkbd-mobintl"]);
}

fn run_hotkey_command(config: &Config, code: u16) {
    match code {
        BTN_EAST => run_command(&config.screenshot, &[]),
        BTN_WEST => run_command(&config.mangohud, &["toggle"]),
        BTN_BACK | KEY_RECORD => run_command(&config.screen_switch, &[]),
        BTN_NORTH => run_command(&config.game_guide, &[]),
        _ => {}
    }
}

fn set_grab(file: &File, enabled: bool) {
    let value: i32 = if enabled { 1 } else { 0 };
    unsafe {
        ioctl(file.as_raw_fd(), EVIOCGRAB, &value);
    }
}

impl UInputKeyboard {
    fn create(name: &str) -> io::Result<Self> {
        let mut file = OpenOptions::new().write(true).open("/dev/uinput")?;
        set_uinput_bit(&file, UI_SET_EVBIT, EV_KEY)?;
        set_uinput_bit(&file, UI_SET_KEYBIT, KEY_F24)?;
        write_uinput_user_dev(&mut file, name)?;
        ioctl_simple(&file, UI_DEV_CREATE)?;
        Ok(Self { file })
    }

    fn emit_key(&mut self, code: u16, value: i32) -> io::Result<()> {
        write_input_event(&mut self.file, EV_KEY, code, value)?;
        write_input_event(&mut self.file, EV_SYN, SYN_REPORT, 0)
    }
}

impl Drop for UInputKeyboard {
    fn drop(&mut self) {
        let _ = ioctl_simple(&self.file, UI_DEV_DESTROY);
    }
}

fn ioctl_simple(file: &File, request: usize) -> io::Result<()> {
    let result = unsafe { ioctl(file.as_raw_fd(), request, 0) };
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn set_uinput_bit(file: &File, request: usize, bit: u16) -> io::Result<()> {
    let result = unsafe { ioctl(file.as_raw_fd(), request, bit as i32) };
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn write_uinput_user_dev(file: &mut File, name: &str) -> io::Result<()> {
    let mut data = [0u8; 1116];
    let name_bytes = name.as_bytes();
    let len = name_bytes.len().min(79);
    data[..len].copy_from_slice(&name_bytes[..len]);
    file.write_all(&data)
}

fn write_input_event(file: &mut File, event_type: u16, code: u16, value: i32) -> io::Result<()> {
    let mut data = [0u8; 24];
    data[16..18].copy_from_slice(&event_type.to_ne_bytes());
    data[18..20].copy_from_slice(&code.to_ne_bytes());
    data[20..24].copy_from_slice(&value.to_ne_bytes());
    file.write_all(&data)
}

fn should_relay_f24(enabled: bool, device_name: &str, event_type: u16, code: u16, value: i32) -> bool {
    enabled
        && device_name == "gpio-keys"
        && event_type == EV_KEY
        && code == KEY_F24
        && matches!(value, 0 | 1 | 2)
}

fn read_event(file: &mut File) -> io::Result<(u16, u16, i32)> {
    let mut buf = [0u8; 24];
    file.read_exact(&mut buf)?;

    let event_type = u16::from_ne_bytes([buf[16], buf[17]]);
    let code = u16::from_ne_bytes([buf[18], buf[19]]);
    let value = i32::from_ne_bytes([buf[20], buf[21], buf[22], buf[23]]);
    Ok((event_type, code, value))
}

fn create_input_watcher(config: &Config) -> Option<InputWatcher> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let fd = unsafe { inotify_init1(IN_NONBLOCK | IN_CLOEXEC) };
    if fd < 0 {
        log("failed to create inotify watcher; falling back to periodic retry");
        return None;
    }
    let file = unsafe { File::from_raw_fd(fd) };

    let mask = IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB;
    let mut watched = 0;
    let mut watched_event_root = false;
    for (path, is_event_root) in [(&config.input_root, false), (&config.event_root, true)] {
        let Ok(path) = CString::new(path.as_os_str().as_bytes()) else {
            continue;
        };
        let watch = unsafe { inotify_add_watch(file.as_raw_fd(), path.as_ptr(), mask) };
        if watch >= 0 {
            watched += 1;
            watched_event_root |= is_event_root;
        }
    }
    if watched == 0 {
        log("failed to watch input roots; falling back to periodic retry");
        return None;
    }
    if !watched_event_root {
        log("failed to watch event root; falling back to periodic retry");
        return None;
    }

    Some(InputWatcher { file })
}

fn drain_input_watcher(watcher: &mut InputWatcher) {
    let mut buf = [0u8; 4096];
    loop {
        match watcher.file.read(&mut buf) {
            Ok(0) => break,
            Ok(_) => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
            Err(_) => break,
        }
    }
}

fn open_new_devices(
    config: &Config,
    devices: &mut HashMap<i32, OpenedDevice>,
    opened_paths: &mut HashSet<PathBuf>,
) {
    for path in input_devices(config) {
        if opened_paths.contains(&path) {
            continue;
        }

        let event_name = path.file_name().and_then(|name| name.to_str()).unwrap_or("");
        let device_name = input_device_name(config, event_name);
        let Ok(file) = File::open(&path) else {
            continue;
        };
        if should_grab_on_open(&device_name) {
            set_grab(&file, true);
        }

        let fd = file.as_raw_fd();
        log(&format!("opened {} ({})", path.display(), device_name));
        opened_paths.insert(path.clone());
        devices.insert(
            fd,
            OpenedDevice {
                file,
                path,
                name: device_name.clone(),
                grab_allowed: can_grab_device(&device_name),
            },
        );
    }
}

fn remove_device(
    fd: i32,
    devices: &mut HashMap<i32, OpenedDevice>,
    opened_paths: &mut HashSet<PathBuf>,
    pressed: &mut HashSet<u16>,
    modifier_fds: &mut HashMap<i32, HashSet<u16>>,
    grabbed_fds: &mut HashSet<i32>,
    reason: &str,
) {
    if let Some(opened) = devices.remove(&fd) {
        if grabbed_fds.remove(&fd) {
            set_grab(&opened.file, false);
        }
        opened_paths.remove(&opened.path);
        modifier_fds.remove(&fd);
        pressed.clear();
        log(&format!("removed {} ({}) after {reason}", opened.path.display(), opened.name));
    }
}

fn prune_missing_devices(
    devices: &mut HashMap<i32, OpenedDevice>,
    opened_paths: &mut HashSet<PathBuf>,
    pressed: &mut HashSet<u16>,
    modifier_fds: &mut HashMap<i32, HashSet<u16>>,
    grabbed_fds: &mut HashSet<i32>,
) {
    let missing_fds: Vec<i32> = devices
        .iter()
        .filter_map(|(fd, opened)| (!opened.path.exists()).then_some(*fd))
        .collect();
    for fd in missing_fds {
        remove_device(
            fd,
            devices,
            opened_paths,
            pressed,
            modifier_fds,
            grabbed_fds,
            "path disappeared",
        );
    }
}

fn sync_grabs(
    devices: &HashMap<i32, OpenedDevice>,
    pressed: &HashSet<u16>,
    hotkey_modifiers: &HashSet<u16>,
    modifier_fds: &HashMap<i32, HashSet<u16>>,
    grabbed_fds: &mut HashSet<i32>,
) {
    let should_grab = pressed.iter().any(|code| hotkey_modifiers.contains(code));
    for (fd, opened) in devices {
        if !opened.grab_allowed {
            continue;
        }
        let wants_grab = should_grab && !modifier_fds.contains_key(fd);
        let is_grabbed = grabbed_fds.contains(fd);
        if wants_grab == is_grabbed {
            continue;
        }
        set_grab(&opened.file, wants_grab);
        if wants_grab {
            grabbed_fds.insert(*fd);
        } else {
            grabbed_fds.remove(fd);
        }
    }
}

fn main() {
    let config = Config::load();
    let hotkey_modifiers: HashSet<u16> = config
        .brightness_modifiers
        .union(&config.led_modifiers)
        .chain(config.rocknix_hotkey_modifiers.iter())
        .copied()
        .collect();

    let mut pressed = HashSet::new();
    let mut modifier_fds: HashMap<i32, HashSet<u16>> = HashMap::new();
    let mut grabbed_fds = HashSet::new();
    let mut last_adjust: HashMap<u16, Instant> = HashMap::new();

    let mut devices: HashMap<i32, OpenedDevice> = HashMap::new();
    let mut opened_paths = HashSet::new();
    let mut watcher = create_input_watcher(&config);
    open_new_devices(&config, &mut devices, &mut opened_paths);
    let mut f24_keyboard = if config.f24_relay {
        match UInputKeyboard::create("Thorch Hardware Keys") {
            Ok(keyboard) => Some(keyboard),
            Err(error) => {
                log(&format!("failed to create F24 relay keyboard: {error}"));
                None
            }
        }
    } else {
        None
    };

    loop {
        let watcher_fd = watcher.as_ref().map(|watcher| watcher.file.as_raw_fd());
        let mut poll_fds: Vec<PollFd> = devices
            .keys()
            .map(|fd| PollFd {
                fd: *fd,
                events: POLLIN,
                revents: 0,
            })
            .collect();
        if let Some(fd) = watcher_fd {
            poll_fds.push(PollFd {
                fd,
                events: POLLIN,
                revents: 0,
            });
        }

        if poll_fds.is_empty() {
            thread::sleep(Duration::from_secs(1));
            open_new_devices(&config, &mut devices, &mut opened_paths);
            continue;
        }

        let timeout = if watcher.is_some() { -1 } else { 1000 };
        let poll_result = unsafe { poll(poll_fds.as_mut_ptr(), poll_fds.len(), timeout) };
        if poll_result < 0 {
            continue;
        }
        if poll_result == 0 {
            open_new_devices(&config, &mut devices, &mut opened_paths);
            continue;
        }

        let mut rescan = false;
        let mut failed_fds = Vec::new();

        for poll_fd in poll_fds.iter().filter(|fd| fd.revents & POLLIN != 0) {
            if Some(poll_fd.fd) == watcher_fd {
                if let Some(input_watcher) = watcher.as_mut() {
                    drain_input_watcher(input_watcher);
                }
                rescan = true;
                continue;
            }

            let Some(opened) = devices.get_mut(&poll_fd.fd) else {
                continue;
            };
            let (event_type, code, value) = match read_event(&mut opened.file) {
                Ok(event) => event,
                Err(_) => {
                    failed_fds.push(poll_fd.fd);
                    continue;
                }
            };

            if should_relay_f24(config.f24_relay, &opened.name, event_type, code, value) {
                if let Some(keyboard) = f24_keyboard.as_mut() {
                    if let Err(error) = keyboard.emit_key(code, value) {
                        log(&format!("failed to relay F24 event: {error}"));
                        f24_keyboard = None;
                    }
                }
            }

            if event_type == EV_ABS && config.dpad_events {
                let direction = match (code, value) {
                    (ABS_HAT0Y, -1) => Some("up"),
                    (ABS_HAT0Y, 1) => Some("down"),
                    (ABS_HAT0X, 1) => Some("right"),
                    (ABS_HAT0X, -1) => Some("left"),
                    _ => None,
                };
                if direction.is_some()
                    && pressed
                        .iter()
                        .any(|pressed_code| config.brightness_modifiers.contains(pressed_code))
                {
                    match direction.unwrap() {
                        "up" => run_volume(&config, "up"),
                        "down" => run_volume(&config, "down"),
                        "right" => run_backlight(&config, "up"),
                        "left" => run_backlight(&config, "down"),
                        _ => {}
                    }
                }
                continue;
            }
            if event_type != EV_KEY {
                continue;
            }

            if value == 1 || value == 2 {
                pressed.insert(code);
            } else if value == 0 {
                pressed.remove(&code);
            }

            if hotkey_modifiers.contains(&code) {
                let fd_modifiers = modifier_fds.entry(poll_fd.fd).or_default();
                if value == 1 || value == 2 {
                    fd_modifiers.insert(code);
                } else if value == 0 {
                    fd_modifiers.remove(&code);
                    if fd_modifiers.is_empty() {
                        modifier_fds.remove(&poll_fd.fd);
                    }
                }
                sync_grabs(
                    &devices,
                    &pressed,
                    &hotkey_modifiers,
                    &modifier_fds,
                    &mut grabbed_fds,
                );
            }

            if value == 1
                && config
                    .rocknix_hotkey_modifiers
                    .iter()
                    .any(|modifier| pressed.contains(modifier))
            {
                if matches!(code, BTN_EAST | BTN_WEST | BTN_BACK | KEY_RECORD | BTN_NORTH) {
                    run_hotkey_command(&config, code);
                } else if config.touch_events && code == BTN_TOUCH {
                    toggle_keyboard(&config);
                }
                let hotkey_count = config
                    .rocknix_hotkey_modifiers
                    .iter()
                    .filter(|modifier| pressed.contains(modifier))
                    .count();
                if hotkey_count > 0 && pressed.contains(&BTN_SELECT) && pressed.contains(&BTN_START) {
                    execute_kill(&config);
                }
            }

            if value == 1
                && config.dpad_events
                && pressed
                    .iter()
                    .any(|pressed_code| config.brightness_modifiers.contains(pressed_code))
            {
                match code {
                    BTN_DPAD_UP => run_volume(&config, "up"),
                    BTN_DPAD_DOWN => run_volume(&config, "down"),
                    BTN_DPAD_RIGHT => run_backlight(&config, "up"),
                    BTN_DPAD_LEFT => run_backlight(&config, "down"),
                    _ => {}
                }
            }

            let direction = match code {
                KEY_VOLUMEUP if value == 1 || value == 2 => "up",
                KEY_VOLUMEDOWN if value == 1 || value == 2 => "down",
                _ => continue,
            };

            let has_brightness_modifier = pressed
                .iter()
                .any(|code| config.brightness_modifiers.contains(code));
            let has_led_modifier = pressed.iter().any(|code| config.led_modifiers.contains(code));
            let now = Instant::now();
            if value == 2 {
                if let Some(last) = last_adjust.get(&code) {
                    if now.duration_since(*last) < config.repeat_delay {
                        continue;
                    }
                }
            }
            last_adjust.insert(code, now);

            if !has_brightness_modifier && !has_led_modifier {
                run_volume(&config, direction);
                continue;
            }

            if has_brightness_modifier && has_led_modifier {
                run_wifi(&config, direction == "up");
            } else if has_led_modifier {
                run_rgb(&config, direction == "up");
            } else {
                run_backlight(&config, direction);
            }
        }

        for fd in failed_fds {
            remove_device(
                fd,
                &mut devices,
                &mut opened_paths,
                &mut pressed,
                &mut modifier_fds,
                &mut grabbed_fds,
                "read failure",
            );
            rescan = true;
        }

        if rescan {
            prune_missing_devices(
                &mut devices,
                &mut opened_paths,
                &mut pressed,
                &mut modifier_fds,
                &mut grabbed_fds,
            );
            open_new_devices(&config, &mut devices, &mut opened_paths);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn test_root(name: &str) -> PathBuf {
        let mut path = env::temp_dir();
        path.push(format!(
            "thorch-inputd-test-{}-{}",
            std::process::id(),
            name
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn write(path: &PathBuf, value: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, value).unwrap();
    }

    fn clear_env(names: &[&str]) {
        for name in names {
            env::remove_var(name);
        }
    }

    #[test]
    fn key_code_accepts_named_and_numeric_codes() {
        assert_eq!(key_code("KEY_VOLUMEUP"), Some(KEY_VOLUMEUP));
        assert_eq!(key_code("BTN_DPAD_LEFT"), Some(BTN_DPAD_LEFT));
        assert_eq!(key_code("330"), Some(BTN_TOUCH));
        assert_eq!(key_code("DOES_NOT_EXIST"), None);
    }

    #[test]
    fn parse_key_set_prefers_new_env_and_keeps_legacy_fallback() {
        let _guard = env_lock().lock().unwrap();
        clear_env(&["THORCH_INPUTD_TEST_KEYS", "THORCH_HWCONTROLD_TEST_KEYS"]);

        env::set_var("THORCH_HWCONTROLD_TEST_KEYS", "BTN_START");
        assert_eq!(
            parse_key_set(&["THORCH_INPUTD_TEST_KEYS", "THORCH_HWCONTROLD_TEST_KEYS"], &["BTN_MODE"]),
            HashSet::from([BTN_START])
        );

        env::set_var("THORCH_INPUTD_TEST_KEYS", "BTN_MODE KEY_VOLUMEUP 999");
        assert_eq!(
            parse_key_set(&["THORCH_INPUTD_TEST_KEYS", "THORCH_HWCONTROLD_TEST_KEYS"], &[]),
            HashSet::from([BTN_MODE, KEY_VOLUMEUP, 999])
        );

        clear_env(&["THORCH_INPUTD_TEST_KEYS", "THORCH_HWCONTROLD_TEST_KEYS"]);
    }

    #[test]
    fn env_bool_parses_common_values_and_defaults_unknown_values() {
        let _guard = env_lock().lock().unwrap();
        clear_env(&["THORCH_INPUTD_BOOL_TEST"]);

        assert!(env_bool(&["THORCH_INPUTD_BOOL_TEST"], true));
        env::set_var("THORCH_INPUTD_BOOL_TEST", "yes");
        assert!(env_bool(&["THORCH_INPUTD_BOOL_TEST"], false));
        env::set_var("THORCH_INPUTD_BOOL_TEST", "0");
        assert!(!env_bool(&["THORCH_INPUTD_BOOL_TEST"], true));
        env::set_var("THORCH_INPUTD_BOOL_TEST", "maybe");
        assert!(env_bool(&["THORCH_INPUTD_BOOL_TEST"], true));

        clear_env(&["THORCH_INPUTD_BOOL_TEST"]);
    }

    #[test]
    fn default_device_names_own_volume_keys_without_grabbing_power_key() {
        let _guard = env_lock().lock().unwrap();
        clear_env(&["THORCH_INPUTD_DEVICE_NAMES", "THORCH_HWCONTROLD_DEVICE_NAMES"]);

        let config = Config::load();

        assert!(config.device_names.contains("InputPlumber Keyboard"));
        assert!(config.device_names.contains("gpio-keys"));
        assert!(config.device_names.contains("pmic_resin"));
        assert!(!config.device_names.contains("pmic_pwrkey"));
        assert!(!can_grab_device("pmic_pwrkey"));
        assert!(!can_grab_device("gpio-keys"));
        assert!(!can_grab_device("pmic_resin"));
        assert!(can_grab_device("InputPlumber Keyboard"));
        assert!(should_grab_on_open("gpio-keys"));
        assert!(should_grab_on_open("pmic_resin"));
        assert!(!should_grab_on_open("pmic_pwrkey"));
    }

    #[test]
    fn input_devices_filters_matching_event_devices_in_order() {
        let root = test_root("devices");
        let sys_input = root.join("sys/class/input");
        let dev_input = root.join("dev/input");

        write(&sys_input.join("event2/device/name"), "RSInput Gamepad\n");
        write(&sys_input.join("event0/device/name"), "keyboard\n");
        write(&sys_input.join("mouse0/device/name"), "RSInput Gamepad\n");
        write(&sys_input.join("event1/device/name"), "gpio-keys\n");
        fs::create_dir_all(&dev_input).unwrap();

        let config = Config {
            input_root: sys_input,
            event_root: dev_input.clone(),
            device_names: HashSet::from(["gpio-keys".to_string(), "RSInput Gamepad".to_string()]),
            brightness_modifiers: HashSet::new(),
            led_modifiers: HashSet::new(),
            rocknix_hotkey_modifiers: HashSet::new(),
            repeat_delay: Duration::from_millis(1),
            backlight: String::new(),
            brightness_target: String::new(),
            brightness_step: String::new(),
            rgb: String::new(),
            rfkill: String::new(),
            nmcli: String::new(),
            volume: String::new(),
            screenshot: String::new(),
            mangohud: String::new(),
            screen_switch: String::new(),
            game_guide: String::new(),
            keyboard_signal: String::new(),
            kill_data: root.join("kill-data"),
            dpad_events: true,
            touch_events: false,
            f24_relay: true,
        };

        assert_eq!(
            input_devices(&config),
            vec![dev_input.join("event1"), dev_input.join("event2")]
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn f24_relay_only_mirrors_gpio_key_f24_events_when_enabled() {
        const EV_SW: u16 = 5;
        const SW_LID: u16 = 0;

        assert!(should_relay_f24(true, "gpio-keys", EV_KEY, KEY_F24, 1));
        assert!(should_relay_f24(true, "gpio-keys", EV_KEY, KEY_F24, 0));
        assert!(should_relay_f24(true, "gpio-keys", EV_KEY, KEY_F24, 2));
        assert!(!should_relay_f24(false, "gpio-keys", EV_KEY, KEY_F24, 1));
        assert!(!should_relay_f24(true, "InputPlumber Keyboard", EV_KEY, KEY_F24, 1));
        assert!(!should_relay_f24(true, "gpio-keys", EV_SW, SW_LID, 1));
        assert!(!should_relay_f24(true, "gpio-keys", EV_KEY, KEY_VOLUMEUP, 1));
        assert!(!should_relay_f24(true, "gpio-keys", EV_KEY, KEY_F24, 3));
    }
}
