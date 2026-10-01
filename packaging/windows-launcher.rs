#![windows_subsystem = "windows"]

use std::{env, fs::{self, OpenOptions}, io, os::windows::process::CommandExt, process::{self, Command, Stdio}};

fn launch() -> io::Result<i32> {
    let exe = env::current_exe()?;
    let root = exe.parent().ok_or_else(|| io::Error::other("Missing application directory"))?;
    let resources = root.join("resources");
    let runtime = resources.join("ruby");
    let ruby_lib = runtime.join("lib/ruby");
    let paths = ["site_ruby/3.4.0", "site_ruby/3.4.0/x64-mingw-ucrt", "site_ruby", "vendor_ruby/3.4.0", "vendor_ruby/3.4.0/x64-mingw-ucrt", "vendor_ruby", "3.4.0", "3.4.0/x64-mingw-ucrt"];
    let rubylib = env::join_paths(paths.map(|p| ruby_lib.join(p))).map_err(io::Error::other)?;
    let log_dir = env::var_os("ALJAM3_DATA_DIR").map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from(env::var_os("LOCALAPPDATA").unwrap_or_else(|| root.as_os_str().to_owned())).join("Aljam3"));
    fs::create_dir_all(&log_dir)?;
    let log = OpenOptions::new().create(true).append(true).open(log_dir.join("launcher.log"))?;
    let mut command = Command::new(runtime.join("bin.real/ruby.exe"));
    command.arg(resources.join("boot.rb")).args(env::args_os().skip(1))
        .env("RUBYLIB", rubylib)
        .env("SCARPE_NATIVE_BIN", root.join("scarpe-native.exe"))
        .env("SSL_CERT_FILE", runtime.join("lib/ca-bundle.crt"))
        .env_remove("SSL_CERT_DIR").env_remove("RUBYOPT")
        .env_remove("BUNDLE_GEMFILE").env_remove("BUNDLE_PATH").env_remove("BUNDLE_BIN_PATH")
        .env_remove("GEM_HOME").env_remove("GEM_PATH")
        .current_dir(root).creation_flags(0x08000000)
        .stdin(Stdio::null()).stdout(log.try_clone()?).stderr(log);
    Ok(command.status()?.code().unwrap_or(1))
}

fn main() {
    process::exit(match launch() { Ok(code) => code, Err(error) => { eprintln!("Aljam3: {error}"); 1 } });
}
