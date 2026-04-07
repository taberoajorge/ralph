use crate::config::RalphConfig;
use crate::detection::failure_memory::FailureMemory;
use crate::detection::progress;
use crate::git;
use crate::guardrails;
use crate::health;
use crate::logger;
use crate::prd::Prd;
use crate::prompt::PromptBuilder;
use crate::providers::Provider;
use crate::state;
use anyhow::Result;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

pub async fn run<P: Provider>(
    config: &RalphConfig,
    provider: &P,
    shutdown_flag: Arc<AtomicBool>,
) -> Result<()> {
    let mut iteration: u32 = 0;
    let initial_commit = git::get_head_hash(&config.work_dir).await.unwrap_or_default();
    let mut failure_memory = FailureMemory::load(&config.failure_memory_file);
    let mut consecutive_zero_progress: u32 = 0;

    while iteration < config.max_iterations {
        if shutdown_flag.load(Ordering::SeqCst) {
            logger::log_warning("Shutdown requested, exiting loop");
            break;
        }

        state::wait_while_paused(&config.pause_file).await;
        if state::check_and_clear_done(&config.done_file) {
            break;
        }

        let services_ok = health::check_all_services_parallel(config).await;
        if !services_ok {
            logger::log_error("Services unavailable, retrying in 30s", Some(&config.error_log));
            logger::log_activity("Iteration skipped: services down", &config.activity_log);
            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
            continue;
        }

        let mut prd = match load_or_restore_prd(config) {
            Some(prd) => prd,
            None => {
                logger::log_error("PRD unrecoverable, stopping", Some(&config.error_log));
                break;
            }
        };

        let total = prd.total_stories();
        let passed = prd.passed_count();
        let blocked = prd.blocked_count();
        let pending = prd.pending_count();

        if pending == 0 {
            logger::log_success(&format!(
                "All stories completed! {passed} passed, {blocked} blocked."
            ));
            break;
        }

        let next_story = match prd.next_actionable_story() {
            Some(story) => story.clone(),
            None => {
                logger::log_success("No more actionable stories. Done.");
                break;
            }
        };

        iteration += 1;
        let iter_start = std::time::Instant::now();

        logger::log_iteration_header(iteration);
        logger::log_activity(
            &format!("=== Iteration {iteration} started ==="),
            &config.activity_log,
        );

        println!(
            "   Progress: {passed}/{total} | Pending: {pending} | Blocked: {blocked}"
        );
        println!("   Story: {}", next_story.title);

        if failure_memory.is_in_gutter(&next_story.id, config.gutter_threshold) {
            logger::log_warning(&format!(
                "GUTTER: {} has failed {}+ times, skipping",
                next_story.id, config.gutter_threshold
            ));
            guardrails::add_guardrail(
                &config.guardrails_file,
                &next_story.id,
                "Exceeded gutter threshold",
                iteration,
            );
            logger::log_activity(
                &format!("Story {} skipped (gutter threshold)", next_story.id),
                &config.activity_log,
            );

            prd.user_stories
                .iter_mut()
                .find(|story| story.id == next_story.id)
                .map(|story| story.blocked = true);
            prd.save(&config.prd_file)?;
            continue;
        }

        prd.save(&config.prd_backup)?;

        let progress_before = progress::get_progress_file_size(&config.progress_file);

        let head_before = git::get_head_hash(&config.work_dir)
            .await
            .unwrap_or_default();

        let prompt_builder = PromptBuilder::new(
            &config.prompt_file,
            &config.guardrails_file,
            &config.ralph_dir,
            &config.work_dir,
            iteration,
            &failure_memory,
        );
        let full_prompt = prompt_builder.build(&next_story, None);

        logger::log_info(&format!("Starting {} agent ({})...", provider.name(), provider.model()));

        let agent_result = provider
            .run_agent(
                &full_prompt,
                &next_story.id,
                &config.work_dir,
                config.stall_timeout_secs,
                shutdown_flag.clone(),
                &config.codex_output_log,
            )
            .await;

        git::remove_git_lock(&config.work_dir).await;

        let prd = match load_or_restore_prd(config) {
            Some(prd) => prd,
            None => {
                logger::log_error("PRD unrecoverable after iteration", Some(&config.error_log));
                break;
            }
        };

        let story_passed = prd
            .user_stories
            .iter()
            .find(|story| story.id == next_story.id)
            .map(|story| story.passes)
            .unwrap_or(false);

        let progress_report = progress::analyze_iteration_progress(
            &config.work_dir,
            &head_before,
            story_passed,
            &config.progress_file,
            progress_before,
        )
        .await;

        match &agent_result {
            Ok(result) if result.rate_limited => {
                let wait_secs = compute_rate_limit_wait(result);
                let retry_hint = result
                    .retry_after_message
                    .as_deref()
                    .unwrap_or("unknown");
                logger::log_warning(&format!(
                    "RATE LIMITED! Provider says retry at: {retry_hint}. Sleeping {}m {}s...",
                    wait_secs / 60,
                    wait_secs % 60,
                ));
                logger::log_error(
                    &format!("Iteration {iteration} rate limited (retry at: {retry_hint})"),
                    Some(&config.error_log),
                );
                logger::log_activity(
                    &format!("Rate limited at iteration {iteration}, sleeping {wait_secs}s"),
                    &config.activity_log,
                );
                iteration = iteration.saturating_sub(1);
                if interruptible_sleep(wait_secs, &shutdown_flag).await {
                    logger::log_warning("Shutdown requested during rate limit wait");
                    break;
                }
                continue;
            }
            Ok(result) if result.success() => {
                if story_passed {
                    logger::log_success(&format!("Story {} completed!", next_story.id));
                    consecutive_zero_progress = 0;
                } else if progress_report.zero_progress {
                    consecutive_zero_progress += 1;
                    logger::log_warning(&format!(
                        "Zero progress detected ({consecutive_zero_progress} consecutive)"
                    ));
                    let approach = summarize_approach(&result.output_lines);
                    failure_memory.record_failure(
                        &next_story.id,
                        iteration,
                        "zero_progress",
                        vec![],
                        &approach,
                    );
                    if consecutive_zero_progress >= 2 {
                        guardrails::add_guardrail(
                            &config.guardrails_file,
                            &next_story.id,
                            "Zero progress in consecutive iterations",
                            iteration,
                        );
                    }
                } else {
                    consecutive_zero_progress = 0;
                    logger::log_warning(&format!(
                        "Story {}: agent finished but not marked as passed",
                        next_story.id
                    ));
                }
            }
            Ok(result) => {
                let approach = summarize_approach(&result.output_lines);
                let error_type = if result.stall_killed {
                    "stall_killed"
                } else {
                    "nonzero_exit"
                };
                failure_memory.record_failure(
                    &next_story.id,
                    iteration,
                    error_type,
                    vec![],
                    &approach,
                );
                logger::log_error(
                    &format!(
                        "Iteration {iteration} failed (exit: {}, stall: {})",
                        result.exit_code, result.stall_killed
                    ),
                    Some(&config.error_log),
                );
            }
            Err(err) => {
                failure_memory.record_failure(
                    &next_story.id,
                    iteration,
                    "spawn_error",
                    vec![],
                    &err.to_string(),
                );
                logger::log_error(
                    &format!("Iteration {iteration} error: {err}"),
                    Some(&config.error_log),
                );
            }
        }

        failure_memory.save(&config.failure_memory_file)?;

        let elapsed = iter_start.elapsed().as_secs();
        let total_commits = git::count_commits_since(&config.work_dir, &initial_commit)
            .await
            .unwrap_or(0);

        logger::log_activity(
            &format!(
                "Iteration {iteration} completed in {} | Commits: {total_commits} | Story: {} | Passed: {story_passed}",
                logger::format_duration(elapsed),
                next_story.id,
            ),
            &config.activity_log,
        );
        println!(
            "   Duration: {} | Commits: {total_commits}",
            logger::format_duration(elapsed)
        );

        logger::log_info(&format!(
            "Cooldown {}s before next iteration...",
            config.cooldown_secs
        ));
        if interruptible_sleep(config.cooldown_secs, &shutdown_flag).await {
            logger::log_warning("Shutdown requested during cooldown");
            break;
        }
    }

    print_session_summary(iteration, config, &initial_commit).await;
    state::clear_state(&config.state_file);
    Ok(())
}

