{
  description = "HTML2APK: самодостаточное Rust-приложение для сборки HTML-проектов в Android APK одной командой через Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Поддерживаемые платформы (Android SDK build-tools в nixpkgs)
      supportedSystems = [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };

          # Версии Android SDK, поставляемые декларативно через Nix
          androidApiLevel = "35";
          androidBuildToolsVersion = "35.0.0";

          androidComposition = pkgs.androidenv.composeAndroidPackages {
            buildToolsVersions = [ androidBuildToolsVersion ];
            platformVersions = [ androidApiLevel ];
            includeNDK = false;
            includeEmulator = false;
            includeSystemImages = false;
          };

          androidSdk = androidComposition.androidsdk;

          # Все внешние утилиты времени выполнения поставляются исключительно через Nix
          runtimeTools = [
            pkgs.jdk21
            pkgs.resvg
            pkgs.imagemagick
            pkgs.zip
            pkgs.unzip
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.xdg-utils
          ];

          # Исходный код приложения на чистом Rust 2021 (без внешних крейтов = мгновенная
          # воспроизводимая сборка без Cargo.lock / сетевых хешей)
          rustSource = pkgs.writeText "main.rs" ''
// ============================================================================
// HTML2APK — Современный автономный сборщик HTML -> Android APK на Rust
// Нулевые внешние Rust-зависимости; Android SDK, OpenJDK, resvg, ImageMagick
// и архиваторы полностью изолированы и подключены через Nix Flake.
// ============================================================================

use std::collections::{HashMap, VecDeque};
use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const MAX_UPLOAD_BYTES: usize = 160 * 1024 * 1024; // 160 MiB
const MAX_CACHED_BUILDS: usize = 5;

/// Сохранённый результат сборки APK для скачивания браузером
struct BuiltApk {
    filename: String,
    bytes: Vec<u8>,
}

/// Потокобезопасное хранилище последних собранных APK
struct AppState {
    builds: HashMap<String, BuiltApk>,
    order: VecDeque<String>,
    env_cfg: ToolchainEnv,
}

/// Пути к инструментам, переданным из Nix wrapper
#[derive(Clone)]
struct ToolchainEnv {
    build_tools: PathBuf,
    platform_jar: PathBuf,
}

/// Входные параметры конвертации из UI
struct BuildRequest {
    config: HashMap<String, String>,
    files: Vec<(String, Vec<u8>)>,
    icon_ext: String,
    icon_bytes: Vec<u8>,
    keystore_bytes: Vec<u8>,
}

/// Результат выполнения пайплайна сборки
struct BuildOutput {
    filename: String,
    apk_bytes: Vec<u8>,
    log: String,
    elapsed_ms: u128,
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut host = String::from("127.0.0.1");
    let mut port: u16 = 8787;
    let mut open_browser = true;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--help" | "-h" => {
                println!("HTML2APK (Rust + Nix)");
                println!("Usage: html2apk [--host 127.0.0.1] [--port 8787] [--no-open]");
                return;
            }
            "--host" => {
                if i + 1 < args.len() {
                    host = args[i + 1].clone();
                    i += 1;
                }
            }
            "--port" | "-p" => {
                if i + 1 < args.len() {
                    if let Ok(p) = args[i + 1].parse::<u16>() {
                        port = p;
                    }
                    i += 1;
                }
            }
            "--no-open" => {
                open_browser = false;
            }
            _ => {}
        }
        i += 1;
    }

    let build_tools = PathBuf::from(
        env::var("ANDROID_BUILD_TOOLS")
            .expect("ANDROID_BUILD_TOOLS must be set by Nix wrapper"),
    );
    let platform_jar = PathBuf::from(
        env::var("ANDROID_PLATFORM_JAR")
            .expect("ANDROID_PLATFORM_JAR must be set by Nix wrapper"),
    );

    let env_cfg = ToolchainEnv {
        build_tools,
        platform_jar,
    };

    // Пробуем занять указанный порт, иначе берём свободный порт ОС
    let listener = TcpListener::bind(format!("{}:{}", host, port))
        .or_else(|_| TcpListener::bind(format!("{}:0", host)))
        .expect("Failed to bind local HTTP server");

    let actual_addr = listener.local_addr().expect("Failed to get bound address");
    let url = format!("http://{}:{}", host, actual_addr.port());

    println!("\n  HTML2APK  ->  {}", url);
    println!("  Ctrl+C to stop\n");

    if open_browser {
        let open_url = url.clone();
        thread::spawn(move || {
            open_in_default_browser(&open_url);
        });
    }

    let state = Arc::new(Mutex::new(AppState {
        builds: HashMap::new(),
        order: VecDeque::new(),
        env_cfg,
    }));

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state_clone = Arc::clone(&state);
                thread::spawn(move || {
                    if let Err(err) = handle_client(stream, state_clone) {
                        eprintln!("[http] {}", err);
                    }
                });
            }
            Err(err) => eprintln!("[accept] {}", err),
        }
    }
}

/// Открытие локального интерфейса в системном браузере
fn open_in_default_browser(url: &str) {
    #[cfg(target_os = "macos")]
    let _ = Command::new("open")
        .arg(url)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();

    #[cfg(target_os = "linux")]
    let _ = Command::new("xdg-open")
        .arg(url)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

// ============================================================================
// МИНИМАЛИСТИЧНЫЙ МНОГОПОТОЧНЫЙ HTTP/1.1 СЕРВЕР
// ============================================================================

fn handle_client(mut stream: TcpStream, state: Arc<Mutex<AppState>>) -> io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);

    let mut request_line = String::new();
    if reader.read_line(&mut request_line)? == 0 {
        return Ok(());
    }
    let parts: Vec<&str> = request_line.trim().split_whitespace().collect();
    if parts.len() < 2 {
        return write_response(&mut stream, "400 Bad Request", "text/plain", b"Bad Request", &[]);
    }
    let method = parts[0];
    let path = parts[1].split('?').next().unwrap_or("/");

    let mut content_length: usize = 0;
    let mut expect_continue = false;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line)?;
        if line == "\r\n" || line == "\n" || line.is_empty() {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            let key = k.trim().to_ascii_lowercase();
            let val = v.trim();
            if key == "content-length" {
                content_length = val.parse::<usize>().unwrap_or(0);
            } else if key == "expect" && val.to_ascii_lowercase().contains("100-continue") {
                expect_continue = true;
            }
        }
    }

    if expect_continue {
        stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\n")?;
        stream.flush()?;
    }

    if content_length > MAX_UPLOAD_BYTES {
        let err_json = format!(
            "{{\"ok\":false,\"error\":\"Payload exceeds {} MiB limit\"}}",
            MAX_UPLOAD_BYTES / (1024 * 1024)
        );
        return write_response(
            &mut stream,
            "413 Payload Too Large",
            "application/json; charset=utf-8",
            err_json.as_bytes(),
            &[],
        );
    }

    let mut body = vec![0u8; content_length];
    if content_length > 0 {
        reader.read_exact(&mut body)?;
    }

    match (method, path) {
        ("GET", "/") | ("GET", "/index.html") => write_response(
            &mut stream,
            "200 OK",
            "text/html; charset=utf-8",
            INDEX_HTML.as_bytes(),
            &[("Cache-Control", "no-store")],
        ),
        ("GET", "/api/health") => write_response(
            &mut stream,
            "200 OK",
            "application/json; charset=utf-8",
            b"{\"ok\":true}",
            &[],
        ),
        ("POST", "/api/build") => handle_build_request(&mut stream, &body, state),
        ("GET", p) if p.starts_with("/api/download/") => {
            let id = &p["/api/download/".len()..];
            let guard = state.lock().unwrap();
            if let Some(apk) = guard.builds.get(id) {
                let disp = format!("attachment; filename=\"{}\"", sanitize_header_filename(&apk.filename));
                let headers = [
                    ("Content-Disposition", disp.as_str()),
                    ("Cache-Control", "no-store"),
                ];
                write_response(
                    &mut stream,
                    "200 OK",
                    "application/vnd.android.package-archive",
                    &apk.bytes,
                    &headers,
                )
            } else {
                write_response(&mut stream, "404 Not Found", "text/plain", b"Not Found", &[])
            }
        }
        _ => write_response(&mut stream, "404 Not Found", "text/plain", b"Not Found", &[]),
    }
}

fn write_response(
    stream: &mut TcpStream,
    status: &str,
    content_type: &str,
    body: &[u8],
    extra_headers: &[(&str, &str)],
) -> io::Result<()> {
    let mut head = format!(
        "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n",
        status,
        content_type,
        body.len()
    );
    for (k, v) in extra_headers {
        head.push_str(&format!("{}: {}\r\n", k, v));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes())?;
    stream.write_all(body)?;
    stream.flush()
}

fn handle_build_request(
    stream: &mut TcpStream,
    body: &[u8],
    state: Arc<Mutex<AppState>>,
) -> io::Result<()> {
    let req = match decode_binary_request(body) {
        Ok(r) => r,
        Err(msg) => {
            let json = format!("{{\"ok\":false,\"error\":\"{}\"}}", json_escape(&msg));
            return write_response(
                stream,
                "400 Bad Request",
                "application/json; charset=utf-8",
                json.as_bytes(),
                &[],
            );
        }
    };

    let env_cfg = {
        let guard = state.lock().unwrap();
        guard.env_cfg.clone()
    };

    match run_apk_build(&env_cfg, &req) {
        Ok(out) => {
            let id = format!(
                "{:x}",
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            );
            let size = out.apk_bytes.len();
            let filename = out.filename.clone();

            {
                let mut guard = state.lock().unwrap();
                guard.builds.insert(
                    id.clone(),
                    BuiltApk {
                        filename: out.filename,
                        bytes: out.apk_bytes,
                    },
                );
                guard.order.push_back(id.clone());
                while guard.order.len() > MAX_CACHED_BUILDS {
                    if let Some(old_id) = guard.order.pop_front() {
                        guard.builds.remove(&old_id);
                    }
                }
            }

            let json = format!(
                "{{\"ok\":true,\"id\":\"{}\",\"filename\":\"{}\",\"size\":{},\"elapsed_ms\":{},\"log\":\"{}\"}}",
                json_escape(&id),
                json_escape(&filename),
                size,
                out.elapsed_ms,
                json_escape(&out.log)
            );
            write_response(
                stream,
                "200 OK",
                "application/json; charset=utf-8",
                json.as_bytes(),
                &[],
            )
        }
        Err((err_msg, log)) => {
            let json = format!(
                "{{\"ok\":false,\"error\":\"{}\",\"log\":\"{}\"}}",
                json_escape(&err_msg),
                json_escape(&log)
            );
            write_response(
                stream,
                "422 Unprocessable Entity",
                "application/json; charset=utf-8",
                json.as_bytes(),
                &[],
            )
        }
    }
}

