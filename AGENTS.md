## codegraph

This project has a codegraph knowledge graph at .codegraph/.

Rules for AI Agents (Antigravity, Claude Code, Codex, etc.):
- Before answering architecture or codebase questions, read .codegraph/README.md for god nodes and community structure.
- Refer to .codegraph/components/ and .codegraph/nodes/ to navigate codebase relationships and definitions instead of reading raw files directly.
- If .codegraph/README.md does not contain AI Architectural Insights, read .codegraph/AGENT_PROMPT.md, perform the deep architectural analysis, and write your report into the `AI 架构深度洞察` section of .codegraph/README.md.
- After modifying code files in this workspace, remind the user to run `codegraph build .` to keep the knowledge graph current.
