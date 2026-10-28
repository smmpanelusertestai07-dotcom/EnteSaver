# Lone Wolf Arena: rules for anyone (human or AI) working here

This folder is a self-contained Godot 4.7.2 game. The rest of the repository is a different
app (Ente Saver) and must not be touched for game work.

## Scope
- Edit only files under `LoneWolfArena/`. The one exception is the game's own CI workflow,
  `.github/workflows/lonewolf-arena.yml`. Never edit `app/`, Gradle files or other workflows.

## Privacy and safety (owner's standing instruction)
- Develop privately: no personal data in web searches, no uploading code, assets, logs or chat
  content to any third-party service (pastebins, online converters, AI tools, file hosts).
- The GitHub repository is PUBLIC (checked 2026-10-28). Do not push without the owner's OK
  until it is made private; never commit signing keys, passwords or `export_credentials.cfg`.
- Reference screenshots of other games are for private analysis only: keep them outside the
  repo (or in a git-ignored `reference_private/` folder) and never ship or commit them.
- The game must stay offline: no INTERNET permission, no ads/analytics SDKs, no downloads at
  runtime. Everything ships inside the APK.

## Originality (legal)
- The game should FEEL like popular mobile battle-royale "Lone Wolf" modes (layout, flow,
  controls, pacing), but every asset, icon, name and logo must be original. Do not use any
  Garena/Free Fire names, logos, characters, bundles, icons, sounds or ripped assets, and do
  not use trademarked phrases such as "Booyah" or "Gloo Wall".

## Build and test
```bash
godot --headless --path . --import                       # first time / after asset changes
godot --headless --path . res://tests/check.tscn         # every script compiles
godot --headless --path . res://tests/run_tests.tscn     # unit tests
tools/qa/soak.sh 5                                        # 5 full headless matches, no script errors
tools/qa/capture.sh /tmp/shots 1560x720 screens           # screenshot walkthrough (Xvfb + llvmpipe)
python3 tools/qa/compare.py /tmp/shots_old /tmp/shots /tmp/cmp   # screen-by-screen diff
tools/build_apk.sh                                        # signed release APK (see script header)
```

## Reference-matching loop (agents)
See `.claude/skills/match-reference/SKILL.md`: research -> spec (`design/`) -> build ->
capture -> compare against the spec and private references -> fix, until every checklist item
in `design/STYLE_SPEC.md` passes.
