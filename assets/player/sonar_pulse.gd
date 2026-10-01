class_name SonarPulse extends Node
## Under the water, the sonar_pulse key (V) sends a pulse out around the player. For a moment
## everything it has reached shows as a grainy echo in place of the murk, then the picture
## crumbles away -- a snapshot to find your bearings by, never a way to see all the time.
## The player adds this node itself. Every dial is in GameSettings (Sonar pulse group); the
## picture is drawn by the underwater effect (sonar_pulse() in underwater_post.glsl).

const ACTION := &'sonar_pulse'
## Testing aid: flips to the next look (GameSettings.sonar_look) and pings at once.
const CYCLE_ACTION := &'sonar_cycle_look'

var player: Node # player.gd: its camera, water and whether its ears are under

var _age := -1.0 # seconds since the pulse was sent, -1 = none showing
var _origin := Vector3.ZERO
var _last_sent_msec := -1000000

func _ready() -> void:
	# project.godot binds them to V and B; this covers the editor having saved over that.
	_ensure_action(ACTION, KEY_V)
	_ensure_action(CYCLE_ACTION, KEY_B)

func _ensure_action(action: StringName, keycode: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var key := InputEventKey.new()
	key.physical_keycode = keycode
	InputMap.action_add_event(action, key)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if event.is_action_pressed(ACTION):
		send()
	elif event.is_action_pressed(CYCLE_ACTION):
		var s := GameSettings.current()
		s.sonar_look = ((s.sonar_look + 1) % GameSettings.SonarLook.size()) as GameSettings.SonarLook
		print("Sonar look: ", GameSettings.SonarLook.keys()[s.sonar_look])
		send(true)

## Sends a pulse if we are under the water and it has cooled down (or `ignore_cooldown`).
## True if it went.
func send(ignore_cooldown := false) -> bool:
	var s := GameSettings.current()
	if not player or not player.water or player.unconscious or not player._ears_underwater:
		return false
	if not ignore_cooldown and Time.get_ticks_msec() - _last_sent_msec < s.sonar_cooldown * 1000.0:
		return false
	_last_sent_msec = Time.get_ticks_msec()
	_age = 0.0
	_origin = player.camera.global_position
	EventBus.sonar_pulsed.emit(_origin, s.sonar_range)
	return true

## 0..1: how much of the cooldown is left (for a HUD, should one want it).
func cooldown_left() -> float:
	var s := GameSettings.current()
	if s.sonar_cooldown <= 0.0:
		return 0.0
	return clampf(1.0 - (Time.get_ticks_msec() - _last_sent_msec) / (s.sonar_cooldown * 1000.0), 0.0, 1.0)

func _process(delta: float) -> void:
	var fx: UnderwaterEffect = player.water.underwater_effect if player and player.water else null
	if not fx:
		return
	if _age < 0.0:
		fx.pulse_visibility = 0.0
		return
	var s := GameSettings.current()
	_age += delta
	var visibility := 1.0
	if _age > s.sonar_hold:
		visibility = 1.0 - (_age - s.sonar_hold) / maxf(s.sonar_fade, 0.01)
	# Surfacing ends it: the echo belongs to the water.
	if visibility <= 0.0 or not player._ears_underwater:
		_age = -1.0
		fx.pulse_visibility = 0.0
		return
	apply_to(fx, s, _origin, _age, visibility)

## Hands one moment of a pulse (`age` seconds after it was sent) to the underwater effect.
static func apply_to(fx: UnderwaterEffect, s: GameSettings, origin: Vector3, age: float, visibility: float) -> void:
	fx.pulse_origin = origin
	fx.pulse_age = age
	fx.pulse_front = minf(age * s.sonar_speed, s.sonar_range)
	fx.pulse_speed = s.sonar_speed
	fx.pulse_afterglow = s.sonar_afterglow
	fx.pulse_flare = s.sonar_flare
	fx.pulse_visibility = visibility
	fx.pulse_range = s.sonar_range
	fx.pulse_far_brightness = s.sonar_far_brightness
	fx.pulse_surface = s.sonar_surface
	fx.pulse_grain = s.sonar_look_value(&'grain')
	fx.pulse_streaks = s.sonar_look_value(&'streaks')
	fx.pulse_echo_color = s.sonar_look_value(&'echo_color')
	fx.pulse_rings = s.sonar_look_value(&'rings')
	fx.pulse_background = s.sonar_look_value(&'background')
	fx.pulse_facing = s.sonar_look_value(&'facing')
	fx.pulse_front_glow = s.sonar_look_value(&'front_glow')
	fx.pulse_dissolve = s.sonar_dissolve
	fx.pulse_opacity = s.sonar_opacity
	var rate := s.sonar_grain_rate
	fx.pulse_seed = fmod(floorf(Time.get_ticks_msec() / 1000.0 * rate), 97.0) if rate > 0.0 else 0.0