// ============================================================================
// ДЕКОДЕР БИНАРНОГО ПРОТОКОЛА ПЕРЕДАЧИ (0 потерь, UTF-8 + сырые байты файлов)
// Формат:
//   [u32 cfg_count] ( [u32 klen][k] [u32 vlen][v] ) *
//   [u32 file_count] ( [u32 plen][path] [u32 dlen][bytes] ) *
//   [u32 icon_ext_len][ext] [u32 icon_len][icon_bytes]
//   [u32 ks_len][ks_bytes]
// ============================================================================

struct BinCursor<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> BinCursor<'a> {
    fn read_u32(&mut self) -> Result<usize, String> {
        if self.pos + 4 > self.buf.len() {
            return Err("Unexpected EOF reading u32".into());
        }
        let val = u32::from_be_bytes([
            self.buf[self.pos],
            self.buf[self.pos + 1],
            self.buf[self.pos + 2],
            self.buf[self.pos + 3],
        ]) as usize;
        self.pos += 4;
        Ok(val)
    }

    fn read_bytes(&mut self) -> Result<Vec<u8>, String> {
        let len = self.read_u32()?;
        if self.pos + len > self.buf.len() {
            return Err("Unexpected EOF reading byte slice".into());
        }
        let out = self.buf[self.pos..self.pos + len].to_vec();
        self.pos += len;
        Ok(out)
    }

    fn read_string(&mut self) -> Result<String, String> {
        let bytes = self.read_bytes()?;
        String::from_utf8(bytes).map_err(|_| "Invalid UTF-8 string".into())
    }
}

fn decode_binary_request(data: &[u8]) -> Result<BuildRequest, String> {
    let mut cur = BinCursor { buf: data, pos: 0 };
    let cfg_count = cur.read_u32()?;
    if cfg_count > 128 {
        return Err("Too many config parameters".into());
    }
    let mut config = HashMap::new();
    for _ in 0..cfg_count {
        let k = cur.read_string()?;
        let v = cur.read_string()?;
        config.insert(k, v);
    }

    let file_count = cur.read_u32()?;
    if file_count == 0 {
        return Err("No HTML or ZIP files uploaded".into());
    }
    if file_count > 4096 {
        return Err("Too many files in project".into());
    }
    let mut files = Vec::with_capacity(file_count);
    for _ in 0..file_count {
        let path = cur.read_string()?;
        let bytes = cur.read_bytes()?;
        files.push((path, bytes));
    }

    let icon_ext = cur.read_string()?.to_ascii_lowercase();
    let icon_bytes = cur.read_bytes()?;
    let keystore_bytes = cur.read_bytes()?;

    Ok(BuildRequest {
        config,
        files,
        icon_ext,
        icon_bytes,
        keystore_bytes,
    })
}

// ============================================================================
// ПАЙПЛАЙН СБОРКИ ANDROID APK (resvg + ImageMagick + aapt2 + javac + d8 + zipalign + apksigner)
// ============================================================================

struct TempDirGuard(PathBuf);
impl Drop for TempDirGuard {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn run_apk_build(
    env_cfg: &ToolchainEnv,
    req: &BuildRequest,
) -> Result<BuildOutput, (String, String)> {
    let started = Instant::now();
    let mut log = String::new();

    let cfg = |key: &str, default: &str| -> String {
        req.config
            .get(key)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| default.to_string())
    };
    let cfg_bool = |key: &str, default: bool| -> bool {
        req.config
            .get(key)
            .map(|v| v == "true" || v == "1")
            .unwrap_or(default)
    };

    let app_name = cfg("app_name", "WebApp");
    let package_id = cfg("package_id", "com.html2apk.app").to_ascii_lowercase();
    let version_name = cfg("version_name", "1.0.0");
    let version_code: u32 = cfg("version_code", "1").parse().unwrap_or(1).max(1);
    let min_sdk: u32 = cfg("min_sdk", "24").parse().unwrap_or(24).clamp(21, 35);
    let target_sdk: u32 = cfg("target_sdk", "35").parse().unwrap_or(35).clamp(min_sdk, 35);
    let entry_file = sanitize_rel_path(&cfg("entry_file", "index.html"))
        .unwrap_or_else(|| PathBuf::from("index.html"))
        .to_string_lossy()
        .replace('\\', "/");

    let orientation = match cfg("orientation", "unspecified").as_str() {
        "portrait" => "portrait",
        "landscape" => "landscape",
        "sensor" => "sensor",
        _ => "unspecified",
    };

    let icon_bg = normalize_hex_color(&cfg("icon_bg", "#111827"), "#111827");
    let icon_padding_pct: u32 = cfg("icon_padding", "18").parse().unwrap_or(18).clamp(0, 40);
    let status_bar_color = normalize_hex_color(&cfg("status_bar_color", "#0f1115"), "#0f1115");
    let nav_bar_color = normalize_hex_color(&cfg("nav_bar_color", "#0f1115"), "#0f1115");
    let splash_bg = normalize_hex_color(&cfg("splash_bg", "#0f1115"), "#0f1115");
    let light_status_bar = cfg_bool("light_status_bar", false);
    let fullscreen = cfg_bool("fullscreen", false);
    let keep_screen_on = cfg_bool("keep_screen_on", false);

    let enable_js = cfg_bool("enable_js", true);
    let enable_dom_storage = cfg_bool("enable_dom_storage", true);
    let enable_zoom = cfg_bool("enable_zoom", false);
    let open_external = cfg_bool("open_external", true);
    let allow_cleartext = cfg_bool("allow_cleartext", true);
    let allow_file_upload = cfg_bool("allow_file_upload", true);
    let user_agent = cfg("user_agent", "");

    let perm_internet = cfg_bool("perm_internet", true);
    let perm_camera = cfg_bool("perm_camera", false);
    let perm_audio = cfg_bool("perm_audio", false);
    let perm_location = cfg_bool("perm_location", false);
    let perm_vibrate = cfg_bool("perm_vibrate", false);

    if !is_valid_package_id(&package_id) {
        return Err((
            format!("Invalid Android package ID: {}", package_id),
            log,
        ));
    }

    // Создаём изолированную временную директорию сборки
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let work_dir = env::temp_dir().join(format!("html2apk_{}_{}", std::process::id(), nonce));
    fs::create_dir_all(&work_dir).map_err(|e| (e.to_string(), log.clone()))?;
    let _guard = TempDirGuard(work_dir.clone());

    let res_dir = work_dir.join("res");
    let assets_www = work_dir.join("assets").join("www");
    let gen_dir = work_dir.join("gen");
    let src_dir = work_dir.join("src");
    let classes_dir = work_dir.join("classes");
    let dex_dir = work_dir.join("dex");

    for d in [&res_dir, &assets_www, &gen_dir, &src_dir, &classes_dir, &dex_dir] {
        fs::create_dir_all(d).map_err(|e| (e.to_string(), log.clone()))?;
    }

    // ------------------------------------------------------------------------
    // Шаг 1: Подготовка веб-ассетов (HTML / набор файлов / ZIP-архив)
    // ------------------------------------------------------------------------
    log.push_str("[1/7] Staging web assets...\n");
    stage_web_assets(&req.files, &work_dir, &assets_www, &mut log)
        .map_err(|e| (e, log.clone()))?;

    // Если entry_file отсутствует, но есть ровно один .html файл — используем его
    let resolved_entry = resolve_entry_file(&assets_www, &entry_file);
    log.push_str(&format!("      entry: assets/www/{}\n", resolved_entry));

    // ------------------------------------------------------------------------
    // Шаг 2: Генерация адаптивных и классических иконок (SVG через resvg / PNG через ImageMagick)
    // ------------------------------------------------------------------------
    log.push_str("[2/7] Generating icons (mipmap + adaptive)...\n");
    generate_android_icons(
        &work_dir,
        &res_dir,
        &app_name,
        &req.icon_ext,
        &req.icon_bytes,
        &icon_bg,
        icon_padding_pct,
        &mut log,
    )
    .map_err(|e| (e, log.clone()))?;

    // ------------------------------------------------------------------------
    // Шаг 3: Генерация ресурсов XML, AndroidManifest.xml и MainActivity.java
    // ------------------------------------------------------------------------
    log.push_str("[3/7] Generating AndroidManifest.xml & WebView Activity...\n");

    let values_dir = res_dir.join("values");
    fs::create_dir_all(&values_dir).map_err(|e| (e.to_string(), log.clone()))?;

