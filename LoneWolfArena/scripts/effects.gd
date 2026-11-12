class_name Effects
extends RefCounted
## Lightweight visual effects (tracers, impacts, muzzle flashes, explosions).
## Everything is created on demand and frees itself, but the bullet holes: one MultiMesh per scene
## holds them all (one draw call), the oldest overwritten, each cleared after HOLE_LIFE_S.

const MAX_HOLES := 40
const HOLE_LIFE_S := 12.0
const HIDDEN_HOLE := Transform3D(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3(0, -1000, 0))   # an empty slot: no size, far below

static var _mats := {}
static var _meshes := {}
static var _hole_mmi: MultiMeshInstance3D
static var _hole_born := PackedInt64Array()   # tick (ms) each hole was made, -1 when its slot is empty
static var _hole_next := 0
static var _hole_mat: StandardMaterial3D
static var muzzle_tex: Texture2D
static var glow_tex: Texture2D
static var lights_enabled := true
## Share of each burst's particles that are made (they are CPU-simulated), see configure().
static var particle_share := 1.0


## The graphics level and the VISUAL EFFECTS setting (full): lights on muzzle flashes and explosions
## from HIGH up and only with the effects on; particle bursts at half on LOW and at half again with
## the effects off (a burst keeps 2 particles at least, so hits still spark).
static func configure(level: int, full: bool) -> void:
	lights_enabled = level >= 2 and full
	particle_share = (0.5 if level <= 0 else 1.0) * (1.0 if full else 0.5)


static func _mat(color: Color, additive := true, tex: Texture2D = null, billboard := false) -> StandardMaterial3D:
	var key := "%s|%s|%s|%s" % [color.to_html(), additive, tex.resource_path if tex else "", billboard]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if tex:
		m.albedo_texture = tex
	if billboard:
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true
	_mats[key] = m
	return m


static func _box(size: Vector3) -> BoxMesh:
	var key := "box%s" % size
	if not _meshes.has(key):
		var b := BoxMesh.new()
		b.size = size
		_meshes[key] = b
	return _meshes[key]


static func _quad(size: Vector2) -> QuadMesh:
	var key := "quad%s" % size
	if not _meshes.has(key):
		var q := QuadMesh.new()
		q.size = size
		_meshes[key] = q
	return _meshes[key]


static func _scene(node: Node) -> Node:
	if node == null or not node.is_inside_tree():
		return null
	return node.get_tree().current_scene


static func _free_after(node: Node, seconds: float) -> void:
	node.get_tree().create_timer(seconds, false).timeout.connect(node.queue_free)


static func load_textures() -> void:
	if muzzle_tex == null and ResourceLoader.exists("res://assets/textures/muzzle_flash.png"):
		muzzle_tex = load("res://assets/textures/muzzle_flash.png")
	if glow_tex == null and ResourceLoader.exists("res://assets/textures/glow.png"):
		glow_tex = load("res://assets/textures/glow.png")


static func tracer(ctx: Node, from: Vector3, to: Vector3) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	var dist := from.distance_to(to)
	if dist < 0.6:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = _box(Vector3(0.022, 0.022, 1.0))
	mi.material_override = _mat(Color(1.0, 0.82, 0.42, 0.85))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	var dir := (to - from) / dist
	var up := Vector3.UP if absf(dir.y) < 0.98 else Vector3.RIGHT
	var b := Basis.looking_at(dir, up).scaled(Vector3(1, 1, dist * 0.85))
	mi.global_transform = Transform3D(b, from.lerp(to, 0.55))
	_free_after(mi, 0.045)


static func muzzle_flash(ctx: Node, pos: Vector3, dir: Vector3, big := false) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	load_textures()
	var mi := MeshInstance3D.new()
	var s := 0.55 if big else 0.36
	mi.mesh = _quad(Vector2(s, s))
	if muzzle_tex:
		mi.material_override = _mat(Color(1, 0.9, 0.7, 1), true, muzzle_tex, true)
	else:
		mi.material_override = _mat(Color(1.0, 0.75, 0.3, 0.9), true, null, true)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.global_position = pos + dir * 0.08
	mi.rotate_object_local(Vector3.FORWARD, randf() * TAU)
	_free_after(mi, 0.05)
	if lights_enabled:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.75, 0.4)
		l.light_energy = 2.2 if big else 1.4
		l.omni_range = 4.0
		l.shadow_enabled = false
		parent.add_child(l)
		l.global_position = pos
		_free_after(l, 0.05)


static func _burst(parent: Node, pos: Vector3, normal: Vector3, color: Color, amount: int, speed: float, size: float, life: float, gravity := -9.0) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = maxi(roundi(amount * particle_share), 2)
	p.lifetime = life
	p.local_coords = false
	p.mesh = _box(Vector3(size, size, size * 3.0))
	p.material_override = _mat(color)
	p.direction = normal
	p.spread = 55.0
	p.initial_velocity_min = speed * 0.5
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, gravity, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	p.particle_flag_align_y = true
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	_free_after(p, life + 0.2)


