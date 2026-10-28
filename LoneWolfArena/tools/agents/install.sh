#!/usr/bin/env bash
# Links the files Claude Code reads to their plain-text sources in tools/agents/:
#   CLAUDE.md                               -> tools/agents/CLAUDE.txt
#   .claude/agents/<name>.md                -> tools/agents/agents/<name>.txt
#   .claude/skills/<skill>/SKILL.md         -> tools/agents/skills/<skill>/SKILL.txt
# The links are git-ignored: the repository carries no .md files (see CLAUDE.txt). Edit the
# .txt sources; the links follow. Safe to run again.
set -euo pipefail
cd "$(dirname "$0")/../.."
ln -sfn tools/agents/CLAUDE.txt CLAUDE.md
mkdir -p .claude/agents
for src in tools/agents/agents/*.txt; do
  name="$(basename "$src" .txt)"
  ln -sfn "../../$src" ".claude/agents/$name.md"
done
for src in tools/agents/skills/*/SKILL.txt; do
  skill="$(basename "$(dirname "$src")")"
  mkdir -p ".claude/skills/$skill"
  ln -sfn "../../../$src" ".claude/skills/$skill/SKILL.md"
done
echo "linked: CLAUDE.md, $(ls .claude/agents | wc -l) agents, $(ls .claude/skills | wc -l) skill(s)"
