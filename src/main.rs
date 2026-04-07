mod config;
mod detection;
mod git;
mod guardrails;
mod health;
mod logger;
mod loop_engine;
mod prd;
mod prompt;
mod providers;
mod signals;
mod state;

use anyhow::Result;
use clap::{Parser, Subcommand};
use colored::Colorize;
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "ralph", about = "Autonomous AI Agent Loop (Rust)")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    #[arg(long, default_value = "codex")]
    provider: String,

    #[arg(long, default_value = "gpt-5.4")]
    model: String,

    #[arg(long, default_value = "high")]
    reasoning: String,

    #[arg(long)]
    config: Option<PathBuf>,

    #[arg(long)]
    max_iterations: Option<u32>,
}

#[derive(Subcommand)]
enum Commands {
    Watch,
    Status,
    Reset,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    let ralph_dir = std::env::current_dir()?;
    let mut ralph_config = config::RalphConfig::from_defaults(&ralph_dir);

    if let Some(config_path) = &cli.config {
        let resolved = if config_path.is_absolute() {
            config_path.clone()
        } else {
            ralph_dir.join(config_path)
        };
        ralph_config.load_toml_overlay(&resolved)?;
    }

    if let Some(max_iter) = cli.max_iterations {
        ralph_config.max_iterations = max_iter;
    }

    match &cli.command {
        Some(Commands::Watch) => {
            run_watch(&ralph_config).await;
            return Ok(());
        }
        Some(Commands::Status) => {
            run_status(&ralph_config, &cli.provider, &cli.model).await;
            return Ok(());
        }
        Some(Commands::Reset) => {
            state::reset_all(
                &ralph_config.state_file,
                &ralph_config.pause_file,
                &ralph_config.done_file,
            );
            return Ok(());
        }
        None => {}
    }

    let prd = prd::Prd::load(&ralph_config.prd_file)?;
    ralph_config.work_dir = PathBuf::from(&prd.working_directory);

    if !ralph_config.work_dir.is_dir() {
        anyhow::bail!(
            "workingDirectory does not exist: {}",
            ralph_config.work_dir.display()
        );
    }

    if ralph_config.prd_backup.as_os_str().is_empty() {
        ralph_config.prd_backup = ralph_config.prd_file.with_extension("json.bak");
    }

    logger::log_session_header(
        ralph_config.max_iterations,
        ralph_config.poll_interval_secs,
        &cli.provider,
        &cli.model,
    );

    println!("Project: {}", prd.project.blue());
    println!("Feature: {}", prd.feature.blue());
    println!("Working dir: {}", ralph_config.work_dir.display());
    if let Some(ref branch) = prd.branch_name {
        println!("Branch: {} -> origin/main", branch.green());
    }
    println!();

    logger::rotate_log_if_large(&ralph_config.error_log, 1000);
    guardrails::ensure_exists(&ralph_config.guardrails_file);
    logger::log_activity(
        "=== Ralph (Rust) session started ===",
        &ralph_config.activity_log,
    );

    if !ralph_config.progress_file.exists() && !ralph_config.progress_file.as_os_str().is_empty() {
        let header = format!(
            "# Ralph Progress Log\n# Feature: {}\n# Started: {}\n\n",
            prd.feature,
            chrono::Local::now().format("%Y-%m-%d %H:%M:%S"),
        );
        let _ = std::fs::write(&ralph_config.progress_file, header);
    }

    let shutdown_flag = signals::setup_shutdown_flag();

    let provider_kind = providers::ProviderKind::from_str(&cli.provider)
        .ok_or_else(|| anyhow::anyhow!("Unknown provider: {}. Use: codex, claude, cursor", cli.provider))?;

    match provider_kind {
        providers::ProviderKind::Codex => {
            let provider =
                providers::codex::CodexProvider::new(cli.model.clone(), cli.reasoning.clone());
            loop_engine::run(&ralph_config, &provider, shutdown_flag).await?;
        }
        providers::ProviderKind::Claude => {
            let provider = providers::claude::ClaudeProvider::new(cli.model.clone());
            loop_engine::run(&ralph_config, &provider, shutdown_flag).await?;
        }
        providers::ProviderKind::Cursor => {
            let provider = providers::cursor::CursorProvider::new(cli.model.clone());
            loop_engine::run(&ralph_config, &provider, shutdown_flag).await?;
        }
    }

    Ok(())
}

async fn run_watch(config: &config::RalphConfig) {
    println!("{}", "===============================================".cyan());
    println!("  Ralph (Rust) Watch Mode");
    println!("{}", "===============================================".cyan());
    println!();
    logger::log_info("Monitoring logs in real time...");
    println!("{}", "   Press Ctrl+C to exit".dimmed());
    println!();

    if config.activity_log.exists() {
        let _ = tokio::process::Command::new("tail")
            .args([
                "-f",
                &config.activity_log.to_string_lossy(),
                &config.error_log.to_string_lossy(),
            ])
            .status()
            .await;
    } else {
        logger::log_warning("No logs yet. Run Ralph first.");
    }
}

async fn run_status(
    config: &config::RalphConfig,
    provider_name: &str,
    model_name: &str,
) {
    println!("{}", "===============================================".cyan());
    println!("  Ralph (Rust) Status");
    println!("{}", "===============================================".cyan());
    println!();

    if let Ok(prd) = prd::Prd::load(&config.prd_file) {
        println!(
            "   Stories: {} / {} completed",
            prd.passed_count(),
            prd.total_stories()
        );
        println!("   Pending: {}", prd.pending_count());
        println!("   Blocked: {}", prd.blocked_count());
    }

    if config.state_file.exists() {
        println!();
        println!("   {}", "Active state found".yellow());
    }

    if config.pause_file.exists() {
        println!();
        println!("   {}", "Ralph is PAUSED".yellow());
    }

    if config.failure_memory_file.exists() {
        let memory = detection::failure_memory::FailureMemory::load(&config.failure_memory_file);
        let total_failures: usize = memory
            .stories
            .iter()
            .map(|record| record.attempts.len())
            .sum();
        let guttered = memory
            .stories
            .iter()
            .filter(|record| record.gutter_score >= config.gutter_threshold)
            .count();
        println!();
        println!("   Failure memory: {total_failures} attempts tracked");
        println!("   Stories in gutter: {guttered}");
    }

    println!();
    println!("   Provider: {provider_name}");
    println!("   Model: {model_name}");
    println!();
}
