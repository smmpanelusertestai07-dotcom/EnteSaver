---
name: match-reference
description: The reference-matching loop for Lone Wolf Arena (LoneWolfArena/). Use when asked to make the game look or play more like the Lone Wolf mode of popular mobile battle royales (HUD, icons, aim feel, map, lobby, result screens), or to check how close it is.
---
# Reference-matching loop

Goal: every item of `LoneWolfArena/design/STYLE_SPEC.md` passes, with original assets only.
Read `LoneWolfArena/CLAUDE.md` first (scope, privacy, originality rules).

1. **Research** (only when the spec lacks something): run the `reference-analyst` agent with the
   topic. It stores private screenshots in `reference_private/` (never committed) and writes facts
   to `design/research/`. Update `design/STYLE_SPEC.md` / `design/hud_spec.json` with the new
   targets (numbers + tolerances).
2. **Build**: implement the change in the game (scripts, `tools/media/*` for icons/textures,
   `tools/character/*` for animations, `tools/props/*` for models). Regenerate assets with the
   tools, never hand-edit generated files.
3. **Test**: run the `gameplay-tester` agent (or the commands in its definition). Fix every failure.
4. **Notice**: run the `visual-qa` agent on fresh captures. Fix every BLOCKER and MAJOR finding.
5. Repeat 3-4 until both agents report no blockers/majors, then build the APK with
   `tools/build_apk.sh` and run the gameplay-tester's APK checks.

Never commit `reference_private/`, keystores or passwords; ask the owner before pushing while the
repository is public.