async fn interruptible_sleep(total_secs: u64, shutdown_flag: &Arc<AtomicBool>) -> bool {
    let mut remaining = total_secs;
    while remaining > 0 {
        if shutdown_flag.load(Ordering::SeqCst) {
            return true;
        }
        let chunk = remaining.min(2);
        tokio::time::sleep(std::time::Duration::from_secs(chunk)).await;
        remaining = remaining.saturating_sub(chunk);
    }
    false
}

fn compute_rate_limit_wait(result: &crate::providers::AgentResult) -> u64 {
    if let Some(ref retry_hint) = result.retry_after_message {
        if let Some(secs) = parse_retry_time_to_secs(retry_hint) {
            return secs.min(3600);
        }
    }
    600
}

fn parse_retry_time_to_secs(time_str: &str) -> Option<u64> {
    let now = chrono::Local::now();
    let cleaned = time_str
        .trim()
        .replace(".", "")
        .to_uppercase();

    let is_pm = cleaned.contains("PM");
    let is_am = cleaned.contains("AM");
    let digits_only = cleaned
        .replace("PM", "")
        .replace("AM", "")
        .trim()
        .to_string();

    let parts: Vec<&str> = digits_only.split(':').collect();
    if parts.is_empty() || parts.len() > 2 {
        return None;
    }

    let mut hour: u32 = parts[0].trim().parse().ok()?;
    let minute: u32 = if parts.len() == 2 {
        parts[1].trim().parse().ok()?
    } else {
        0
    };

    if is_pm && hour < 12 {
        hour += 12;
    } else if is_am && hour == 12 {
        hour = 0;
    }

    let target = now
        .date_naive()
        .and_hms_opt(hour, minute, 0)?;
    let target_dt = target
        .and_local_timezone(now.timezone())
        .single()?;

    let diff = target_dt.signed_duration_since(now);
    if diff.num_seconds() <= 0 {
        return Some(120);
    }
    Some(diff.num_seconds() as u64 + 30)
}

