use chrono::Local;
use colored::Colorize;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;

pub fn log_error(message: &str, error_log: Option<&Path>) {
    let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S");
    if let Some(log_path) = error_log {
        let formatted = format!("[{timestamp}] ERROR: {message}\n");
        append_to_file(log_path, &formatted);
    }
    eprintln!("{}", format!("x {message}").red());
}

pub fn log_info(message: &str) {
    println!("{}", format!("i {message}").cyan());
}

pub fn log_success(message: &str) {
    println!("{}", format!("v {message}").green());
}

pub fn log_warning(message: &str) {
    println!("{}", format!("! {message}").yellow());
}

pub fn log_activity(message: &str, activity_log: &Path) {
    let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S");
    let formatted = format!("[{timestamp}] {message}\n");
    append_to_file(activity_log, &formatted);
}

pub fn log_iteration_header(iteration: u32) {
    println!();
    println!("{}", "===============================================".blue());
    println!("  Iteration {iteration}");
    println!("{}", "===============================================".blue());
}

pub fn log_session_header(
    max_iterations: u32,
    poll_interval: u64,
    provider_name: &str,
    model: &str,
) {
    println!("{}", "===============================================".cyan());
    println!("  Ralph (Rust) Autonomous AI Agent");
    println!("{}", "===============================================".cyan());
    println!();
    println!("   Max iterations: {max_iterations}");
    println!(
        "   Poll interval: {poll_interval}s ({})",
        format_duration(poll_interval)
    );
    println!("   Provider: {provider_name}");
    println!("   Model: {model}");
    println!();
}

pub fn format_duration(seconds: u64) -> String {
    let hours = seconds / 3600;
    let minutes = (seconds % 3600) / 60;
    let secs = seconds % 60;
    if hours > 0 {
        format!("{hours}h {minutes}m")
    } else if minutes > 0 {
        format!("{minutes}m {secs}s")
    } else {
        format!("{secs}s")
    }
}

fn append_to_file(path: &Path, content: &str) {
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = file.write_all(content.as_bytes());
    }
}

pub fn rotate_log_if_large(path: &Path, max_lines: usize) {
    if let Ok(content) = std::fs::read_to_string(path) {
        let line_count = content.lines().count();
        if line_count > max_lines {
            let old_path = path.with_extension("log.old");
            let _ = std::fs::rename(path, old_path);
            log_info("Log rotated");
        }
    }
}
