# SKILL: Research & Build Anything

## Description
Use this skill when the user wants to build, automate, research, or create any system, tool, workflow, or product. This skill guides the agent through a structured research-first, build-second pipeline optimized for free, open-source, and reusable output.

---

## When to Activate

Activate when the user says things like:
- "build me...", "make me...", "create a...", "I want a system that..."
- "find the best tool for...", "what's the open-source alternative to..."
- "automate...", "set up a workflow for...", "how do I self-host..."
- "research...", "compare...", "what should I use for..."

---

## Execution Pipeline

### Phase 1 — Understand
- Clarify the goal in one sentence
- Identify: inputs, outputs, constraints, scale requirements
- Identify: what already exists vs what needs to be built

### Phase 2 — Research
Search in this order:
1. GitHub `awesome <topic>` lists
2. Reddit: `best open source <topic>`, `free alternative to <tool>`
3. HuggingFace, arXiv, engineering blogs
4. Community forums, Discord, issue discussions
5. Benchmarks and real-world comparisons

Evaluate tools by:
- Stars growth trajectory (not just total stars)
- Commit frequency (active = trustworthy)
- Issue quality (responsive maintainers)
- Real-world adoption (production use cases)
- Modularity and extensibility

### Phase 3 — Plan
Break the goal into agent roles:
- **Planner** — defines the architecture and steps
- **Researcher** — finds the right tools and APIs
- **Builder** — writes and assembles the code
- **Validator** — tests and verifies output
- **Optimizer** — reduces cost, improves performance

Output a clear step-by-step plan before writing any code.

### Phase 4 — Build
- Write modular, documented, fault-tolerant code
- Use preferred stack (Python / TypeScript / Bash)
- Containerize with Docker when relevant
- Include logging and error handling
- Make every component independently reusable

### Phase 5 — Validate
- Test the happy path
- Test edge cases and failure modes
- Verify the free/OSS path works end-to-end
- Document what was built and how to run it

### Phase 6 — Optimize
- Identify what can be automated further
- Identify where costs can be reduced to zero
- Suggest next improvements or extensions

---

## Free Resource Toolkit

Always pull from:
- **Compute:** Colab, Kaggle, HuggingFace Spaces, Paperspace free
- **Hosting:** Vercel, Netlify, Cloudflare Pages, Fly.io, Render
- **DB/Storage:** Supabase, Firebase, Neon, Turso, PlanetScale free tiers
- **AI Inference:** HuggingFace, Groq free tier, Together AI, Ollama local
- **Automation:** n8n self-hosted, Playwright, Puppeteer
- **Data:** Common Crawl, Wikipedia dumps, arXiv, public APIs

---

## Output Template

```
## Goal
[One-sentence summary of what we're building]

## Recommended Approach
[Best balance of speed, cost, reliability]

## Free/OSS Approach
[Zero-cost path with specific tools]

## Fastest Approach
[If speed is the constraint]

## Backup Approach
[If primary fails]

## Risks & Failure Points
[What to watch out for]

## Automation Opportunities
[What can run hands-free]

## Implementation
[Code, configs, commands]
```
