#![windows_subsystem = "windows"]

use std::{
    env,
    fs::{self, OpenOptions},
    io::{self, Write},
    os::windows::process::CommandExt,
    path::PathBuf,
    process::{self, Command, Stdio},
};

#[link(name = "user32")]
extern "system" {
    fn MessageBoxW(
        window: *mut std::ffi::c_void,
        text: *const u16,
        title: *const u16,
        flags: u32,
    ) -> i32;
}

fn log_path() -> PathBuf {
    env::var_os("ALJAM3_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            env::var_os("LOCALAPPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(env::temp_dir)
                .join("Aljam3")
        })
        .join("launcher.log")
}

fn report_error(reason: &str) {
    let path = log_path();
    eprintln!("Aljam3: {reason}\nLog: {}", path.display());
    if let Ok(mut log) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(log, "Aljam3: {reason}");
    }
    if env::var("SCARPE_NATIVE_HEADLESS").as_deref() == Ok("1") {
        return;
    }
    let text: Vec<u16> = format!(
        "تعذر تشغيل الجامع.\n\n{reason}\n\nمسار سجل الأخطاء:\n\u{2066}{}\u{2069}",
        path.display()
    )
    .encode_utf16()
    .chain(Some(0))
    .collect();
    let title: Vec<u16> = "الجامع".encode_utf16().chain(Some(0)).collect();
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            text.as_ptr(),
            title.as_ptr(),
            0x00180010,
        );
    }
}

fn launch() -> io::Result<i32> {
    let exe = env::current_exe()?;
    let root = exe
        .parent()
        .ok_or_else(|| io::Error::other("Missing application directory"))?;
    let resources = root.join("resources");
    let runtime = resources.join("ruby");
    let ruby_lib = runtime.join("lib/ruby");
    let paths = [
        "site_ruby/3.4.0",
        "site_ruby/3.4.0/x64-mingw-ucrt",
        "site_ruby",
        "vendor_ruby/3.4.0",
        "vendor_ruby/3.4.0/x64-mingw-ucrt",
        "vendor_ruby",
        "3.4.0",
        "3.4.0/x64-mingw-ucrt",
    ];
    let rubylib = env::join_paths(paths.map(|p| ruby_lib.join(p))).map_err(io::Error::other)?;
    let log_path = log_path();
    fs::create_dir_all(log_path.parent().unwrap())?;
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)?;
    if !runtime.join("bin.real/ruby.exe").is_file()
        || !resources.join("boot.rb").is_file()
        || !root.join("scarpe-native.exe").is_file()
    {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "ملفات التطبيق غير مكتملة. أعد تثبيت الجامع باستخدام برنامج التثبيت.",
        ));
    }
    let mut command = Command::new(runtime.join("bin.real/ruby.exe"));
    command
        .arg(resources.join("boot.rb"))
        .args(env::args_os().skip(1))
        .env("RUBYLIB", rubylib)
        .env("ALJAM3_LAUNCHER_PID", process::id().to_string())
        .env("SCARPE_NATIVE_BIN", root.join("scarpe-native.exe"))
        .env("SSL_CERT_FILE", runtime.join("lib/ca-bundle.crt"))
        .env_remove("SSL_CERT_DIR")
        .env_remove("RUBYOPT")
        .env_remove("BUNDLE_GEMFILE")
        .env_remove("BUNDLE_PATH")
        .env_remove("BUNDLE_BIN_PATH")
        .env_remove("BUNDLER_SETUP")
        .env_remove("GEM_HOME")
        .env_remove("GEM_PATH")
        .current_dir(root)
        // A hidden console still supplies a legacy code page to Ruby. Detach
        // completely so Ruby uses its UTF-8 process manifest from startup.
        .creation_flags(0x00000008) // DETACHED_PROCESS
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    Ok(command.status()?.code().unwrap_or(1))
}

fn main() {
    let code = match launch() {
        Ok(0) => return,
        Ok(code) => {
            report_error(&format!(
                "توقف التطبيق برمز {code} (0x{:08X}).",
                code as u32
            ));
            code
        }
        Err(error) => {
            report_error(&error.to_string());
            1
        }
    };
    process::exit(code);
}