static func impact(ctx: Node, pos: Vector3, normal: Vector3) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	_burst(parent, pos + normal * 0.02, normal, Color(1.0, 0.75, 0.35, 1), 7, 5.0, 0.025, 0.22)
	_burst(parent, pos + normal * 0.05, normal, Color(0.55, 0.52, 0.48, 0.55), 4, 1.2, 0.09, 0.45, 0.5)
	var up := Vector3.UP if absf(normal.y) < 0.95 else Vector3.RIGHT
	var mm := _hole_layer(parent).multimesh
	mm.set_instance_transform(_hole_next, Transform3D(Basis.looking_at(-normal, up), pos + normal * 0.012))
	_hole_born[_hole_next] = Time.get_ticks_msec()
	_hole_next = (_hole_next + 1) % MAX_HOLES


## Every bullet hole of the scene is an instance of one MultiMesh (one draw call, not one each): a
## ring of MAX_HOLES, the oldest overwritten; a hole goes after HOLE_LIFE_S (a timer clears it).
static func _hole_layer(parent: Node) -> MultiMeshInstance3D:
	if is_instance_valid(_hole_mmi) and _hole_mmi.get_parent() == parent:
		return _hole_mmi
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _quad(Vector2(0.07, 0.07))
	mm.instance_count = MAX_HOLES
	_hole_mmi = MultiMeshInstance3D.new()
	_hole_mmi.name = "BulletHoles"
	_hole_mmi.multimesh = mm
	_hole_mmi.material_override = _hole_material()
	_hole_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(_hole_mmi)
	_hole_born.resize(MAX_HOLES)
	_hole_born.fill(-1)
	_hole_next = 0
	for i in MAX_HOLES:
		mm.set_instance_transform(i, HIDDEN_HOLE)
	var t := Timer.new()
	t.wait_time = 1.0
	t.autostart = true
	t.timeout.connect(_clear_old_holes)
	_hole_mmi.add_child(t)
	return _hole_mmi


static func _clear_old_holes() -> void:
	if not is_instance_valid(_hole_mmi):
		return
	var now := Time.get_ticks_msec()
	for i in _hole_born.size():
		if _hole_born[i] >= 0 and now - _hole_born[i] > int(HOLE_LIFE_S * 1000.0):
			_hole_born[i] = -1
			_hole_mmi.multimesh.set_instance_transform(i, HIDDEN_HOLE)


## The bullet holes showing now (tests, the draw-call budget sweep).
static func hole_count() -> int:
	var n := 0
	if is_instance_valid(_hole_mmi):
		for b in _hole_born:
			n += 1 if b >= 0 else 0
	return n


## Bullet hole: a dark round core with a soft edge and a faint chipped rim, lit like the surface
## it sits on (texture drawn once).
static func _hole_material() -> StandardMaterial3D:
	if _hole_mat != null:
		return _hole_mat
	var n := 64
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var r := Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			var c := Color(0.03, 0.028, 0.025).lerp(Color(0.34, 0.31, 0.27), clampf((r - 0.3) / 0.25, 0.0, 1.0))
			c.a = maxf((1.0 - smoothstep(0.26, 0.4, r)) * 0.95, (1.0 - smoothstep(0.4, 0.95, r)) * 0.35)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = ImageTexture.create_from_image(img)
	m.roughness = 1.0
	_hole_mat = m
	return m


static func hit_spark(ctx: Node, pos: Vector3, normal: Vector3, headshot: bool) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	var c := Color(1.0, 0.25, 0.2, 1) if not headshot else Color(1.0, 0.9, 0.3, 1)
	_burst(parent, pos, normal, c, 10 if headshot else 6, 3.5, 0.03, 0.25)


static func shield_hit(ctx: Node, pos: Vector3, normal: Vector3) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	_burst(parent, pos, normal, Color(0.4, 0.95, 1.0, 1), 8, 3.0, 0.03, 0.3, -2.0)


static func shield_break(ctx: Node, pos: Vector3) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	_burst(parent, pos + Vector3.UP, Vector3.UP, Color(0.78, 0.93, 1.0, 1), 46, 6.5, 0.07, 0.9)
	_burst(parent, pos + Vector3.UP * 0.8, Vector3.UP, Color(0.85, 0.95, 1.0, 0.3), 14, 1.6, 0.4, 1.0, 0.4)


## A fighter eliminated (on every phone, whoever it is): "ELIMINATED" floats up over the body for
## ELIMINATED_S and fades, over a short burst of yellow and orange shards and a white puff (the
## game's colours; the bursts follow particle_share like every other).
const ELIMINATED_S := 2.0


