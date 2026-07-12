## codegraph

This project has a codegraph knowledge graph at .codegraph/.

Rules for AI Agents (Antigravity, Claude Code, Codex, etc.):
- Before answering architecture or codebase questions, read .codegraph/README.md for god nodes and community structure.
- Refer to .codegraph/components/ and .codegraph/nodes/ to navigate codebase relationships and definitions instead of reading raw files directly.
- If .codegraph/README.md does not contain AI Architectural Insights, read .codegraph/AGENT_PROMPT.md, perform the deep architectural analysis, and write your report into the `AI 架构深度洞察` section of .codegraph/README.md.
- After modifying code files in this workspace, remind the user to run `codegraph build .` to keep the knowledge graph current.

## codegraph-gen

This project maintains a codebase knowledge graph at `.codegraph/`.

### Guidelines for AI Agents (Antigravity, Claude Code, Cursor, Roo Code, etc.)

You MUST follow these rules when working in this codebase:

1. **Prioritize the Knowledge Graph**:
   - Before answering architecture, design, or codebase structure questions, you **MUST** read [.codegraph/README.md](.codegraph/README.md) to understand the system overview, god nodes, and logical community structure.
   - Use [.codegraph/components/](.codegraph/components/) and [.codegraph/nodes/](.codegraph/nodes/) to navigate component boundaries, file relationships, and symbol definitions. This is much faster and more token-efficient than reading raw source files directly.

2. **AI Architectural Insights**:
   - Check [.codegraph/README.md](.codegraph/README.md) for a section titled `AI Architectural Insights`.
   - If this section is missing, incomplete, or contains placeholders, read [.codegraph/AGENT_PROMPT.md](.codegraph/AGENT_PROMPT.md), perform a deep architectural analysis of the project, and write your report into that section. Do not overwrite other sections.

3. **Keep Graph Sync'd**:
   - Whenever you create, delete, or modify code files, you **SHOULD** remind the user to run `codegraph build .` to rebuild the knowledge graph and keep it current.
   - When running the build command, exclude irrelevant or generated directories (e.g., third-party dependencies, build folders, or documentation) using the `-e`/`--exclude` flag to keep the graph focused and clean (e.g., `codegraph build . -e third_party/`).
