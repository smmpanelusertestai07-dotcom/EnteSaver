# Interfaces between the game's parts (keep these stable)

Owners: `arena.gd`, `fighter.gd`, `player.gd`, `bot.gd`, `weapons.gd`, `character_model.gd` are the
gameplay core. HUD, map and menus are separate files that talk to the core only through what is
listed here. If a part needs something new from the core, add it in its own file or note it.

## Arena (scripts/arena.gd) -> read by HUD / menus
- `phase` (Phase.PREP=0, FIGHT=1, END=2), `prep_left` (s), `time_left` (s), `elapsed` (s),
  `round_index`, `rounds_to_win`, `score` {"player": int, "bot": int}, `picked_weapon` (id)
- zone: `zone_state` ("stationary" | "shrinking" | "closed"), `zone_next()` (s until it
  changes), `zone_radius`, `zone_center` (Vector3), `in_zone(pos)`, `zone_warning` (text or "")
- `fighters` (Array[Fighter]), `player`, `bot`, `map_name` ("CARGO CAGE"), `map_rect` (Rect2,
  world X/Z area of the minimap), `minimap_texture` (Texture2D rendered once from above, may be
  null for the first frames), `obstacles` (Array[Rect2] footprints, X/Z)
- `scoreboard_rows()` -> [{name, me, alive, hp, kills, damage, headshots, accuracy, rounds, weapon}]
- `open_pause()`; the HUD emits `pause_pressed` for it.

## Arena -> HUD calls (scripts/hud.gd must implement all of these)
- `bind(player: Player, arena: Node)`, `reload_layout()`, `release_all()`
- `show_center(text, seconds, color := Color.WHITE, size := 96, sub := "")`
- `show_round_banner(round_index: int, area: String)`  (blue->orange band "ROUND 1 / AREA: ...")
- `open_weapon_pick(options: Array[String] weapon ids, preselect: String, seconds: float, on_pick: Callable(id))`
  must call `on_pick` exactly once (tap SELECT, or the timer runs out -> current choice);
  `close_weapon_pick()` closes it without a callback.
- `add_kill_feed(killer: String, victim: String, weapon_name: String, weapon_icon: String, headshot: bool, mine: bool)`
- `kill_banner(victim_name: String, headshot: bool)` (big elimination feedback when the player kills)
- `reveal(f: Fighter, seconds)` (enemy shows on the minimap), `match_over: bool`, `tips_time: float`
- `editor_mode`, `selected_id`, `layout` (used by the HUD editor)

## Player (scripts/player.gd) -> called by the HUD's touch controls
- movement `move_dir: Vector2` (joystick, length 0..1, y forward), `set_sprint(on)`
- `add_look(rel_px: Vector2, from_fire_button: bool)`, `set_firing(on)`, `toggle_ads()`,
  `do_jump()`, `toggle_crouch()`, `toggle_prone()`, `do_reload()`, `select_weapon(i)` (0 gun, 1 fists),
  `use_medkit()`, `use_shield()`, `use_grenade()`
- state: `hp` (0..Fighter.MAX_HP=200), `alive`, `weapons[i]` (WeaponState: `def`, `ammo`,
  `reserve`, `reloading`, `reload_progress()`, `infinite()`), `current`, `stance`
  (Fighter.Stance.STAND/CROUCH/PRONE), `sprinting`, `ads`, `is_scoped()`, `scope_type()`
  ("reddot" | "sniper" | "none"), `healing`, `heal_progress()`, `medkits`, `shields`,
  `grenades`, `crosshair_on_target` (crosshair turns red), `current_spread()` (deg),
  `camera`, `firing`, `assist_target`, `hold_fire` (prep: cannot shoot)
- signals: `hit_landed(target, amount, headshot, pos, killed)`, `damaged(amount, from_pos, headshot, attacker)`
- `Fighter.helmet_reduction` / `vest_reduction` (Lv2 armour; show level 2 icons)

## Weapons (scripts/weapons.gd)
- `Weapons.DEFS[id]` with `name`, `class` (AR/SMG/SG/PISTOL/SNIPER/MELEE), `icon` (texture name in
  res://assets/ui/icons/, e.g. "weapon_ar"; missing icons fall back to the AR), `mag`, `reserve`,
  `crosshair` ("ring" | "wide" | "dot"), `scope`, `auto`. `Weapons.PICKABLE` = pick-grid order.

## Map (scripts/map_builder.gd) -> used by arena.gd
- `build(parent: Node3D)` creates the environment (`env: WorldEnvironment`, `sun: DirectionalLight3D`),
  geometry, colliders (layer Fighter.LAYER_WORLD), the navigation region `nav` (baked by arena),
  `obstacles` (Array[Rect2] X/Z footprints for the minimap/AI), `cover_points` (Array[Vector3])
- `spawn_a`, `spawn_a_yaw` (player), `spawn_b`, `spawn_b_yaw` (bot); `map_name`; `map_rect`;
  `zone_center`; `zone_start_radius`
- `set_barriers(on: bool)` red spawn barriers (colliders + glow) during PREP
- `apply_quality(g: int)` 0 SMOOTH .. 3 MAX
- Roof, ceiling, trusses and hanging lamps must use visual layer 2 (`layers = 2`) so the
  top-down minimap render (camera cull_mask 1) sees the floor plan; everything else layer 1.

## Menus
- `ResultsScreen.new()` (Control): `setup(result: Dictionary)` - keys: won, draw, invalid, kills,
  damage, headshots, accuracy, time, xp, enemy, mode, map, weapon, score_player, score_bot,
  hp_left, difficulty, taken. Buttons: PLAY AGAIN (`Game.goto_arena`), LOBBY (`Game.goto_lobby`).
- `PauseMenu.new()` (Control, works while paused): signal `closed`.
- `SettingsPanel.new()` (Control): signal `closed`; writes `Game.settings` keys listed in
  `autoload/game.gd` DEFAULT_SETTINGS and calls `Game.save_settings()` on close.
- Scene flow: `Game.goto_lobby()`, `Game.goto_arena()`, `Game.goto_hud_editor()`.
- Every button that the screenshot walkthrough (scripts/autotest.gd) uses keeps its node name:
  `StartButton`, `SettingsButton`, `BundlesButton`, `Bundle_<id>`, `EquipButton`, `PlayAgain`,
  `Lobby`, `Close`, `SaveButton`.
