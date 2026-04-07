use crate::detection::failure_memory::FailureMemory;
use crate::guardrails;
use crate::prd::UserStory;
use std::path::Path;

pub struct PromptBuilder<'a> {
    prompt_file: &'a Path,
    guardrails_file: &'a Path,
    ralph_dir: &'a Path,
    work_dir: &'a Path,
    iteration: u32,
    failure_memory: &'a FailureMemory,
}

impl<'a> PromptBuilder<'a> {
    pub fn new(
        prompt_file: &'a Path,
        guardrails_file: &'a Path,
        ralph_dir: &'a Path,
        work_dir: &'a Path,
        iteration: u32,
        failure_memory: &'a FailureMemory,
    ) -> Self {
        Self {
            prompt_file,
            guardrails_file,
            ralph_dir,
            work_dir,
            iteration,
            failure_memory,
        }
    }

    pub fn build(&self, story: &UserStory, bulk_checkpoint: Option<&str>) -> String {
        let mut prompt = String::with_capacity(8192);

        let base_prompt =
            std::fs::read_to_string(self.prompt_file).unwrap_or_else(|_| {
                format!(
                    "No prompt file found at {}",
                    self.prompt_file.display()
                )
            });
        prompt.push_str(&base_prompt);

        prompt.push_str("\n\n## GUARDRAILS (READ FIRST!)\n\n");
        let guardrails_content = guardrails::read_content(self.guardrails_file);
        prompt.push_str(&guardrails_content);

        if let Some(diversity_section) = self.failure_memory.build_diversity_prompt(&story.id) {
            prompt.push_str(&diversity_section);
        }

        prompt.push_str("\n\n---\n\n");
        prompt.push_str("IMPORTANT: You have full file system access. You can use bash heredoc syntax freely.\n\n");
        prompt.push_str("Next story to implement:\n");

        let story_json =
            serde_json::to_string_pretty(story).unwrap_or_else(|_| format!("{:?}", story));
        prompt.push_str(&story_json);

        prompt.push_str("\n\n---\n");
        prompt.push_str("## DYNAMIC CONTEXT (this section changes per iteration)\n\n");
        prompt.push_str(&format!(
            "RALPH_DIR: {}\n",
            self.ralph_dir.display()
        ));
        prompt.push_str(&format!(
            "WORK_DIR: {}\n",
            self.work_dir.display()
        ));
        prompt.push_str(&format!(
            "Current working directory: {}\n",
            self.work_dir.display()
        ));
        prompt.push_str(&format!(
            "Config directory: {}\n",
            self.ralph_dir.display()
        ));
        prompt.push_str(&format!("ITERATION: {}\n", self.iteration));

        if let Some(checkpoint) = bulk_checkpoint {
            prompt.push_str(checkpoint);
        }

        prompt
    }
}
