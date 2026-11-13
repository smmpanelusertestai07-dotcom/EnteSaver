class_name LobbyPlate
extends Control
## A small name plate under a character on the lobby's podium (the group lobby): a dark chamfered
## box with the level square, a yellow flag for the group's leader, the name (18 px heavy) and, on
## this player's own plate in a group, a leave glyph at its right end (a tap asks EXIT GROUP / DISBAND
## GROUP: LobbyTeam's own confirm). It is a 2D control on the lobby's UI layer, placed every frame
## where the character's feet are on screen (`anchor`: a point under the model, unprojected by the
## lobby's camera), so it stays small and sharp at every screen size and never floats over the
## skyline. The hero's plate sits just above the voice pill (VoiceButtons.lobby_pill), a member's at
## its shins. Hidden while the wardrobe, PROFILE, SETTINGS or a popup is open (not the team-size box), and while its
## character is off screen. Node names: HeroPlate, MemberPlate_<n>, PlateLeave (the leave glyph's
## rect is `leave_rect()`).

const SIZE := Vector2(172, 30)
const LIFT := 0.12                 # the point unprojected: this high over the anchor (model units)
const HERO_RISE := 22.0 + 4.0 + 15.0   # the hero's plate: half the voice pill + a gap + half a plate higher
const LEAVE_W := 30.0

var lobby: Node                    # the Lobby (camera, wardrobe, dialogs, profile_ui, team)
var anchor: Node3D                 # the character the plate follows
var hero := false                  # this player's own plate (above the voice pill)
var player_name := ""
var level := 0
var leader := false
var can_leave := false             # this player's plate in a group: the leave glyph


static func make(l: Node, follow: Node3D, own: bool) -> LobbyPlate:
	var p := LobbyPlate.new()
	p.lobby = l
	p.anchor = follow
	p.hero = own
	p.size = SIZE
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


## What the plate shows; redrawn only when something changed.
func show_member(n: String, lv: int, is_leader: bool, leave: bool) -> void:
	if n == player_name and lv == level and is_leader == leader and leave == can_leave:
		return
	player_name = n
	level = lv
	leader = is_leader
	can_leave = leave
	mouse_filter = Control.MOUSE_FILTER_STOP if leave else Control.MOUSE_FILTER_IGNORE
	queue_redraw()


## The leave glyph's place on the plate (local coordinates).
func leave_rect() -> Rect2:
	return Rect2(SIZE.x - LEAVE_W, 0.0, LEAVE_W, SIZE.y)


## Whether the lobby has a window open over the podium (the plates step aside).
static func covered(l: Node) -> bool:
	if l == null:
		return true
	if l.get("wardrobe") != null:
		return true
	var prof: Variant = l.get("profile_ui")
	if prof != null and (prof as Object).get("layer") != null:
		return true
	var dialogs: Variant = l.get("dialogs")
	if dialogs != null and (dialogs as Object).get("modal") != null:
		return true                  # (the small team-size box leaves them, as the reference does)
	return l.call("_find_settings") != null


func _process(_delta: float) -> void:
	var cam := lobby.get("camera") as Camera3D if lobby else null
	var on := cam != null and anchor != null and is_instance_valid(anchor) and anchor.is_visible_in_tree() \
		and player_name != "" and not covered(lobby)
	if on:
		var p := anchor.global_position + Vector3(0, LIFT, 0)
		if cam.is_position_behind(p):
			on = false
		else:
			var at := cam.unproject_position(p) - SIZE * 0.5
			if hero:
				at.y -= HERO_RISE
			var vs := get_viewport_rect().size
			on = at.x > -SIZE.x * 0.5 and at.x < vs.x - SIZE.x * 0.5
			at.x = clampf(at.x, 8.0, vs.x - SIZE.x - 8.0)
			at.y = clampf(at.y, 80.0, vs.y - 92.0 - SIZE.y - 50.0)
			position = at.round()
	visible = on


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, SIZE)
	draw_colored_polygon(UI.chamfer_points(r, 7.0, ["tl", "br"]), Color(0.03, 0.03, 0.035, 0.78))
	# the level square
	var sq := Rect2(3, 3, SIZE.y - 6.0, SIZE.y - 6.0)
	draw_rect(sq, Color(0.13, 0.12, 0.15))
	draw_rect(sq, Color(UI.ACCENT, 0.55), false, 1.0)
	HudDraw.text(self, str(level) if level > 0 else "-", sq.get_center(), 14, UI.ACCENT, 1, 0, "heavy")
	var x := sq.end.x + 6.0
	if leader:
		LobbyTeam.draw_flag(self, Vector2(x + 8.0, SIZE.y * 0.5), 16.0, UI.ACCENT)
		x += 20.0
	var room := SIZE.x - x - (LEAVE_W if can_leave else 8.0) - 2.0
	var t := player_name
	while t.length() > 1 and HudDraw.text_width(t, 18, "heavy") > room:
		t = t.left(t.length() - 1)
	if t != player_name:
		t = t.left(maxi(t.length() - 1, 1)) + "…"
	HudDraw.text(self, t, Vector2(x, SIZE.y * 0.5), 18, UI.ACCENT if hero else UI.TEXT, 0, 0, "heavy")
	if can_leave:
		_draw_leave(leave_rect())


## The leave glyph: an open door frame and an arrow going out to the right.
func _draw_leave(r: Rect2) -> void:
	var c := r.get_center()
	var col := Color(UI.TEXT, 0.92)
	var h := 16.0
	var left := c.x - 8.0
	draw_polyline(PackedVector2Array([Vector2(left + 8.0, c.y - h * 0.5), Vector2(left, c.y - h * 0.5),
		Vector2(left, c.y + h * 0.5), Vector2(left + 8.0, c.y + h * 0.5)]), col, 2.0)
	draw_line(Vector2(left + 4.0, c.y), Vector2(c.x + 8.0, c.y), col, 2.0)
	draw_colored_polygon(PackedVector2Array([Vector2(c.x + 10.0, c.y), Vector2(c.x + 4.0, c.y - 5.0),
		Vector2(c.x + 4.0, c.y + 5.0)]), col)


func _gui_input(event: InputEvent) -> void:
	if not can_leave or not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and leave_rect().grow(6.0).has_point(mb.position):
		accept_event()
		Audio.play("ui_click", -4.0)
		var team: Variant = lobby.get("team")
		if team != null:
			(team as Object).call("ask_leave")
