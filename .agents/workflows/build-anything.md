# Workflow: /build-anything

## Description
Full research-to-build pipeline. Triggered with `/build-anything` followed by your idea.
Searches for the best free/OSS tools, plans the architecture, and builds a complete working system.

---

## Trigger
```
/build-anything [your idea or goal]
```

Examples:
- `/build-anything a web scraper that monitors price drops`
- `/build-anything an AI chatbot I can self-host for free`
- `/build-anything a workflow that auto-posts to Twitter from RSS`
- `/build-anything a local RAG system over my PDF files`

---

## Steps the Agent Will Execute

### Step 1 — Parse the Goal
- Extract: what to build, who uses it, what it outputs
- Identify: scale, constraints, tech preferences if any
- Confirm understanding in one sentence before proceeding

### Step 2 — Research Phase
The agent will search:
- GitHub awesome lists for relevant tools
- Reddit for real-world community consensus
- HuggingFace and arXiv if AI/ML is involved
- Engineering blogs and changelogs for production-readiness
- Unofficial APIs, wrappers, and self-hosted alternatives

The agent will evaluate and rank options by:
- Cost (free > freemium > paid)
- Maturity (active commits, responsive maintainers)
- Simplicity (least moving parts for the job)
- Reusability (modular, extensible architecture)

### Step 3 — Architecture Plan
The agent will output:
- System diagram or component breakdown
- Tech stack decision with reasoning
- Step-by-step build plan
- Estimated setup time

**Agent will pause here for your approval before building.**

### Step 4 — Build
The agent will:
- Write all code (Python / TypeScript / Bash preferred)
- Create config files, Dockerfiles, .env templates
- Add inline documentation and comments
- Include error handling and logging
- Make it runnable in one command where possible

### Step 5 — Validate
The agent will:
- Walk through the happy path
- Identify and handle failure modes
- Verify the free/OSS path is fully functional
- Output a README with setup instructions

### Step 6 — Deliver
Final output includes:
1. Working code (modular, documented)
2. Setup instructions (step-by-step)
3. Free hosting / deployment path
4. Backup approach if anything breaks
5. List of automation opportunities to extend it

---

## Output Format (agent must follow this)

```
## What We're Building
[One-sentence goal]

## Recommended Stack
[Tools chosen + why]

## Free Path
[Zero-cost implementation]

## Architecture
[Components and how they connect]

## Build Plan
[Numbered steps]

## Code
[Full implementation]

## Setup Instructions
[How to run it]

## Backup Approach
[If primary fails]

## What to Automate Next
[Extension ideas]
```

---

## Guardrails

- Never recommend paid tools without first exhausting free alternatives
- Never write non-modular, undocumented, or one-off code
- Never skip the research phase — always validate tool choices
- Always provide a working fallback option
- Always make the output deployable and repeatable