    let strings_xml = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<resources>\n    <string name=\"app_name\">{}</string>\n</resources>\n",
        android_string_escape(&app_name)
    );
    fs::write(values_dir.join("strings.xml"), strings_xml)
        .map_err(|e| (e.to_string(), log.clone()))?;

    let colors_xml = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<resources>\n    <color name=\"ic_launcher_background\">{}</color>\n    <color name=\"splash_bg\">{}</color>\n</resources>\n",
        icon_bg, splash_bg
    );
    fs::write(values_dir.join("colors.xml"), colors_xml)
        .map_err(|e| (e.to_string(), log.clone()))?;

    let styles_xml = concat!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n",
        "<resources>\n",
        "    <style name=\"AppTheme\" parent=\"@android:style/Theme.DeviceDefault.NoActionBar\">\n",
        "        <item name=\"android:windowBackground\">@color/splash_bg</item>\n",
        "    </style>\n",
        "</resources>\n"
    );
    fs::write(values_dir.join("styles.xml"), styles_xml)
        .map_err(|e| (e.to_string(), log.clone()))?;

    let mut permissions_xml = String::new();
    if perm_internet {
        permissions_xml.push_str("    <uses-permission android:name=\"android.permission.INTERNET\" />\n");
        permissions_xml.push_str("    <uses-permission android:name=\"android.permission.ACCESS_NETWORK_STATE\" />\n");
    }
    if perm_camera {
        permissions_xml.push_str("    <uses-permission android:name=\"android.permission.CAMERA\" />\n");
    }
    if perm_audio {
        permissions_xml.push_str("    <uses-permission android:name=\"android.permission.RECORD_AUDIO\" />\n");
        permissions_xml.push_str("    <uses-permission android:name=\"android.permission.MODIFY_AUDIO_SETTINGS\" />\n");
    }
    if perm_location {
        permissions_xml.push_str("    <uses-permission android:name=\"android.permission.ACCESS_FINE_LOCATION\" />\n");
        permissions_xml.push_str("    <uses-permission android:name=\"android.permission.ACCESS_COARSE_LOCATION\" />\n");
    }
    if perm_vibrate {
        permissions_xml.push_str("    <uses-permission android:name=\"android.permission.VIBRATE\" />\n");
    }

    let manifest_xml = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\
<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"\n\
    package=\"{pkg}\"\n\
    android:versionCode=\"{vcode}\"\n\
    android:versionName=\"{vname}\">\n\
    <uses-sdk android:minSdkVersion=\"{min_sdk}\" android:targetSdkVersion=\"{target_sdk}\" />\n\
{perms}\
    <application\n\
        android:label=\"@string/app_name\"\n\
        android:icon=\"@mipmap/ic_launcher\"\n\
        android:roundIcon=\"@mipmap/ic_launcher\"\n\
        android:theme=\"@style/AppTheme\"\n\
        android:hardwareAccelerated=\"true\"\n\
        android:usesCleartextTraffic=\"{cleartext}\">\n\
        <activity\n\
            android:name=\".MainActivity\"\n\
            android:exported=\"true\"\n\
            android:screenOrientation=\"{orient}\"\n\
            android:configChanges=\"orientation|screenSize|keyboardHidden|smallestScreenSize|screenLayout\">\n\
            <intent-filter>\n\
                <action android:name=\"android.intent.action.MAIN\" />\n\
                <category android:name=\"android.intent.category.LAUNCHER\" />\n\
            </intent-filter>\n\
        </activity>\n\
    </application>\n\
</manifest>\n",
        pkg = package_id,
        vcode = version_code,
        vname = xml_escape(&version_name),
        min_sdk = min_sdk,
        target_sdk = target_sdk,
        perms = permissions_xml,
        cleartext = allow_cleartext,
        orient = orientation
    );

    let manifest_path = work_dir.join("AndroidManifest.xml");
    fs::write(&manifest_path, manifest_xml).map_err(|e| (e.to_string(), log.clone()))?;

    let java_pkg_dir = src_dir.join(package_id.replace('.', "/"));
    fs::create_dir_all(&java_pkg_dir).map_err(|e| (e.to_string(), log.clone()))?;

    let main_activity_java = generate_main_activity_java(
        &package_id,
        &resolved_entry,
        &status_bar_color,
        &nav_bar_color,
        &splash_bg,
        light_status_bar,
        fullscreen,
        keep_screen_on,
        enable_js,
        enable_dom_storage,
        enable_zoom,
        open_external,
        allow_file_upload,
        &user_agent,
        perm_camera,
        perm_audio,
        perm_location,
    );
    let main_activity_path = java_pkg_dir.join("MainActivity.java");
    fs::write(&main_activity_path, main_activity_java)
        .map_err(|e| (e.to_string(), log.clone()))?;

    // ------------------------------------------------------------------------
    // Шаг 4: aapt2 compile + aapt2 link
    // ------------------------------------------------------------------------
    log.push_str("[4/7] Compiling & linking resources (aapt2)...\n");
    let aapt2 = env_cfg.build_tools.join("aapt2");
    let compiled_res = work_dir.join("compiled_res.zip");
    let unsigned_apk = work_dir.join("unsigned.apk");

    run_cmd(
        &aapt2,
        &[
            "compile",
            "--dir",
            res_dir.to_str().unwrap(),
            "-o",
            compiled_res.to_str().unwrap(),
        ],
        &work_dir,
        &mut log,
    )
    .map_err(|e| (e, log.clone()))?;

    run_cmd(
        &aapt2,
        &[
            "link",
            "-o",
            unsigned_apk.to_str().unwrap(),
            "-I",
            env_cfg.platform_jar.to_str().unwrap(),
            "--manifest",
            manifest_path.to_str().unwrap(),
            "-A",
            work_dir.join("assets").to_str().unwrap(),
            "--java",
            gen_dir.to_str().unwrap(),
            "--min-sdk-version",
            &min_sdk.to_string(),
            "--target-sdk-version",
            &target_sdk.to_string(),
            "--version-code",
            &version_code.to_string(),
            "--version-name",
            &version_name,
            compiled_res.to_str().unwrap(),
        ],
        &work_dir,
        &mut log,
    )
    .map_err(|e| (e, log.clone()))?;

    // ------------------------------------------------------------------------
    // Шаг 5: javac -> d8 (DEX байткод)
    // ------------------------------------------------------------------------
    log.push_str("[5/7] Compiling Java & DEX bytecode (javac + d8)...\n");
    let mut java_files = Vec::new();
    collect_files_with_ext(&gen_dir, "java", &mut java_files);
    java_files.push(main_activity_path.clone());

    let mut javac_args: Vec<String> = vec![
        "-source".into(),
        "11".into(),
        "-target".into(),
        "11".into(),
        "-Xlint:none".into(),
        "-encoding".into(),
        "UTF-8".into(),
        "-classpath".into(),
        env_cfg.platform_jar.to_string_lossy().into_owned(),
        "-d".into(),
        classes_dir.to_string_lossy().into_owned(),
    ];
    for jf in &java_files {
        javac_args.push(jf.to_string_lossy().into_owned());
    }
    let javac_refs: Vec<&str> = javac_args.iter().map(|s| s.as_str()).collect();
    run_cmd(Path::new("javac"), &javac_refs, &work_dir, &mut log)
        .map_err(|e| (e, log.clone()))?;

    let mut class_files = Vec::new();
    collect_files_with_ext(&classes_dir, "class", &mut class_files);
    if class_files.is_empty() {
        return Err(("No .class files produced by javac".into(), log));
    }

    let d8 = env_cfg.build_tools.join("d8");
    let mut d8_args: Vec<String> = vec![
        "--release".into(),
        "--min-api".into(),
        min_sdk.to_string(),
        "--lib".into(),
        env_cfg.platform_jar.to_string_lossy().into_owned(),
        "--output".into(),
        dex_dir.to_string_lossy().into_owned(),
    ];
    for cf in &class_files {
        d8_args.push(cf.to_string_lossy().into_owned());
    }
    let d8_refs: Vec<&str> = d8_args.iter().map(|s| s.as_str()).collect();
    run_cmd(&d8, &d8_refs, &work_dir, &mut log).map_err(|e| (e, log.clone()))?;

    // ------------------------------------------------------------------------
    // Шаг 6: Упаковка classes.dex и выравнивание zipalign
    // ------------------------------------------------------------------------
    log.push_str("[6/7] Packaging DEX & aligning APK (zip + zipalign)...\n");
    let packaged_apk = work_dir.join("packaged.apk");
    fs::copy(&unsigned_apk, &packaged_apk).map_err(|e| (e.to_string(), log.clone()))?;

    let mut dex_files = Vec::new();
    collect_files_with_ext(&dex_dir, "dex", &mut dex_files);
    if dex_files.is_empty() {
        return Err(("d8 did not produce classes.dex".into(), log));
    }
    let mut zip_args: Vec<String> = vec![
        "-j".into(),
        "-u".into(),
        packaged_apk.to_string_lossy().into_owned(),
    ];
    for df in &dex_files {
        zip_args.push(df.to_string_lossy().into_owned());
    }
    let zip_refs: Vec<&str> = zip_args.iter().map(|s| s.as_str()).collect();
    run_cmd(Path::new("zip"), &zip_refs, &work_dir, &mut log)
        .map_err(|e| (e, log.clone()))?;

    let aligned_apk = work_dir.join("aligned.apk");
    let zipalign = env_cfg.build_tools.join("zipalign");
    run_cmd(
        &zipalign,
        &[
            "-f",
            "-p",
            "4",
            packaged_apk.to_str().unwrap(),
            aligned_apk.to_str().unwrap(),
        ],
        &work_dir,
        &mut log,
    )
    .map_err(|e| (e, log.clone()))?;

    // ------------------------------------------------------------------------
    // Шаг 7: Подпись APK (apksigner v2/v3) и верификация
    // ------------------------------------------------------------------------
    log.push_str("[7/7] Signing & verifying APK (apksigner)...\n");
    let ks_path = work_dir.join("signing.keystore");
    let (ks_alias, ks_store_pass, ks_key_pass) = if !req.keystore_bytes.is_empty() {
        fs::write(&ks_path, &req.keystore_bytes).map_err(|e| (e.to_string(), log.clone()))?;
        (
            cfg("ks_alias", "appkey"),
            cfg("ks_store_pass", "android"),
            cfg("ks_key_pass", &cfg("ks_store_pass", "android")),
        )
    } else {
        let alias = String::from("html2apk");
        let pass = String::from("html2apk_auto_key");
        let dname = format!("CN={}, O=HTML2APK", sanitize_dname(&app_name));
        run_cmd(
            Path::new("keytool"),
            &[
                "-genkeypair",
                "-keystore",
                ks_path.to_str().unwrap(),
                "-storetype",
                "PKCS12",
                "-alias",
                &alias,
                "-keyalg",
                "RSA",
                "-keysize",
                "2048",
                "-validity",
                "10000",
                "-storepass",
                &pass,
                "-keypass",
                &pass,
                "-dname",
                &dname,
            ],
            &work_dir,
            &mut log,
        )
        .map_err(|e| (e, log.clone()))?;
        (alias, pass.clone(), pass)
    };

    let final_apk = work_dir.join("final.apk");
    let apksigner = env_cfg.build_tools.join("apksigner");
    let ks_pass_arg = format!("pass:{}", ks_store_pass);
    let key_pass_arg = format!("pass:{}", ks_key_pass);

    run_cmd(
        &apksigner,
        &[
            "sign",
            "--ks",
            ks_path.to_str().unwrap(),
            "--ks-key-alias",
            &ks_alias,
            "--ks-pass",
            &ks_pass_arg,
            "--key-pass",
            &key_pass_arg,
            "--out",
            final_apk.to_str().unwrap(),
            aligned_apk.to_str().unwrap(),
        ],
        &work_dir,
        &mut log,
    )
    .map_err(|e| (e, log.clone()))?;

    run_cmd(
        &apksigner,
        &["verify", final_apk.to_str().unwrap()],
        &work_dir,
        &mut log,
    )
    .map_err(|e| (e, log.clone()))?;

    let apk_bytes = fs::read(&final_apk).map_err(|e| (e.to_string(), log.clone()))?;
    let elapsed_ms = started.elapsed().as_millis();
    log.push_str(&format!(
        "Done in {} ms ({} bytes)\n",
        elapsed_ms,
        apk_bytes.len()
    ));

    let safe_slug: String = app_name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '_' })
        .collect::<String>()
        .trim_matches('_')
        .to_string();
    let base = if safe_slug.is_empty() {
        package_id.replace('.', "_")
    } else {
        safe_slug
    };
    let filename = format!("{}-v{}.apk", base, sanitize_filename_token(&version_name));

    Ok(BuildOutput {
        filename,
        apk_bytes,
        log,
        elapsed_ms,
    })
}

