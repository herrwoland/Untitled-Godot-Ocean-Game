class_name SonarPulse extends Node
## Under the water, the sonar_pulse key (V) sends a pulse out around the player. For a moment
## everything it has reached shows as a grainy echo in place of the murk, then the picture
## crumbles away -- a snapshot to find your bearings by, never a way to see all the time.
## The player adds this node itself. Every dial is in GameSettings (Sonar pulse group); the
## picture is drawn by the underwater effect (sonar_pulse() in underwater_post.glsl).

const ACTION := &'sonar_pulse'

var player: Node # player.gd: its camera, water and whether its ears are under

var _age := -1.0 # seconds since the pulse was sent, -1 = none showing
var _origin := Vector3.ZERO
var _last_sent_msec := -1000000

func _ready() -> void:
	# project.godot binds it to V; this covers the editor having saved over that.
	if not InputMap.has_action(ACTION):
		InputMap.add_action(ACTION)
		var key := InputEventKey.new()
		key.physical_keycode = KEY_V
		InputMap.action_add_event(ACTION, key)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION) and not event.is_echo():
		send()

## Sends a pulse if we are under the water and it has cooled down. True if it went.
func send() -> bool:
	var s := GameSettings.current()
	if not player or not player.water or player.unconscious or not player._ears_underwater:
		return false
	if Time.get_ticks_msec() - _last_sent_msec < s.sonar_cooldown * 1000.0:
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
	fx.pulse_grain = s.sonar_grain
	fx.pulse_streaks = s.sonar_streaks
	fx.pulse_echo_color = s.sonar_echo_color
	fx.pulse_rings = s.sonar_rings
	fx.pulse_background = s.sonar_background
	fx.pulse_facing = s.sonar_facing
	fx.pulse_front_glow = s.sonar_front_glow
	fx.pulse_dissolve = s.sonar_dissolve
	fx.pulse_opacity = s.sonar_opacity
	var rate := s.sonar_grain_rate
	fx.pulse_seed = fmod(floorf(Time.get_ticks_msec() / 1000.0 * rate), 97.0) if rate > 0.0 else 0.0
