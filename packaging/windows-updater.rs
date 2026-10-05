#![windows_subsystem = "windows"]

use std::{env, fs, io::{self, Read}, os::windows::process::CommandExt, path::Path, process::{Command, Stdio}};
type Handle = *mut std::ffi::c_void;
#[link(name = "kernel32")]
extern "system" {
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> Handle;
    fn WaitForSingleObject(handle: Handle, timeout: u32) -> u32;
    fn CloseHandle(handle: Handle) -> i32;
}
#[link(name = "bcrypt")]
extern "system" {
    fn BCryptOpenAlgorithmProvider(algorithm: *mut Handle, name: *const u16, provider: *const u16, flags: u32) -> i32;
    fn BCryptCreateHash(algorithm: Handle, hash: *mut Handle, object: *mut u8, object_size: u32, secret: *const u8, secret_size: u32, flags: u32) -> i32;
    fn BCryptHashData(hash: Handle, data: *const u8, size: u32, flags: u32) -> i32;
    fn BCryptFinishHash(hash: Handle, output: *mut u8, size: u32, flags: u32) -> i32;
    fn BCryptDestroyHash(hash: Handle) -> i32;
    fn BCryptCloseAlgorithmProvider(algorithm: Handle, flags: u32) -> i32;
}

fn wait(pid: &str) -> io::Result<()> {
    let pid: u32 = pid.parse().map_err(io::Error::other)?;
    if pid == 0 { return Ok(()); }
    unsafe {
        let handle = OpenProcess(0x00100000, 0, pid); // SYNCHRONIZE
        if handle.is_null() {
            let error = io::Error::last_os_error();
            return if error.raw_os_error() == Some(87) { Ok(()) } else { Err(error) };
        }
        let status = WaitForSingleObject(handle, 120_000);
        CloseHandle(handle);
        if status != 0 { return Err(io::Error::other("Application did not quit; no files changed")); }
    }
    Ok(())
}

fn checksum(path: &Path) -> io::Result<String> {
    let mut file = fs::File::open(path)?;
    unsafe {
        let mut algorithm = std::ptr::null_mut();
        let name: Vec<u16> = "SHA256\0".encode_utf16().collect();
        if BCryptOpenAlgorithmProvider(&mut algorithm, name.as_ptr(), std::ptr::null(), 0) != 0 {
            return Err(io::Error::other("Cannot initialize SHA256"));
        }
        let mut hash = std::ptr::null_mut();
        let result = (|| {
            if BCryptCreateHash(algorithm, &mut hash, std::ptr::null_mut(), 0, std::ptr::null(), 0, 0) != 0 {
                return Err(io::Error::other("Cannot initialize package verification"));
            }
            let mut buffer = [0u8; 65536];
            loop {
                let size = file.read(&mut buffer)?;
                if size == 0 { break; }
                if BCryptHashData(hash, buffer.as_ptr(), size as u32, 0) != 0 { return Err(io::Error::other("Package verification failed")); }
            }
            let mut digest = [0u8; 32];
            if BCryptFinishHash(hash, digest.as_mut_ptr(), 32, 0) != 0 { return Err(io::Error::other("Package verification failed")); }
            Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
        })();
        if !hash.is_null() { BCryptDestroyHash(hash); }
        BCryptCloseAlgorithmProvider(algorithm, 0);
        result
    }
}

fn copy_tree(source: &Path, destination: &Path) -> io::Result<()> {
    fs::create_dir_all(destination)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let target = destination.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_symlink() { return Err(io::Error::other("Unexpected link in installation")); }
        if kind.is_dir() { copy_tree(&entry.path(), &target)?; }
        else { fs::copy(entry.path(), target)?; }
    }
    Ok(())
}

fn install(args: &[String]) -> io::Result<()> {
    wait(&args[5])?;
    wait(&args[6])?;
    let root = Path::new(&args[1]);
    let installer = Path::new(&args[2]);
    if checksum(installer)? != args[3] { return Err(io::Error::other("Package checksum mismatch")); }
    if !root.join("resources/build.json").is_file() { return Err(io::Error::other("Application location is invalid")); }
    let backup = Path::new(&args[7]).parent().unwrap().join("previous-app");
    // Never overwrite an existing recovery copy after a previous interrupted update.
    if backup.exists() { return Err(io::Error::other("A recovery copy already exists")); }
    if let Err(error) = copy_tree(root, &backup) { let _ = fs::remove_dir_all(&backup); return Err(error); }
    let log = Path::new(&args[7]).parent().unwrap().join("installer.log");
    let status = Command::new(installer)
        .args(["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", "/NOCLOSEAPPLICATIONS"])
        .arg(format!("/DIR={}", root.display()))
        .arg(format!("/LOG={}", log.display()))
        .creation_flags(0x08000000).status();
    match status {
        Ok(status) if status.success() => {
            fs::remove_dir_all(backup)?;
            Ok(())
        }
        result => {
            // Inno's failed file replacement must not strand the user without an app.
            fs::remove_dir_all(root)?;
            copy_tree(&backup, root)?;
            fs::remove_dir_all(backup)?;
            Err(io::Error::other(format!("Installer failed; previous app restored: {result:?}")))
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 8 { std::process::exit(2); }
    let result = install(&args);
    if let Err(error) = &result { eprintln!("{error}"); }
    let _ = fs::write(&args[7], if result.is_ok() { "installed" } else { "failed" });
    let launcher = Path::new(&args[1]).join("Aljam3.exe");
    let _ = Command::new(launcher).creation_flags(0x00000008)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
    if result.is_err() { std::process::exit(1); }
}