static func eliminated(ctx: Node, pos: Vector3) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	_burst(parent, pos + Vector3.UP * 1.0, Vector3.UP, Color(1.0, 0.76, 0.055, 1), 18, 4.5, 0.06, 0.8, -6.0)
	_burst(parent, pos + Vector3.UP * 1.1, Vector3.UP, Color(0.875, 0.447, 0.216, 1), 12, 3.5, 0.05, 0.7, -6.0)
	_burst(parent, pos + Vector3.UP * 0.9, Vector3.UP, Color(1, 1, 1, 0.28), 6, 1.2, 0.35, 0.8, 0.5)
	var l := Label3D.new()
	l.name = "EliminatedTag"
	l.text = "ELIMINATED"
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0009
	l.font_size = 40
	l.outline_size = 12
	l.modulate = Color(1.0, 0.86, 0.3)
	l.outline_modulate = Color(0.12, 0.05, 0.02, 0.9)
	l.font = UI.font("italic")
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(l)
	l.global_position = pos + Vector3.UP * 1.7
	l.scale = Vector3.ONE * 0.6
	var tw := l.create_tween()
	tw.tween_property(l, "scale", Vector3.ONE * 1.1, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(l, "scale", Vector3.ONE, 0.1)
	tw.parallel().tween_property(l, "global_position:y", pos.y + 2.15, ELIMINATED_S - 0.1)
	tw.parallel().tween_property(l, "modulate:a", 0.0, 0.5).set_delay(ELIMINATED_S - 0.6)
	tw.parallel().tween_property(l, "outline_modulate:a", 0.0, 0.5).set_delay(ELIMINATED_S - 0.6)
	_free_after(l, ELIMINATED_S + 0.1)


## A wall forming: frozen foam bursts up along its base, with a puff of cold mist.
static func shield_form(ctx: Node, xf: Transform3D) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	for k in 3:
		_burst(parent, xf * Vector3((k - 1) * 1.1, 0.15, 0.15), Vector3.UP, Color(0.85, 0.95, 1.0, 0.9), 10, 4.0, 0.07, 0.45)
	_burst(parent, xf * Vector3(0, 0.8, 0.3), xf.basis.z, Color(0.8, 0.92, 1.0, 0.3), 12, 1.5, 0.35, 0.9, 0.5)


static func explosion(ctx: Node, pos: Vector3) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	_burst(parent, pos, Vector3.UP, Color(1.0, 0.6, 0.15, 1), 40, 11.0, 0.12, 0.55, -4.0)
	_burst(parent, pos, Vector3.UP, Color(1.0, 0.85, 0.4, 1), 20, 6.0, 0.25, 0.3, 0.0)
	_burst(parent, pos + Vector3.UP * 0.3, Vector3.UP, Color(0.25, 0.23, 0.22, 0.6), 18, 2.5, 0.6, 1.6, 1.0)
	var ball := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	ball.mesh = sm
	ball.material_override = _mat(Color(1.0, 0.7, 0.3, 0.7))
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(ball)
	ball.global_position = pos
	var tw := ball.create_tween()
	tw.tween_property(ball, "scale", Vector3.ONE * 7.0, 0.25)
	tw.parallel().tween_property(ball, "transparency", 1.0, 0.25)
	tw.tween_callback(ball.queue_free)
	if lights_enabled:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.65, 0.3)
		l.light_energy = 6.0
		l.omni_range = 12.0
		parent.add_child(l)
		l.global_position = pos + Vector3.UP
		var tl := l.create_tween()
		tl.tween_property(l, "light_energy", 0.0, 0.4)
		tl.tween_callback(l.queue_free)


## Spawns every effect once far below the floor and shows them to a tiny camera of their own, so
## their shaders compile during the prep phase instead of stuttering on the first shot or
## explosion. They sit on the actors' visual layer, which the minimap's top-down render skips.
static func warm_up(ctx: Node) -> void:
	load_textures()
	var parent := _scene(ctx)
	if parent == null:
		return
	var first := parent.get_child_count()
	var p := Vector3(0, -50, 0)
	tracer(ctx, p, p + Vector3(0, 0, -5))
	muzzle_flash(ctx, p, Vector3.FORWARD, false)
	muzzle_flash(ctx, p, Vector3.FORWARD, true)
	impact(ctx, p, Vector3.UP)
	hit_spark(ctx, p, Vector3.UP, false)
	hit_spark(ctx, p, Vector3.UP, true)
	shield_hit(ctx, p, Vector3.UP)
	shield_break(ctx, p)
	shield_form(ctx, Transform3D(Basis(), p))
	explosion(ctx, p)
	var wall := ShieldWall.warm_up_node()
	parent.add_child(wall)
	wall.global_position = p
	_free_after(wall, 0.6)
	for i in range(first, parent.get_child_count()):
		_set_layers(parent.get_child(i), CharacterModel.LAYER_ACTORS)
	var vp := SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(vp)
	var cam := Camera3D.new()
	cam.cull_mask = CharacterModel.LAYER_ACTORS
	vp.add_child(cam)
	cam.look_at_from_position(p + Vector3(0, 1.0, 6.0), p)
	cam.current = true
	_free_after(vp, 0.6)


static func _set_layers(node: Node, layers: int) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = layers
	for c in node.get_children():
		_set_layers(c, layers)