/// Копирование HTML-файлов или распаковка ZIP-архива в assets/www
fn stage_web_assets(
    files: &[(String, Vec<u8>)],
    work_dir: &Path,
    assets_www: &Path,
    log: &mut String,
) -> Result<(), String> {
    // Если загружен один ZIP-архив, распаковываем его целиком
    if files.len() == 1 && files[0].0.to_ascii_lowercase().ends_with(".zip") {
        let zip_path = work_dir.join("upload.zip");
        let raw_dir = work_dir.join("zip_extracted");
        fs::create_dir_all(&raw_dir).map_err(|e| e.to_string())?;
        fs::write(&zip_path, &files[0].1).map_err(|e| e.to_string())?;
        run_cmd(
            Path::new("unzip"),
            &["-q", "-o", zip_path.to_str().unwrap(), "-d", raw_dir.to_str().unwrap()],
            work_dir,
            log,
        )?;

        // Если внутри ZIP один корневой каталог (кроме __MACOSX), поднимаем его содержимое
        let mut top_entries: Vec<PathBuf> = fs::read_dir(&raw_dir)
            .map_err(|e| e.to_string())?
            .filter_map(|e| e.ok().map(|x| x.path()))
            .filter(|p| p.file_name().and_then(|n| n.to_str()) != Some("__MACOSX"))
            .collect();

        let source_root = if top_entries.len() == 1 && top_entries[0].is_dir() {
            top_entries.remove(0)
        } else {
            raw_dir
        };

        copy_dir_recursive(&source_root, assets_www).map_err(|e| e.to_string())?;
        return Ok(());
    }

    // Если загружен ровно один HTML-файл с любым именем -> также доступен по своему имени и index.html
    if files.len() == 1 && is_html_name(&files[0].0) {
        let target = assets_www.join("index.html");
        fs::write(&target, &files[0].1).map_err(|e| e.to_string())?;
        if let Some(rel) = sanitize_rel_path(&files[0].0) {
            if rel != Path::new("index.html") {
                let alt = assets_www.join(rel);
                if let Some(parent) = alt.parent() {
                    let _ = fs::create_dir_all(parent);
                }
                let _ = fs::write(alt, &files[0].1);
            }
        }
        return Ok(());
    }

    // Набор файлов (сохраняя относительную структуру каталогов)
    for (raw_path, bytes) in files {
        let rel = match sanitize_rel_path(raw_path) {
            Some(r) => r,
            None => continue,
        };
        let dest = assets_www.join(rel);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        fs::write(&dest, bytes).map_err(|e| e.to_string())?;
    }

    Ok(())
}

fn resolve_entry_file(assets_www: &Path, requested: &str) -> String {
    if assets_www.join(requested).is_file() {
        return requested.to_string();
    }
    if assets_www.join("index.html").is_file() {
        return "index.html".to_string();
    }
    // Ищем первый доступный .html файл в корне
    if let Ok(rd) = fs::read_dir(assets_www) {
        for entry in rd.flatten() {
            let p = entry.path();
            if p.is_file() {
                if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                    if is_html_name(name) {
                        return name.to_string();
                    }
                }
            }
        }
    }
    requested.to_string()
}

/// Генерация иконок всех плотностей (mdpi..xxxhdpi + адаптивные Android 8+ иконки)
/// Поддержка SVG (через resvg) и PNG (через ImageMagick)
fn generate_android_icons(
    work_dir: &Path,
    res_dir: &Path,
    app_name: &str,
    icon_ext: &str,
    icon_bytes: &[u8],
    icon_bg: &str,
    padding_pct: u32,
    log: &mut String,
) -> Result<(), String> {
    let base_png = work_dir.join("icon_base_1024.png");

    if icon_bytes.is_empty() {
        // Автогенерация аккуратной векторной иконки-монограммы
        let letter = app_name
            .chars()
            .find(|c| c.is_alphanumeric())
            .unwrap_or('A')
            .to_uppercase()
            .to_string();
        let default_svg = format!(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 512 512\">\
<rect width=\"512\" height=\"512\" rx=\"112\" fill=\"{bg}\"/>\
<text x=\"256\" y=\"330\" text-anchor=\"middle\" font-family=\"sans-serif\" font-size=\"260\" font-weight=\"700\" fill=\"#ffffff\">{ch}</text>\
</svg>",
            bg = icon_bg,
            ch = xml_escape(&letter)
        );
        let svg_path = work_dir.join("default_icon.svg");
        fs::write(&svg_path, default_svg).map_err(|e| e.to_string())?;
        rasterize_svg(&svg_path, &base_png, work_dir, log)?;
    } else if icon_ext == "svg" || is_likely_svg(icon_bytes) {
        let svg_path = work_dir.join("uploaded_icon.svg");
        fs::write(&svg_path, icon_bytes).map_err(|e| e.to_string())?;
        rasterize_svg(&svg_path, &base_png, work_dir, log)?;
    } else {
        fs::write(&base_png, icon_bytes).map_err(|e| e.to_string())?;
    }

    // Legacy квадратные mipmap-иконки
    let densities: [(&str, u32); 5] = [
        ("mipmap-mdpi", 48),
        ("mipmap-hdpi", 72),
        ("mipmap-xhdpi", 96),
        ("mipmap-xxhdpi", 144),
        ("mipmap-xxxhdpi", 192),
    ];

    for (folder, size) in densities {
        let dir = res_dir.join(folder);
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let out_png = dir.join("ic_launcher.png");

        let inner = ((size as f32) * (1.0 - (padding_pct as f32) / 100.0)).round().max(16.0) as u32;
        let inner_geom = format!("{}x{}", inner, inner);
        let extent_geom = format!("{}x{}", size, size);

        run_magick(
            &[
                base_png.to_str().unwrap(),
                "-resize",
                &inner_geom,
                "-background",
                icon_bg,
                "-gravity",
                "center",
                "-extent",
                &extent_geom,
                out_png.to_str().unwrap(),
            ],
            work_dir,
            log,
        )?;
    }

    // Adaptive Icon Foreground (432x432 px, безопасная центральная зона 66%)
    let drawable_dir = res_dir.join("drawable-nodpi");
    fs::create_dir_all(&drawable_dir).map_err(|e| e.to_string())?;
    let fg_png = drawable_dir.join("ic_launcher_foreground.png");

    // 288 px = 66.7% от 432 px; дополнительно учитываем пользовательский отступ
    let fg_inner = (288.0 * (1.0 - (padding_pct as f32) / 140.0)).round().max(140.0) as u32;
    let fg_geom = format!("{}x{}", fg_inner, fg_inner);

    run_magick(
        &[
            base_png.to_str().unwrap(),
            "-resize",
            &fg_geom,
            "-background",
            "none",
            "-gravity",
            "center",
            "-extent",
            "432x432",
            fg_png.to_str().unwrap(),
        ],
        work_dir,
        log,
    )?;

    // Adaptive Icon XML для Android 8.0+ (API 26+)
    let anydpi_dir = res_dir.join("mipmap-anydpi-v26");
    fs::create_dir_all(&anydpi_dir).map_err(|e| e.to_string())?;
    let adaptive_xml = concat!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n",
        "<adaptive-icon xmlns:android=\"http://schemas.android.com/apk/res/android\">\n",
        "    <background android:drawable=\"@color/ic_launcher_background\" />\n",
        "    <foreground android:drawable=\"@drawable/ic_launcher_foreground\" />\n",
        "</adaptive-icon>\n"
    );
    fs::write(anydpi_dir.join("ic_launcher.xml"), adaptive_xml)
        .map_err(|e| e.to_string())?;

    Ok(())
}

