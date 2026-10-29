extends Node
## Tamper protection for an offline game. Nothing here talks to a server (the game has no
## network permission). It makes the usual mobile cheats fail or get noticed:
## - memory scanners that search for and freeze values (HP, ammo, items): those values live
##   XOR-masked with a checksum in SecureNum, so they can't be found and edits are detected;
## - speed hacks: the game clock is compared with the wall clock;
## - edited save files: the profile is signed with an HMAC tied to this device and to a secret
##   that exists only in release builds;
## - repackaged APKs: on Android 9+ the system's package manager must confirm that the app is
##   signed with a certificate of the official build. A question it cannot answer counts as
##   "unknown" (allowed); a different certificate, or a release build without the list, counts.
## The secret and the certificate list are constants in res://build_keys.gd, which
## tools/build_apk.sh (and the CI export) writes for one build and deletes afterwards; it is
## git-ignored and ships compiled inside the APK, never as a plain file. Offline, someone who
## digs through the APK can still recover them: this raises the bar, it is not a lock.
## A detection ends the running match without XP ("INTEGRITY CHECK FAILED").

signal tampered(reason: String)

const KEYS_SCRIPT := "res://build_keys.gd"     # const SIGNERS := [...], const SAVE_SECRET := "..."
const SPEED_WINDOW_USEC := 3000000
const SPEED_FAST := 1.6              # game clock vs real time over one window
const SPEED_SLOW := 0.6
const SPEED_STRIKES := 2             # in a row: one odd window is the wall clock being set
const CERT_INPUT_SHA256 := 1        # android.content.pm.PackageManager.CERT_INPUT_SHA256

var flags: PackedStringArray = []
var signature_state := "unchecked"

var _salt := 0
var _mask_state := 0
var _hmac_key := PackedByteArray()
var _tick_start := 0
var _wall_start := 0.0
var _speed_strikes := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_salt = rng.randi() | (rng.randi() << 31)
	_mask_state = rng.randi() | 1
	var secret := "dev"      # editor and test runs; every exported build ships its own
	var keys := build_keys()
	if typeof(keys.get("SAVE_SECRET")) == TYPE_STRING and String(keys.SAVE_SECRET).length() >= 32:
		secret = String(keys.SAVE_SECRET)
	_hmac_key = ("lw-arena|%s|%s" % [OS.get_unique_id(), secret]).sha256_buffer()
	_reset_clock()
	_check_signature.call_deferred()


# ---------------------------------------------------------------- masked values

func next_mask() -> int:
	# xorshift64*: a new mask for every write, so a value's bytes never repeat in memory.
	var x := _mask_state
	x ^= x << 13
	x ^= x >> 7
	x ^= x << 17
	_mask_state = x if x != 0 else 0x2545F491
	return _mask_state


func checksum(raw: int, mask: int) -> int:
	return ((raw * 0x9E3779B1) ^ (mask >> 7) ^ _salt) & 0x3FFFFFFFFFFFFFFF


# ---------------------------------------------------------------- detections

func flag(reason: String) -> void:
	if reason in flags:
		return
	flags.append(reason)
	push_warning("[Guard] integrity check failed: " + reason)
	print("[LoneWolf] integrity flag: ", reason)
	tampered.emit(reason)


func is_clean() -> bool:
	return flags.is_empty()


func _reset_clock() -> void:
	_tick_start = Time.get_ticks_usec()
	_wall_start = Time.get_unix_time_from_system()


func _process(_delta: float) -> void:
	var ticks := Time.get_ticks_usec() - _tick_start
	if ticks < SPEED_WINDOW_USEC:
		return
	# A wall clock that is set (network time, by hand) gives one odd window, so only odd windows
	# in a row count.
	match speed_window(float(ticks) / 1e6, Time.get_unix_time_from_system() - _wall_start):
		1:
			_speed_strikes += 1
			if _speed_strikes >= SPEED_STRIKES:
				flag("speed")
		0:
			_speed_strikes = 0
	_reset_clock()


## One window of game-clock seconds against wall-clock seconds: 1 when the game clock ran ahead
## of real time (a speed tool: faster play) or behind it (more time to aim), 0 when normal,
## -1 when the wall clock went backwards (it was set; no verdict).
static func speed_window(ticks_s: float, wall_s: float) -> int:
	if wall_s <= 0.0:
		return -1
	var ratio := ticks_s / wall_s
	return 1 if ratio > SPEED_FAST or ratio < SPEED_SLOW else 0


