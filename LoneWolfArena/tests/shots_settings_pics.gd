extends Node
## Makes the settings' pictures (SettingsPanel.PIC_DIR, assets/ui/settings/) from our own arena
## and HUD, at 1280x720 (SettingsPanel.SPOTS are fractions of a 16:9 picture):
##   tools/qa/capture.sh <out_dir> 1280x720 script:res://tests/shots_settings_pics.gd
## then `godot --headless --path . --import`. Writes:
##  - hud.png / hud_eye.png (455x256): a fight in TRAINING GROUND seen from behind, the default HUD
##    (hud_eye.png with the free look button on), the bot ahead;
##  - map_turn.png / map_north.png (128x128): the minimap turned with the view and north up;
##  - gfx_0.png .. gfx_3.png (256x144): the same view without the HUD at LOW .. EXTREME.
## It prints the HUD widgets' places in the picture (SPOTS) for settings_panel.gd.
## Returns 0, or 1 if a picture could not be made.

const PIC_H := 256


func run(at: Node) -> int:
	if DisplayServer.get_name() == "headless":
		return 0              # no renderer, no pictures
	var dir := ProjectSettings.globalize_path(SettingsPanel.PIC_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var saved := Game.settings.duplicate(true)
	Game.settings.difficulty = 0
	Game.settings.graphics_auto = false
	Game.settings.graphics = 2
	Game.settings.freelook_button = false
	Game.settings.minimap_turns = true
	Game.settings.reload_on_crosshair = true
	Game.apply_settings()
	await at.wait(1.5)
	Game.goto_arena()
	await at.wait(1.0)
	var arena: Node = at.get_tree().current_scene
	var hud: HUD = arena.get("hud")
	var p: Player = arena.get("player")
	var b: Bot = arena.get("bot")
	arena.set("prep_left", 40.0)
	await at.wait(0.3)
	arena.call("_apply_pick", "ar")
	await at.wait(0.3)
	arena.set("prep_left", 0.5)
	await at.wait_for_phase(arena, 1)
	b.frozen = true
	var t := 0.0
	while float(hud._round_banner.t) > 0.0 and t < 10.0:
		await at.wait(0.2)
		t += 0.2
	# The bot ahead, a little to the right of the crosshair.
	var fwd := -p.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	p.global_position = arena.call("closest_nav_point", p.global_position + fwd * 4.0)
	await at.wait(0.2)
	var seen := false
	for dist in [10.0, 12.0, 8.0, 14.0]:
		for ang in [-0.25, 0.25, -0.4, 0.4, 0.0]:
			if seen:
				break
			b.global_position = arena.call("closest_nav_point", p.global_position + fwd.rotated(Vector3.UP, ang) * dist)
			await at.wait(0.12)
			seen = p.can_see(b.chest_position()) and p.can_see(b.head_position())
	await at.wait(1.0)
	if hud.panels.pick_open:
		hud.panels.close_pick()
	await at.wait(0.3)
	var vs: Vector2 = hud.size
	var lay := HudLayout.current()
	var spots := {}
	for id: String in ["fire_r", "fire_l", "scope", "freelook", "reload", "swap", "sprint", "joystick"]:
		var c := HudLayout.center(lay[id], vs) / vs
		spots[id] = {"x": snappedf(c.x, 0.001), "y": snappedf(c.y, 0.001), "r": snappedf(HudLayout.radius(lay[id], vs) / vs.y, 0.001)}
	at.log_line("SPOTS %s" % JSON.stringify(spots))
	var ok := true
	ok = await _save(at, dir + "hud.png", Vector2i(roundi(PIC_H * vs.x / vs.y), PIC_H)) and ok
	Game.settings.freelook_button = true
	await at.wait(0.4)
	ok = await _save(at, dir + "hud_eye.png", Vector2i(roundi(PIC_H * vs.x / vs.y), PIC_H)) and ok
	Game.settings.freelook_button = false
	# The minimap: turned a little so that TURNS WITH VIEW and NORTH UP differ.
	p.rotate_y(0.9)
	await at.wait(0.5)
	var mm := HudLayout.minimap_rect(lay.minimap, vs)
	ok = await _save(at, dir + "map_turn.png", Vector2i(128, 128), mm) and ok
	Game.settings.minimap_turns = false
	await at.wait(0.4)
	ok = await _save(at, dir + "map_north.png", Vector2i(128, 128), mm) and ok
	Game.settings.minimap_turns = true
	p.rotate_y(-0.9)
	# The arena at each graphics level, without the HUD.
	hud.visible = false
	for level in Game.GRAPHICS_NAMES.size():
		Game.settings.graphics = level
		Game.apply_settings()
		Game.settings_changed.emit()
		await at.wait(1.0)
		ok = await _save(at, dir + "gfx_%d.png" % level, Vector2i(256, 144)) and ok
	hud.visible = true
	Game.settings = saved
	Game.apply_settings()
	at.log_line("SETTINGS PICS ok=%s" % ok)
	return 0 if ok else 1


## Saves the screen (or `region` of it, canvas pixels) scaled to `px`.
func _save(at: Node, path: String, px: Vector2i, region := Rect2()) -> bool:
	await RenderingServer.frame_post_draw
	var img := at.get_viewport().get_texture().get_image()
	if region.size != Vector2.ZERO:
		var k := float(img.get_width()) / at.get_viewport().get_visible_rect().size.x
		var r := Rect2i(Vector2i(region.position * k), Vector2i(region.size * k))
		img = img.get_region(r)
	img.convert(Image.FORMAT_RGB8)
	img.resize(px.x, px.y, Image.INTERPOLATE_LANCZOS)
	var err := img.save_png(path)
	at.log_line("saved %s (%s)" % [path, error_string(err)])
	return err == OK
