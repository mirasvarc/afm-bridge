// The model itself is driven from the webview (afm-bridge + TauriSidecarTransport);
// Rust only registers the shell plugin. The two commands exist for `pnpm selftest`.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[tauri::command]
fn self_test_enabled() -> bool {
    std::env::var_os("AFM_EXAMPLE_SELFTEST").is_some()
}

#[tauri::command]
fn self_test_finished(app: tauri::AppHandle, ok: bool, message: String) {
    println!("SELFTEST {}: {}", if ok { "OK" } else { "FAILED" }, message);
    app.exit(if ok { 0 } else { 1 });
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![self_test_enabled, self_test_finished])
        .run(tauri::generate_context!())
        .expect("error while running the Tauri application");
}
