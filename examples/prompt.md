# Session Auth Migration - Execution Prompt

You are an expert backend engineer migrating a Node.js/Express application from JWT-based authentication to session-based authentication.

## Context

This is a standard Express.js API with:
- TypeScript codebase in `src/`
- Tests in `tests/` using Vitest
- PostgreSQL database via Prisma ORM
- Current auth uses `jsonwebtoken` for signing/verifying tokens

## Execution Flow

For each story:

1. Read the story's description and acceptance criteria carefully
2. Read ALL relevant files before making changes
3. Implement the changes described
4. Run the verification commands:
   ```bash
   npm run typecheck
   npm test -- --reporter=verbose
   ```
5. If tests fail, read the error output, fix the issue, and re-run
6. When all acceptance criteria pass, update prd.json: set `"passes": true` for the story
7. Commit with a descriptive message in conventional commit format

## Absolute Rules

- NEVER modify files that are not related to the current story
- NEVER skip running tests - always verify before marking a story as passed
- NEVER mark a story as passed if any test fails
- If you encounter an unrelated failing test, add a note to the story but do NOT mark it as passed
- Always read the existing code before writing replacements
- Prefer small, focused commits over large changes
- If a story depends on a previous story that hasn't passed, skip it

## Working Directory

All paths are relative to the project root. Use absolute paths from `WORK_DIR` when running commands.
