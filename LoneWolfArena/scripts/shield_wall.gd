class_name ShieldWall
extends StaticBody3D
## Deployable energy wall: blocks bullets, movement and line of sight until broken or expired.

const MAX_HP := 600.0
const LIFETIME := 45.0
const SIZE := Vector3(3.5, 2.0, 0.4)
const MODEL := "res://assets/props/shield_wall.glb"

var hp := MAX_HP
var _life := LIFETIME
var _visual: Node3D
var _glass_mats: Array[StandardMaterial3D] = []
var _flash := 0.0
static var _hex_tex: Texture2D


func _ready() -> void:
	collision_layer = Fighter.LAYER_SHIELD
	collision_mask = 0
	add_to_group("shield_walls")
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = SIZE
	cs.shape = box
	cs.position.y = 1.0
	add_child(cs)
	if _hex_tex == null and ResourceLoader.exists("res://assets/textures/hex_pattern.png"):
		_hex_tex = load("res://assets/textures/hex_pattern.png")
	_visual = Node3D.new()
	add_child(_visual)
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.45, 0.9, 1.0, 0.42)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.emission_enabled = true
	glass.emission = Color(0.2, 0.75, 1.0)
	glass.emission_energy_multiplier = 0.9
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	glass.roughness = 0.15
	if _hex_tex:
		glass.emission_texture = _hex_tex
		glass.uv1_triplanar = true
		glass.uv1_scale = Vector3(1.2, 1.2, 1.2)
	_glass_mats.append(glass)
	var used_model := false
	if ResourceLoader.exists(MODEL):
		var inst: Node3D = (load(MODEL) as PackedScene).instantiate()
		_visual.add_child(inst)
		used_model = true
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			for s in m.mesh.get_surface_count():
				var mat := m.get_active_material(s)
				if mat and mat.resource_name.to_lower().contains("glass"):
					m.set_surface_override_material(s, glass)
	if not used_model:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(SIZE.x, SIZE.y, 0.12)
		mi.mesh = bm
		mi.position.y = 1.0
		mi.material_override = glass
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_visual.add_child(mi)
	# The modelled wall is 2.4 m wide; stretch it to the wall's real width.
	var final_scale := Vector3(SIZE.x / 2.4, 1, 1) if used_model else Vector3.ONE
	_visual.scale = Vector3(final_scale.x, 0.05, 1)
	create_tween().tween_property(_visual, "scale", final_scale, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	Audio.play_at("shield_deploy", global_position, 0.0)


func take_bullet(damage: float, _from: Fighter = null) -> void:
	hp -= damage
	_flash = 1.0
	if hp <= 0.0:
		_break()


func take_explosion(damage: float) -> void:
	take_bullet(damage)


func _break() -> void:
	if is_queued_for_deletion():
		return
	Effects.shield_break(self, global_position)
	Audio.play_at("shield_break", global_position, 0.0)
	queue_free()


func _process(delta: float) -> void:
	_life -= delta
	_flash = maxf(_flash - delta * 5.0, 0.0)
	var fade := clampf(_life / 2.0, 0.0, 1.0)
	for m in _glass_mats:
		m.albedo_color.a = (0.38 + 0.3 * _flash) * fade
		m.emission_energy_multiplier = (0.8 + 2.0 * _flash) * fade
	if _life <= 0.0:
		queue_free()
