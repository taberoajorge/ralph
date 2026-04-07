use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Prd {
    pub project: String,
    pub feature: String,
    pub working_directory: String,
    #[serde(default)]
    pub branch_name: Option<String>,
    pub user_stories: Vec<UserStory>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserStory {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub acceptance_criteria: Vec<String>,
    #[serde(default)]
    pub passes: bool,
    #[serde(default)]
    pub blocked: bool,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub priority: Option<u32>,
}

impl Prd {
    pub fn load(path: &Path) -> Result<Self> {
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("Failed to read PRD: {}", path.display()))?;
        let prd: Prd = serde_json::from_str(&content)
            .with_context(|| format!("Failed to parse PRD JSON: {}", path.display()))?;
        Ok(prd)
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        let content = serde_json::to_string_pretty(self)
            .context("Failed to serialize PRD to JSON")?;
        std::fs::write(path, content)
            .with_context(|| format!("Failed to write PRD: {}", path.display()))?;
        Ok(())
    }

    pub fn total_stories(&self) -> usize {
        self.user_stories.len()
    }

    pub fn passed_count(&self) -> usize {
        self.user_stories.iter().filter(|story| story.passes).count()
    }

    pub fn blocked_count(&self) -> usize {
        self.user_stories.iter().filter(|story| story.blocked).count()
    }

    pub fn pending_count(&self) -> usize {
        self.total_stories() - self.passed_count() - self.blocked_count()
    }

    pub fn next_actionable_story(&self) -> Option<&UserStory> {
        self.user_stories
            .iter()
            .find(|story| !story.passes && !story.blocked)
    }

    pub fn mark_story_passed(&mut self, story_id: &str) -> bool {
        if let Some(story) = self.user_stories.iter_mut().find(|story| story.id == story_id) {
            story.passes = true;
            return true;
        }
        false
    }

    pub fn is_valid_json(path: &Path) -> bool {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|content| serde_json::from_str::<Prd>(&content).ok())
            .is_some()
    }
}
