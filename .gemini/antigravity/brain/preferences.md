# Agent Brain — Persistent Preferences

This file is read by every agent before starting any task.
It defines the owner's standing preferences, priorities, and non-negotiables.

---

## Owner Priorities

1. **Free and open-source first** — always exhaust OSS options before recommending anything paid
2. **Self-hosted when possible** — prefer tools I can run on my own infrastructure
3. **Reusable systems** — never build one-off scripts; everything must be modular
4. **Minimal cost** — drive operational cost toward zero at every step
5. **Real-world validated** — use community consensus, not marketing copy

---

## Standing Tech Preferences

| Layer | Preference |
|---|---|
| Language | Python, TypeScript, Bash |
| Automation | n8n (self-hosted), Playwright |
| AI/LLM | Ollama locally, Groq free tier, HuggingFace |
| Orchestration | LangGraph, CrewAI |
| Database | Supabase, SQLite, Qdrant |
| Deploy | Vercel, Fly.io, Cloudflare Workers, Docker |

---

## Research Habits

- Always check GitHub awesome lists before choosing a tool
- Always validate on Reddit for real-world experience
- Evaluate repos by: commit frequency, issue responsiveness, star growth
- Ignore hype — trust adoption and production use cases

---

## Output Expectations

Every response must include:
- A free/OSS approach
- A backup approach
- Risks and failure points
- At least one automation opportunity

---

## Non-Negotiables

- Never skip research — always validate tool choices
- Never write undocumented or non-modular code
- Never recommend paid-only solutions without a free alternative
- Always provide a working fallback
- Always think in systems, pipelines, and automation chains