/// Рендер SVG в высокочёткий PNG через современный Rust-рендерер resvg (с запасным вариантом ImageMagick)
fn rasterize_svg(svg_path: &Path, out_png: &Path, work_dir: &Path, log: &mut String) -> Result<(), String> {
    let resvg_attempt = run_cmd(
        Path::new("resvg"),
        &[
            "--width",
            "1024",
            svg_path.to_str().unwrap(),
            out_png.to_str().unwrap(),
        ],
        work_dir,
        log,
    );
    if resvg_attempt.is_ok() && out_png.is_file() {
        return Ok(());
    }
    log.push_str("      resvg fallback -> ImageMagick\n");
    run_magick(
        &[
            "-background",
            "none",
            "-density",
            "384",
            svg_path.to_str().unwrap(),
            "-resize",
            "1024x1024",
            out_png.to_str().unwrap(),
        ],
        work_dir,
        log,
    )
}

fn run_magick(args: &[&str], cwd: &Path, log: &mut String) -> Result<(), String> {
    if run_cmd(Path::new("magick"), args, cwd, log).is_ok() {
        return Ok(());
    }
    run_cmd(Path::new("convert"), args, cwd, log)
}

/// Генерация Android MainActivity.java с полноценной поддержкой WebView
#[allow(clippy::too_many_arguments)]
fn generate_main_activity_java(
    package_id: &str,
    entry_file: &str,
    status_bar_color: &str,
    nav_bar_color: &str,
    splash_bg: &str,
    light_status_bar: bool,
    fullscreen: bool,
    keep_screen_on: bool,
    enable_js: bool,
    enable_dom_storage: bool,
    enable_zoom: bool,
    open_external: bool,
    allow_file_upload: bool,
    user_agent: &str,
    perm_camera: bool,
    perm_audio: bool,
    perm_location: bool,
) -> String {
    let mut runtime_perms = Vec::new();
    if perm_camera {
        runtime_perms.push("\"android.permission.CAMERA\"");
    }
    if perm_audio {
        runtime_perms.push("\"android.permission.RECORD_AUDIO\"");
    }
    if perm_location {
        runtime_perms.push("\"android.permission.ACCESS_FINE_LOCATION\"");
    }
    let perms_array = runtime_perms.join(", ");

    format!(
        r#"package {pkg};

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.GeolocationPermissions;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {{
    private static final int FILE_CHOOSER_REQ = 1001;
    private static final int PERMISSION_REQ = 1002;
    private WebView webView;
    private ValueCallback<Uri[]> filePathCallback;

    @Override
    protected void onCreate(Bundle savedInstanceState) {{
        super.onCreate(savedInstanceState);

        Window window = getWindow();
        if ({keep_screen_on}) {{
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        }}

        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
        window.setStatusBarColor(Color.parseColor("{status_bar_color}"));
        window.setNavigationBarColor(Color.parseColor("{nav_bar_color}"));

        int sysFlags = 0;
        if ({light_status_bar} && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {{
            sysFlags |= View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
        }}
        if ({fullscreen}) {{
            sysFlags |= View.SYSTEM_UI_FLAG_FULLSCREEN
                      | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                      | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                      | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                      | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                      | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION;
        }}
        if (sysFlags != 0) {{
            window.getDecorView().setSystemUiVisibility(sysFlags);
        }}

        String[] reqPerms = new String[] {{ {perms_array} }};
        if (reqPerms.length > 0 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {{
            requestPermissions(reqPerms, PERMISSION_REQ);
        }}

        webView = new WebView(this);
        webView.setBackgroundColor(Color.parseColor("{splash_bg}"));
        setContentView(webView);

        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled({enable_js});
        s.setDomStorageEnabled({enable_dom_storage});
        s.setDatabaseEnabled({enable_dom_storage});
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(true);
        s.setAllowFileAccessFromFileURLs(true);
        s.setAllowUniversalAccessFromFileURLs(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setSupportZoom({enable_zoom});
        s.setBuiltInZoomControls({enable_zoom});
        s.setDisplayZoomControls(false);

        String customUa = "{user_agent}";
        if (!customUa.isEmpty()) {{
            s.setUserAgentString(customUa);
        }}

        webView.setWebViewClient(new WebViewClient() {{
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {{
                Uri uri = request.getUrl();
                String scheme = uri.getScheme();
                if (scheme == null || scheme.equals("file") || scheme.equals("data") || scheme.equals("blob") || scheme.equals("about")) {{
                    return false;
                }}
                if ({open_external} && (scheme.equals("http") || scheme.equals("https") || scheme.equals("mailto") || scheme.equals("tel"))) {{
                    try {{
                        startActivity(new Intent(Intent.ACTION_VIEW, uri));
                        return true;
                    }} catch (Exception ignored) {{
                        return false;
                    }}
                }}
                return false;
            }}
        }});

        webView.setWebChromeClient(new WebChromeClient() {{
            @Override
            public void onPermissionRequest(final PermissionRequest request) {{
                runOnUiThread(new Runnable() {{
                    @Override
                    public void run() {{
                        request.grant(request.getResources());
                    }}
                }});
            }}

            @Override
            public void onGeolocationPermissionsShowPrompt(String origin, GeolocationPermissions.Callback callback) {{
                callback.invoke(origin, {perm_location}, false);
            }}

            @Override
            public boolean onShowFileChooser(WebView vw, ValueCallback<Uri[]> cb, FileChooserParams params) {{
                if (!{allow_file_upload}) {{
                    return false;
                }}
                if (filePathCallback != null) {{
                    filePathCallback.onReceiveValue(null);
                }}
                filePathCallback = cb;
                try {{
                    Intent intent = params.createIntent();
                    startActivityForResult(intent, FILE_CHOOSER_REQ);
                    return true;
                }} catch (Exception e) {{
                    filePathCallback = null;
                    return false;
                }}
            }}
        }});

        webView.loadUrl("file:///android_asset/www/{entry}");
    }}

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {{
        if (requestCode == FILE_CHOOSER_REQ && filePathCallback != null) {{
            Uri[] results = WebChromeClient.FileChooserParams.parseResult(resultCode, data);
            filePathCallback.onReceiveValue(results);
            filePathCallback = null;
            return;
        }}
        super.onActivityResult(requestCode, resultCode, data);
    }}

    @Override
    public void onBackPressed() {{
        if (webView != null && webView.canGoBack()) {{
            webView.goBack();
        }} else {{
            super.onBackPressed();
        }}
    }}
}}
"#,
        pkg = package_id,
        entry = java_escape(entry_file),
        status_bar_color = status_bar_color,
        nav_bar_color = nav_bar_color,
        splash_bg = splash_bg,
        light_status_bar = light_status_bar,
        fullscreen = fullscreen,
        keep_screen_on = keep_screen_on,
        enable_js = enable_js,
        enable_dom_storage = enable_dom_storage,
        enable_zoom = enable_zoom,
        open_external = open_external,
        allow_file_upload = allow_file_upload,
        user_agent = java_escape(user_agent),
        perm_location = perm_location,
        perms_array = perms_array,
    )
}

// ============================================================================
// ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
// ============================================================================

fn run_cmd(bin: &Path, args: &[&str], cwd: &Path, log: &mut String) -> Result<(), String> {
    let output = Command::new(bin)
        .args(args)
        .current_dir(cwd)
        .output()
        .map_err(|e| format!("Failed to execute {}: {}", bin.display(), e))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !stdout.trim().is_empty() {
        log.push_str(stdout.trim());
        log.push('\n');
    }
    if !stderr.trim().is_empty() {
        log.push_str(stderr.trim());
        log.push('\n');
    }

    if !output.status.success() {
        let detail = if !stderr.trim().is_empty() {
            stderr.trim().to_string()
        } else if !stdout.trim().is_empty() {
            stdout.trim().to_string()
        } else {
            format!("Exit code {:?}", output.status.code())
        };
        return Err(format!("{} failed: {}", bin.display(), detail));
    }
    Ok(())
}

fn collect_files_with_ext(dir: &Path, ext: &str, out: &mut Vec<PathBuf>) {
    if let Ok(rd) = fs::read_dir(dir) {
        for entry in rd.flatten() {
            let p = entry.path();
            if p.is_dir() {
                collect_files_with_ext(&p, ext, out);
            } else if p.extension().and_then(|e| e.to_str()) == Some(ext) {
                out.push(p);
            }
        }
    }
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let name = entry.file_name();
        if name == "__MACOSX" {
            continue;
        }
        let target = dst.join(name);
        if entry.file_type()?.is_dir() {
            copy_dir_recursive(&entry.path(), &target)?;
        } else {
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

fn sanitize_rel_path(raw: &str) -> Option<PathBuf> {
    let normalized = raw.replace('\\', "/");
    let mut clean = PathBuf::new();
    for comp in Path::new(&normalized).components() {
        if let Component::Normal(seg) = comp {
            clean.push(seg);
        }
    }
    if clean.as_os_str().is_empty() {
        None
    } else {
        Some(clean)
    }
}

fn is_html_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.ends_with(".html") || lower.ends_with(".htm")
}

fn is_likely_svg(bytes: &[u8]) -> bool {
    let head = String::from_utf8_lossy(&bytes[..bytes.len().min(512)]).to_ascii_lowercase();
    head.contains("<svg")
}

fn is_valid_package_id(pkg: &str) -> bool {
    let parts: Vec<&str> = pkg.split('.').collect();
    if parts.len() < 2 {
        return false;
    }
    for seg in parts {
        if seg.is_empty() {
            return false;
        }
        let mut chars = seg.chars();
        let first = chars.next().unwrap();
        if !first.is_ascii_lowercase() {
            return false;
        }
        if !chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') {
            return false;
        }
    }
    true
}

fn normalize_hex_color(input: &str, fallback: &str) -> String {
    let s = input.trim();
    if s.len() == 7 && s.starts_with('#') && s[1..].chars().all(|c| c.is_ascii_hexdigit()) {
        s.to_ascii_lowercase()
    } else {
        fallback.to_string()
    }
}

fn xml_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\u{27}' => out.push_str("&apos;"),
            _ => out.push(c),
        }
    }
    out
}