fn load_or_restore_prd(config: &RalphConfig) -> Option<Prd> {
    if Prd::is_valid_json(&config.prd_file) {
        return Prd::load(&config.prd_file).ok();
    }
    logger::log_warning("PRD missing or corrupted, restoring from backup");
    if config.prd_backup.exists() {
        let _ = std::fs::copy(&config.prd_backup, &config.prd_file);
        return Prd::load(&config.prd_file).ok();
    }
    None
}

fn summarize_approach(output_lines: &[String]) -> String {
    let meaningful: Vec<&str> = output_lines
        .iter()
        .rev()
        .take(20)
        .filter(|line| {
            let trimmed = line.trim();
            !trimmed.is_empty() && trimmed.len() > 10
        })
        .take(3)
        .map(|line| line.as_str())
        .collect();

    if meaningful.is_empty() {
        return "unknown approach".to_string();
    }
    meaningful.join(" | ")
}

async fn print_session_summary(iterations: u32, config: &RalphConfig, initial_commit: &str) {
    println!();
    println!("{}", "===============================================");
    println!("  Session ended after {iterations} iterations");
    println!("{}", "===============================================");

    let total_commits = git::count_commits_since(&config.work_dir, initial_commit)
        .await
        .unwrap_or(0);
    println!("   Total commits: {total_commits}");

    if let Some(last_hash) = git::load_last_rebase(&config.last_rebase_file) {
        println!("   Last rebase: {last_hash}");
    }

    logger::log_activity(
        &format!("=== Session ended after {iterations} iterations ==="),
        &config.activity_log,
    );
}