func _notification(what: int) -> void:
	# The monotonic clock stops while the phone sleeps; the app is paused then. A pending strike
	# is kept, so switching apps does not clear it.
	if what in [NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_PAUSED]:
		_reset_clock()


# ---------------------------------------------------------------- signed saves

func sign_text(text: String) -> String:
	var ctx := HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, _hmac_key)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode()


## JSON turns every number into a float on load, so whole numbers are signed as ints on both
## sides (otherwise 3 and 3.0 would sign differently).
static func _canonical(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if is_equal_approx(v, roundf(v)) and absf(v) < 1.0e15 else v
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[String(k)] = _canonical(v[k])
			return d
		TYPE_ARRAY:
			var a := []
			for x in v:
				a.append(_canonical(x))
			return a
	return v


func sign_dict(data: Dictionary) -> Dictionary:
	var body: Dictionary = _canonical(data)
	body.erase("_sig")
	var out := body.duplicate(true)
	out["_sig"] = sign_text(JSON.stringify(body, "", true))
	return out


## Returns {"ok": bool, "data": Dictionary-without-signature}. A missing or malformed signature
## fails like a wrong one: every build that a player can update from signs its profile.
func verify_dict(data: Dictionary) -> Dictionary:
	var body: Dictionary = _canonical(data)
	var sig: Variant = body.get("_sig")
	body.erase("_sig")
	if typeof(sig) != TYPE_STRING or String(sig).is_empty():
		return {"ok": false, "data": body}
	return {"ok": String(sig) == sign_text(JSON.stringify(body, "", true)), "data": body}


# ---------------------------------------------------------------- APK signature (Android)

func _check_signature() -> void:
	signature_state = _signature_state()
	if OS.get_name() == "Android":
		print("[LoneWolf] signature ", signature_state)
	if signature_state.begins_with("mismatch"):
		flag("signature")


## The constants of res://build_keys.gd ({} when the build has none).
static func build_keys() -> Dictionary:
	if not ResourceLoader.exists(KEYS_SCRIPT):
		return {}
	var scr: Variant = load(KEYS_SCRIPT)
	return (scr as Script).get_script_constant_map() if scr is Script else {}


func _signature_state() -> String:
	if OS.get_name() != "Android":
		return "not android"
	var listed: Variant = build_keys().get("SIGNERS", [])
	var accepted := signer_digests("\n".join(PackedStringArray(listed if listed is Array else [])))
	if accepted.is_empty():
		# Every official release build carries the list, so a release without it was altered.
		return "mismatch (no signer list)" if OS.has_feature("template_release") else "unknown (no signer list)"
	# The installed APK can't be read directly: Godot only opens files in the app's own storage.
	if not Engine.has_singleton("AndroidRuntime"):
		return "unknown (no android runtime)"
	var ctx: Variant = Engine.get_singleton("AndroidRuntime").call("getApplicationContext")
	if not ctx is JavaObject:
		return "unknown (no context)"
	var pm: Variant = (ctx as JavaObject).call("getPackageManager")
	if not pm is JavaObject or not (pm as JavaObject).has_java_method("hasSigningCertificate"):
		return "unknown (android < 9)"
	var package: Variant = (ctx as JavaObject).call("getPackageName")
	for digest in accepted:
		# Also true for an older key of a rotated signing lineage. Godot's Java bridge returns a
		# Java boolean as the integer 0 / 1.
		var signed: Variant = (pm as JavaObject).call("hasSigningCertificate", package, digest, CERT_INPUT_SHA256)
		if typeof(signed) != TYPE_BOOL and typeof(signed) != TYPE_INT:
			return "unknown (no answer)"
		if JavaClassWrapper.get_exception() != null:      # a failed call also reads as 0
			return "unknown (java error)"
		if signed:
			return "ok"
	return "mismatch"


## Certificate SHA-256s, one per line (hex, with or without colons), as 32-byte arrays; empty
## when any line is not one.
static func signer_digests(text: String) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	for line in text.split("\n", false):
		var hex := line.strip_edges().to_lower().replace(":", "")
		if hex.is_empty():
			continue
		if hex.length() != 64 or not hex.is_valid_hex_number():
			return []
		out.append(hex.hex_decode())
	return out