fn android_string_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("\\\""),
            '\u{27}' => out.push_str("\\'"),
            '\\' => out.push_str("\\\\"),
            _ => out.push(c),
        }
    }
    out
}

fn java_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            _ => out.push(c),
        }
    }
    out
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn sanitize_dname(s: &str) -> String {
    let cleaned: String = s
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == ' ' || *c == '-' || *c == '_')
        .collect();
    if cleaned.trim().is_empty() {
        "HTML2APK".to_string()
    } else {
        cleaned.trim().to_string()
    }
}

fn sanitize_filename_token(s: &str) -> String {
    let out: String = s
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-' || *c == '_')
        .collect();
    if out.is_empty() { "1.0".into() } else { out }
}

fn sanitize_header_filename(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-' || *c == '_')
        .collect()
}

// ============================================================================
// ВСТРОЕННЫЙ МИНИМАЛИСТИЧНЫЙ ИНТЕРФЕЙС (Текст только там, где он необходим)
// ============================================================================

const INDEX_HTML: &str = r####"<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>HTML2APK</title>
<style>
:root {
  --bg: #0a0b0e;
  --surface: #12141a;
  --surface-2: #181b23;
  --border: #242834;
  --border-hi: #3a4154;
  --fg: #f3f4f6;
  --muted: #8b93a7;
  --accent: #6366f1;
  --accent-hi: #818cf8;
  --ok: #10b981;
  --err: #ef4444;
  --radius: 14px;
}
@media (prefers-color-scheme: light) {
  :root {
    --bg: #f4f5f7;
    --surface: #ffffff;
    --surface-2: #f8f9fb;
    --border: #e3e6ee;
    --border-hi: #c4cad8;
    --fg: #111827;
    --muted: #6b7280;
    --accent: #4f46e5;
    --accent-hi: #6366f1;
  }
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, sans-serif;
  background: var(--bg);
  color: var(--fg);
  min-height: 100vh;
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 20px 16px 36px;
  -webkit-font-smoothing: antialiased;
}
.shell {
  width: 100%;
  max-width: 960px;
  display: flex;
  flex-direction: column;
  gap: 16px;
}
header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 4px 2px;
}
.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  font-weight: 700;
  font-size: 16px;
  letter-spacing: -0.02em;
}
.brand-mark {
  width: 28px;
  height: 28px;
  border-radius: 8px;
  background: linear-gradient(135deg, var(--accent), #06b6d4);
  display: grid;
  place-items: center;
  color: #fff;
}
.badge {
  font-size: 11px;
  font-weight: 600;
  color: var(--muted);
  background: var(--surface);
  border: 1px solid var(--border);
  padding: 4px 9px;
  border-radius: 999px;
}
.grid {
  display: grid;
  grid-template-columns: 330px 1fr;
  gap: 16px;
  align-items: start;
}
@media (max-width: 820px) {
  .grid { grid-template-columns: 1fr; }
}
.col {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.dropzone {
  position: relative;
  border: 1.5px dashed var(--border-hi);
  border-radius: 12px;
  background: var(--surface-2);
  padding: 20px 14px;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 8px;
  cursor: pointer;
  transition: border-color 0.16s, background 0.16s, transform 0.12s;
  text-align: center;
}
.dropzone:hover, .dropzone.drag {
  border-color: var(--accent);
  background: rgba(99, 102, 241, 0.08);
}
.dropzone.filled {
  border-style: solid;
  border-color: var(--ok);
}
.dropzone input { display: none; }
.drop-title {
  font-size: 13px;
  font-weight: 600;
}
.drop-meta {
  font-size: 11px;
  color: var(--muted);
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.icon-studio {
  display: flex;
  align-items: center;
  gap: 14px;
}
.icon-preview-box {
  width: 78px;
  height: 78px;
  flex-shrink: 0;
  display: grid;
  place-items: center;
  overflow: hidden;
  border: 1px solid var(--border);
  transition: border-radius 0.2s, background 0.15s;
  position: relative;
}
.icon-preview-box.mask-squircle { border-radius: 22px; }
.icon-preview-box.mask-circle { border-radius: 50%; }
.icon-preview-box.mask-square { border-radius: 10px; }
.icon-preview-box img {
  width: 100%;
  height: 100%;
  object-fit: contain;
  transition: transform 0.12s;
}
.icon-monogram {
  font-size: 32px;
  font-weight: 700;
  color: #fff;
  user-select: none;
}
.icon-controls {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: 0;
}
.seg {
  display: inline-flex;
  background: var(--surface-2);
  border: 1px solid var(--border);
  border-radius: 9px;
  padding: 2px;
  gap: 2px;
}
.seg button {
  flex: 1;
  border: 0;
  background: transparent;
  color: var(--muted);
  font-size: 11px;
  font-weight: 600;
  padding: 5px 8px;
  border-radius: 7px;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  transition: background 0.15s, color 0.15s;
}
.seg button.active {
  background: var(--surface);
  color: var(--fg);
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.2);
}
.row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
}
.row-3 {
  display: grid;
  grid-template-columns: 1fr 1fr 1fr;
  gap: 10px;
}
.field {
  display: flex;
  flex-direction: column;
  gap: 5px;
}
.field label {
  font-size: 11px;
  font-weight: 600;
  color: var(--muted);
  letter-spacing: 0.02em;
  display: flex;
  align-items: center;
  justify-content: space-between;
}
input[type="text"], input[type="number"], input[type="password"], select {
  width: 100%;
  background: var(--surface-2);
  border: 1px solid var(--border);
  border-radius: 9px;
  color: var(--fg);
  font-size: 13px;
  padding: 8px 10px;
  outline: none;
  transition: border-color 0.15s;
}
input:focus, select:focus {
  border-color: var(--accent);
}
input[type="range"] {
  width: 100%;
  accent-color: var(--accent);
  cursor: pointer;
}
.color-chip {
  display: flex;
  align-items: center;
  gap: 8px;
  background: var(--surface-2);
  border: 1px solid var(--border);
  border-radius: 9px;
  padding: 5px 8px;
  cursor: pointer;
}
.color-chip input[type="color"] {
  width: 20px;
  height: 20px;
  border: 0;
  padding: 0;
  background: none;
  cursor: pointer;
  border-radius: 5px;
}
.color-chip span {
  font-size: 11px;
  font-weight: 600;
  color: var(--muted);
}
.chips {
  display: flex;
  flex-wrap: wrap;
  gap: 7px;
}
.chip {
  user-select: none;
  font-size: 12px;
  font-weight: 500;
  padding: 6px 11px;
  border-radius: 999px;
  border: 1px solid var(--border);
  background: var(--surface-2);
  color: var(--muted);
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  transition: all 0.14s;
}
.chip.on {
  border-color: var(--accent);
  background: rgba(99, 102, 241, 0.14);
  color: var(--fg);
}
.chip .dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--border-hi);
}
.chip.on .dot {
  background: var(--accent-hi);
}
.tabs {
  display: flex;
  gap: 4px;
  border-bottom: 1px solid var(--border);
  padding-bottom: 10px;
}
.tab-btn {
  border: 0;
  background: transparent;
  color: var(--muted);
  font-size: 12px;
  font-weight: 600;
  padding: 6px 12px;
  border-radius: 8px;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.tab-btn.active {
  background: var(--surface-2);
  color: var(--fg);
}
.tab-panel { display: none; flex-direction: column; gap: 12px; }
.tab-panel.active { display: flex; }

.build-btn {
  width: 100%;
  border: 0;
  border-radius: 12px;
  background: var(--accent);
  color: #fff;
  font-size: 14px;
  font-weight: 600;
  padding: 13px 16px;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  transition: opacity 0.15s, transform 0.1s;
}
.build-btn:hover { opacity: 0.93; }
.build-btn:active { transform: scale(0.99); }
.build-btn:disabled { opacity: 0.55; cursor: wait; }

.status-bar {
  display: none;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 10px 12px;
  border-radius: 10px;
  font-size: 12px;
  border: 1px solid var(--border);
  background: var(--surface-2);
}
.status-bar.show { display: flex; }
.status-bar.ok { border-color: rgba(16, 185, 129, 0.5); }
.status-bar.err { border-color: rgba(239, 68, 68, 0.5); color: var(--err); }
.status-actions {
  display: flex;
  align-items: center;
  gap: 6px;
}
.mini-btn {
  border: 1px solid var(--border);
  background: var(--surface);
  color: var(--fg);
  font-size: 11px;
  font-weight: 600;
  padding: 5px 9px;
  border-radius: 7px;
  cursor: pointer;
  text-decoration: none;
}
.mini-btn:hover { border-color: var(--border-hi); }

.log-box {
  display: none;
  background: #07080a;
  color: #a5b4fc;
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 12px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 11px;
  line-height: 1.45;
  max-height: 220px;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-word;
}
.log-box.show { display: block; }
.spinner {
  width: 15px;
  height: 15px;
  border: 2px solid rgba(255, 255, 255, 0.35);
  border-top-color: #fff;
  border-radius: 50%;
  animation: spin 0.7s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
.ks-fields { display: none; flex-direction: column; gap: 10px; }
.ks-fields.show { display: flex; }
</style>
</head>
<body>
<div class="shell">
  <header>
    <div class="brand">
      <div class="brand-mark">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2L2 7l10 5 10-5-10-5z"/><path d="M2 17l10 5 10-5"/><path d="M2 12l10 5 10-5"/></svg>
      </div>
      <span>HTML2APK</span>
    </div>
    <span class="badge">Rust · Nix · SDK 35</span>
  </header>

  <div class="grid">
    <!-- Левая колонка: исходники, иконка, запуск сборки -->
    <div class="col">
      <div class="card">
        <div class="dropzone" id="htmlDrop">
          <input type="file" id="htmlInput" multiple accept=".html,.htm,.zip,.css,.js,.svg,.png,.jpg,.jpeg,.webp,.woff2,.json">
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="12" y1="18" x2="12" y2="12"/><polyline points="9 15 12 12 15 15"/></svg>
          <div class="drop-title" id="htmlTitle">HTML / ZIP</div>
          <div class="drop-meta" id="htmlMeta">.html · folder · .zip</div>
        </div>

        <div class="icon-studio">
          <div class="icon-preview-box mask-squircle" id="iconPreview" style="background:#111827">
            <span class="icon-monogram" id="iconMonogram">A</span>
            <img id="iconImg" style="display:none" alt="">
          </div>
          <div class="icon-controls">
            <div class="dropzone" id="iconDrop" style="padding:10px">
              <input type="file" id="iconInput" accept=".svg,.png,image/svg+xml,image/png">
              <div class="drop-title" id="iconTitle" style="font-size:12px">SVG / PNG</div>
              <div class="drop-meta" id="iconMeta">512px+</div>
            </div>
            <div class="seg" id="maskSeg">
              <button type="button" class="active" data-mask="mask-squircle" title="Squircle">▢</button>
              <button type="button" data-mask="mask-circle" title="Circle">○</button>
              <button type="button" data-mask="mask-square" title="Square">□</button>
            </div>
          </div>
        </div>

        <div class="row">
          <label class="color-chip">
            <input type="color" id="iconBg" value="#111827">
            <span>BG</span>
          </label>
          <div class="field" style="justify-content:center">
            <label><span>Pad</span><span id="padVal">18%</span></label>
            <input type="range" id="iconPad" min="0" max="38" value="18">
          </div>
        </div>
      </div>

      <button class="build-btn" id="buildBtn" type="button">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><polygon points="5 3 19 12 5 21 5 3"/></svg>
        <span id="buildBtnLabel">APK</span>
      </button>

      <div class="status-bar" id="statusBar">
        <span id="statusText"></span>
        <div class="status-actions">
          <a class="mini-btn" id="downloadLink" style="display:none" href="#">↓ APK</a>
          <button class="mini-btn" id="logToggle" type="button">&gt;_</button>
        </div>
      </div>

      <pre class="log-box" id="logBox"></pre>
    </div>

    <!-- Правая колонка: параметры -->
    <div class="card">
      <div class="tabs">
        <button type="button" class="tab-btn active" data-tab="app">App</button>
        <button type="button" class="tab-btn" data-tab="ui">Display</button>
        <button type="button" class="tab-btn" data-tab="web">WebView</button>
        <button type="button" class="tab-btn" data-tab="sign">Sign</button>
      </div>

      <!-- Вкладка App -->
      <div class="tab-panel active" id="tab-app">
        <div class="row">
          <div class="field">
            <label>Name</label>
            <input type="text" id="appName" value="MyApp" placeholder="MyApp">
          </div>
          <div class="field">
            <label>Package ID</label>
            <input type="text" id="packageId" value="com.app.myapp" placeholder="com.example.app">
          </div>
        </div>
        <div class="row-3">
          <div class="field">
            <label>Version</label>
            <input type="text" id="versionName" value="1.0.0">
          </div>
          <div class="field">
            <label>Code</label>
            <input type="number" id="versionCode" value="1" min="1">
          </div>
          <div class="field">
            <label>Entry</label>
            <input type="text" id="entryFile" value="index.html">
          </div>
        </div>
        <div class="row">
          <div class="field">
            <label>Min SDK</label>
            <input type="number" id="minSdk" value="24" min="21" max="35">
          </div>
          <div class="field">
            <label>Target SDK</label>
            <input type="number" id="targetSdk" value="35" min="24" max="35">
          </div>
        </div>
      </div>

      <!-- Вкладка Display -->
      <div class="tab-panel" id="tab-ui">
        <div class="field">
          <label>Orientation</label>
          <div class="seg" id="orientSeg">
            <button type="button" class="active" data-val="unspecified">Auto</button>
            <button type="button" data-val="portrait">Portrait</button>
            <button type="button" data-val="landscape">Landscape</button>
          </div>
        </div>
        <div class="row-3">
          <label class="color-chip">
            <input type="color" id="statusBarColor" value="#0f1115">
            <span>Status</span>
          </label>
          <label class="color-chip">
            <input type="color" id="navBarColor" value="#0f1115">
            <span>Nav</span>
          </label>
          <label class="color-chip">
            <input type="color" id="splashBg" value="#0f1115">
            <span>Splash</span>
          </label>
        </div>
        <div class="chips" id="uiChips">
          <button type="button" class="chip" data-key="fullscreen"><span class="dot"></span>Fullscreen</button>
          <button type="button" class="chip" data-key="light_status_bar"><span class="dot"></span>Light Status</button>
          <button type="button" class="chip" data-key="keep_screen_on"><span class="dot"></span>Awake</button>
        </div>
      </div>

      <!-- Вкладка WebView -->
      <div class="tab-panel" id="tab-web">
        <div class="chips" id="webChips">
          <button type="button" class="chip on" data-key="enable_js"><span class="dot"></span>JS</button>
          <button type="button" class="chip on" data-key="enable_dom_storage"><span class="dot"></span>Storage</button>
          <button type="button" class="chip" data-key="enable_zoom"><span class="dot"></span>Zoom</button>
          <button type="button" class="chip on" data-key="open_external"><span class="dot"></span>Ext Links</button>
          <button type="button" class="chip on" data-key="allow_cleartext"><span class="dot"></span>HTTP</button>
          <button type="button" class="chip on" data-key="allow_file_upload"><span class="dot"></span>File Input</button>
        </div>
        <div class="field">
          <label>Permissions</label>
          <div class="chips" id="permChips">
            <button type="button" class="chip on" data-key="perm_internet"><span class="dot"></span>Internet</button>
            <button type="button" class="chip" data-key="perm_camera"><span class="dot"></span>Camera</button>
            <button type="button" class="chip" data-key="perm_audio"><span class="dot"></span>Mic</button>
            <button type="button" class="chip" data-key="perm_location"><span class="dot"></span>GPS</button>
            <button type="button" class="chip" data-key="perm_vibrate"><span class="dot"></span>Vibrate</button>
          </div>
        </div>
        <div class="field">
          <label>User-Agent</label>
          <input type="text" id="userAgent" placeholder="Default">
        </div>
      </div>

      <!-- Вкладка Sign -->
      <div class="tab-panel" id="tab-sign">
        <div class="seg" id="signSeg">
          <button type="button" class="active" data-mode="auto">Auto Key</button>
          <button type="button" data-mode="custom">Keystore</button>
        </div>
        <div class="ks-fields" id="ksFields">
          <div class="dropzone" id="ksDrop" style="padding:12px">
            <input type="file" id="ksInput" accept=".jks,.keystore,.p12,.pkcs12">
            <div class="drop-title" id="ksTitle" style="font-size:12px">.jks / .p12</div>
          </div>
          <div class="row-3">
            <div class="field">
              <label>Alias</label>
              <input type="text" id="ksAlias" placeholder="key0">
            </div>
            <div class="field">
              <label>Store Pass</label>
              <input type="password" id="ksStorePass">
            </div>
            <div class="field">
              <label>Key Pass</label>
              <input type="password" id="ksKeyPass">
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<script>
(function() {
  var state = {
    files: [],
    iconExt: "",
    iconBytes: null,
    ksBytes: null,
    orientation: "unspecified",
    signMode: "auto",
    pkgTouched: false
  };

  var el = function(id) { return document.getElementById(id); };

  // Вкладки настроек
  document.querySelectorAll(".tab-btn").forEach(function(btn) {
    btn.addEventListener("click", function() {
      document.querySelectorAll(".tab-btn").forEach(function(b) { b.classList.remove("active"); });
      document.querySelectorAll(".tab-panel").forEach(function(p) { p.classList.remove("active"); });
      btn.classList.add("active");
      el("tab-" + btn.dataset.tab).classList.add("active");
    });
  });

  // Переключатели-чипы
  document.querySelectorAll(".chip").forEach(function(chip) {
    chip.addEventListener("click", function() {
      chip.classList.toggle("on");
    });
  });

  // Сегмент ориентации
  el("orientSeg").querySelectorAll("button").forEach(function(btn) {
    btn.addEventListener("click", function() {
      el("orientSeg").querySelectorAll("button").forEach(function(b) { b.classList.remove("active"); });
      btn.classList.add("active");
      state.orientation = btn.dataset.val;
    });
  });

  // Сегмент маски предпросмотра иконки
  el("maskSeg").querySelectorAll("button").forEach(function(btn) {
    btn.addEventListener("click", function() {
      el("maskSeg").querySelectorAll("button").forEach(function(b) { b.classList.remove("active"); });
      btn.classList.add("active");
      var box = el("iconPreview");
      box.className = "icon-preview-box " + btn.dataset.mask;
    });
  });

  // Сегмент подписи
  el("signSeg").querySelectorAll("button").forEach(function(btn) {
    btn.addEventListener("click", function() {
      el("signSeg").querySelectorAll("button").forEach(function(b) { b.classList.remove("active"); });
      btn.classList.add("active");
      state.signMode = btn.dataset.mode;
      el("ksFields").classList.toggle("show", state.signMode === "custom");
    });
  });

  // Авто-генерация Package ID и монограммы по имени приложения
  el("packageId").addEventListener("input", function() { state.pkgTouched = true; });
  el("appName").addEventListener("input", function() {
    var name = el("appName").value.trim();
    el("iconMonogram").textContent = (name.replace(/[^a-zA-Z0-9\u0400-\u04FF]/g, "")[0] || "A").toUpperCase();
    if (!state.pkgTouched) {
      var slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "").slice(0, 24);
      if (slug && /^[a-z]/.test(slug)) {
        el("packageId").value = "com.app." + slug;
      }
    }
  });

  // Цвет фона и отступ иконки в живом предпросмотре
  function syncIconPreview() {
    var bg = el("iconBg").value;
    var pad = parseInt(el("iconPad").value, 10) || 0;
    el("padVal").textContent = pad + "%";
    el("iconPreview").style.background = bg;
    var scale = 1 - (pad / 100);
    el("iconImg").style.transform = "scale(" + scale.toFixed(2) + ")";
  }
  el("iconBg").addEventListener("input", syncIconPreview);
  el("iconPad").addEventListener("input", syncIconPreview);
  syncIconPreview();

  // Настройка Dropzone
  function wireDropzone(boxEl, inputEl, onFiles) {
    boxEl.addEventListener("click", function() { inputEl.click(); });
    boxEl.addEventListener("dragover", function(e) {
      e.preventDefault();
      boxEl.classList.add("drag");
    });
    boxEl.addEventListener("dragleave", function() {
      boxEl.classList.remove("drag");
    });
    boxEl.addEventListener("drop", function(e) {
      e.preventDefault();
      boxEl.classList.remove("drag");
      if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length) {
        onFiles(e.dataTransfer.files);
      }
    });
    inputEl.addEventListener("change", function() {
      if (inputEl.files && inputEl.files.length) {
        onFiles(inputEl.files);
      }
    });
  }

  // Загрузка HTML / ZIP / нескольких файлов
  wireDropzone(el("htmlDrop"), el("htmlInput"), function(fileList) {
    var arr = Array.prototype.slice.call(fileList);
    Promise.all(arr.map(function(f) {
      return f.arrayBuffer().then(function(buf) {
        return {
          path: (f.webkitRelativePath && f.webkitRelativePath.length > 0) ? f.webkitRelativePath : f.name,
          bytes: new Uint8Array(buf)
        };
      });
    })).then(function(loaded) {
      state.files = loaded;
      el("htmlDrop").classList.add("filled");
      if (loaded.length === 1) {
        el("htmlTitle").textContent = loaded[0].path;
        el("htmlMeta").textContent = formatSize(loaded[0].bytes.length);
      } else {
        var total = loaded.reduce(function(acc, f) { return acc + f.bytes.length; }, 0);
        el("htmlTitle").textContent = loaded.length + " files";
        el("htmlMeta").textContent = formatSize(total);
      }
      var firstHtml = loaded.find(function(f) { return /\.html?$/i.test(f.path); });
      if (firstHtml && loaded.length > 1) {
        el("entryFile").value = firstHtml.path;
      }
    });
  });

  // Загрузка иконки SVG / PNG
  wireDropzone(el("iconDrop"), el("iconInput"), function(fileList) {
    var f = fileList[0];
    if (!f) return;
    var isSvg = /\.svg$/i.test(f.name) || f.type === "image/svg+xml";
    f.arrayBuffer().then(function(buf) {
      state.iconExt = isSvg ? "svg" : "png";
      state.iconBytes = new Uint8Array(buf);
      el("iconDrop").classList.add("filled");
      el("iconTitle").textContent = f.name;
      el("iconMeta").textContent = (isSvg ? "SVG · " : "PNG · ") + formatSize(state.iconBytes.length);

      var blob = new Blob([state.iconBytes], { type: isSvg ? "image/svg+xml" : "image/png" });
      var url = URL.createObjectURL(blob);
      el("iconImg").src = url;
      el("iconImg").style.display = "block";
      el("iconMonogram").style.display = "none";
      syncIconPreview();
    });
  });

  // Загрузка собственного Keystore
  wireDropzone(el("ksDrop"), el("ksInput"), function(fileList) {
    var f = fileList[0];
    if (!f) return;
    f.arrayBuffer().then(function(buf) {
      state.ksBytes = new Uint8Array(buf);
      el("ksDrop").classList.add("filled");
      el("ksTitle").textContent = f.name;
    });
  });

  el("logToggle").addEventListener("click", function() {
    el("logBox").classList.toggle("show");
  });

  // Упаковка в бинарный пакет для Rust-сервера
  function packBinaryPayload(cfgMap) {
    var enc = new TextEncoder();
    var chunks = [];
    var totalLen = 0;

    function pushU32(n) {
      var b = new Uint8Array(4);
      new DataView(b.buffer).setUint32(0, n >>> 0, false);
      chunks.push(b);
      totalLen += 4;
    }
    function pushBytes(u8) {
      pushU32(u8.length);
      if (u8.length > 0) {
        chunks.push(u8);
        totalLen += u8.length;
      }
    }
    function pushStr(s) {
      pushBytes(enc.encode(String(s || "")));
    }

    var keys = Object.keys(cfgMap);
    pushU32(keys.length);
    keys.forEach(function(k) {
      pushStr(k);
      pushStr(cfgMap[k]);
    });

    pushU32(state.files.length);
    state.files.forEach(function(f) {
      pushStr(f.path);
      pushBytes(f.bytes);
    });

    pushStr(state.iconExt);
    pushBytes(state.iconBytes || new Uint8Array(0));
    pushBytes((state.signMode === "custom" && state.ksBytes) ? state.ksBytes : new Uint8Array(0));

    var out = new Uint8Array(totalLen);
    var offset = 0;
    chunks.forEach(function(c) {
      out.set(c, offset);
      offset += c.length;
    });
    return out;
  }

  function showStatus(kind, text, downloadUrl, logText) {
    var bar = el("statusBar");
    bar.className = "status-bar show " + kind;
    el("statusText").textContent = text;
    var dl = el("downloadLink");
    if (downloadUrl) {
      dl.href = downloadUrl;
      dl.style.display = "inline-block";
    } else {
      dl.style.display = "none";
    }
    el("logBox").textContent = logText || "";
    if (kind === "err" && logText) {
      el("logBox").classList.add("show");
    }
  }

  function formatSize(bytes) {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
    return (bytes / (1024 * 1024)).toFixed(2) + " MB";
  }

  // Запуск сборки APK
  el("buildBtn").addEventListener("click", function() {
    if (!state.files.length) {
      showStatus("err", "Upload HTML / ZIP", null, "");
      return;
    }

    var cfg = {
      app_name: el("appName").value.trim() || "MyApp",
      package_id: el("packageId").value.trim() || "com.app.myapp",
      version_name: el("versionName").value.trim() || "1.0.0",
      version_code: el("versionCode").value || "1",
      entry_file: el("entryFile").value.trim() || "index.html",
      min_sdk: el("minSdk").value || "24",
      target_sdk: el("targetSdk").value || "35",
      orientation: state.orientation,
      icon_bg: el("iconBg").value,
      icon_padding: el("iconPad").value,
      status_bar_color: el("statusBarColor").value,
      nav_bar_color: el("navBarColor").value,
      splash_bg: el("splashBg").value,
      user_agent: el("userAgent").value.trim(),
      ks_alias: el("ksAlias").value.trim(),
      ks_store_pass: el("ksStorePass").value,
      ks_key_pass: el("ksKeyPass").value
    };

    document.querySelectorAll(".chip").forEach(function(chip) {
      cfg[chip.dataset.key] = chip.classList.contains("on") ? "true" : "false";
    });

    var btn = el("buildBtn");
    btn.disabled = true;
    btn.innerHTML = "<span class=\"spinner\"></span><span>Building...</span>";
    el("logBox").classList.remove("show");

    var payload = packBinaryPayload(cfg);

    fetch("/api/build", {
      method: "POST",
      headers: { "Content-Type": "application/octet-stream" },
      body: payload
    })
      .then(function(res) { return res.json(); })
      .then(function(data) {
        if (data.ok) {
          var url = "/api/download/" + data.id;
          var sec = (data.elapsed_ms / 1000).toFixed(1) + "s";
          showStatus("ok", data.filename + " · " + formatSize(data.size) + " · " + sec, url, data.log);
          // Автоматическое скачивание готового APK
          var a = document.createElement("a");
          a.href = url;
          a.download = data.filename;
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
        } else {
          showStatus("err", data.error || "Build failed", null, data.log || "");
        }
      })
      .catch(function(err) {
        showStatus("err", String(err), null, "");
      })
      .finally(function() {
        btn.disabled = false;
        btn.innerHTML = "<svg width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><polygon points=\"5 3 19 12 5 21 5 3\"/></svg><span>APK</span>";
      });
  });
})();
</script>
</body>
</html>
"####;
'';

          html2apk = pkgs.stdenv.mkDerivation {
            pname = "html2apk";
            version = "1.0.0";
            dontUnpack = true;

            nativeBuildInputs = [
              pkgs.rustc
              pkgs.makeWrapper
            ];

            buildPhase = ''
              runHook preBuild
              rustc --edition 2021 -O ${rustSource} -o html2apk
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp html2apk $out/bin/html2apk
              wrapProgram $out/bin/html2apk \
                --prefix PATH : "${pkgs.lib.makeBinPath runtimeTools}" \
                --set JAVA_HOME "${pkgs.jdk21}" \
                --set ANDROID_SDK_ROOT "${androidSdk}/libexec/android-sdk" \
                --set ANDROID_BUILD_TOOLS "${androidSdk}/libexec/android-sdk/build-tools/${androidBuildToolsVersion}" \
                --set ANDROID_PLATFORM_JAR "${androidSdk}/libexec/android-sdk/platforms/android-${androidApiLevel}/android.jar"
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Convert HTML projects into signed Android APKs with SVG/PNG icon support";
              platforms = supportedSystems;
              mainProgram = "html2apk";
            };
          };
        in
        {
          default = html2apk;
          inherit html2apk;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/html2apk";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };
        in
        {
          default = pkgs.mkShell {
            packages = [
              self.packages.${system}.default
              pkgs.rustc
              pkgs.rustfmt
            ];
          };
        }
      );
    };
}
