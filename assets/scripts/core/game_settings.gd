@tool
class_name GameSettings extends Resource
## One place for game-wide tuning. Open res://assets/settings/game_settings.tres and change
## things in the inspector; every script reads from it through GameSettings.current().
## Add a new @export_group here whenever something else wants a global dial.

const PATH := "res://assets/settings/game_settings.tres"
const HIGHLIGHT_MATERIAL := preload("res://assets/scripts/interact_highlight_material.tres")

static var _current: GameSettings

static func current() -> GameSettings:
	if _current == null:
		_current = load(PATH)
		_current._apply_highlight()
	return _current

@export_group("Interact highlight", "highlight_")
## Glow laid over things you look at and can use (the helm, the searchlight).
@export var highlight_color := Color(1.0, 0.9, 0.2):
	set(v): highlight_color = v; _apply_highlight()
## Opacity over the whole surface.
@export_range(0.0, 1.0, 0.01) var highlight_fill := 0.3:
	set(v): highlight_fill = v; _apply_highlight()
## Extra opacity on edges seen side-on, which outlines the shape.
@export_range(0.0, 1.0, 0.01) var highlight_rim := 0.35:
	set(v): highlight_rim = v; _apply_highlight()
## Higher = thinner outline.
@export_range(0.5, 8.0, 0.1) var highlight_rim_sharpness := 2.0:
	set(v): highlight_rim_sharpness = v; _apply_highlight()
## Brightness (above 1 it blooms).
@export_range(0.0, 4.0, 0.05) var highlight_energy := 1.5:
	set(v): highlight_energy = v; _apply_highlight()
## Breathing of the glow, in pulses per second (0 = steady).
@export_range(0.0, 10.0, 0.05) var highlight_pulse_speed := 0.0:
	set(v): highlight_pulse_speed = v; _apply_highlight()
## How much the pulse dims the glow at its lowest (0 = no pulse).
@export_range(0.0, 1.0, 0.01) var highlight_pulse_amount := 0.0:
	set(v): highlight_pulse_amount = v; _apply_highlight()
## How far the glow floats towards the camera to stay on top of the model (m). Raise it
## if the glow flickers on big objects, lower it if it visibly floats off small ones.
@export_range(0.0, 0.1, 0.001) var highlight_surface_offset := 0.01:
	set(v): highlight_surface_offset = v; _apply_highlight()

@export_group("Item glow", "item_glow_")
## How letters and packages light up when you look at them (their own surface glows).
@export var item_glow_color := Color(1.0, 0.95, 0.7)
@export_range(0.0, 4.0, 0.05) var item_glow_energy := 0.4

@export_group("Camera shake", "camera_shake_")
## Scales every camera shake (jolts, rumbles). 0 turns shaking off.
@export_range(0.0, 2.0, 0.05) var camera_shake_strength := 1.0

@export_group("Sonar pulse", "sonar_")
## Under the water, the sonar_pulse key (V) sends a pulse out around the player: for a moment
## everything it reaches shows as a grainy echo, then the picture crumbles back into the murk.
## Seconds before another pulse can be sent (counted from the last one).
@export_range(0.0, 60.0, 0.1) var sonar_cooldown := 1.0
## How far it reaches (m).
@export_range(1.0, 500.0, 0.5) var sonar_range := 300.0
## How bright an echo from the edge of the range is, compared to one from close by. The pulse
## sees far past the murk: everything within range answers, the distance only a bit dimmer.
@export_range(0.0, 1.0, 0.01) var sonar_far_brightness := 1.0
## How strongly the underside of the waves answers. Kept faint: it is everywhere overhead and
## would bury whatever hangs under it, like a hull.
@export_range(0.0, 1.0, 0.01) var sonar_surface := 0.15
## How fast the front races out (m/s). range / speed is how long the sweep takes; keep it
## shorter than the hold or the echo starts fading before the front gets all the way out.
## (Real sound in water: about 1500.)
@export_range(5.0, 2000.0, 1.0) var sonar_speed := 500.0
## How long the echo holds at full strength once sent (s).
@export_range(0.0, 5.0, 0.05) var sonar_hold := 1.0
## Then how long it takes to fade away (s).
@export_range(0.05, 5.0, 0.05) var sonar_fade := 0.6
## 0 = it simply dims away, 1 = it crumbles away grain by grain.
@export_range(0.0, 0.95, 0.01) var sonar_dissolve := 0.8
## Colour of what answers the pulse. Above 1 it blooms.
@export var sonar_echo_color := Color(0.784, 1.3, 1.219)
## Colour of everything that does not answer (open water, the surface).
@export var sonar_background := Color(0.0, 0.0, 0.0)
## How strongly the echo is broken up by speckle (0 = clean).
@export_range(0.0, 1.0, 0.01) var sonar_grain := 1.0
## How much of the grain is smeared sideways like a scan line.
@export_range(0.0, 1.0, 0.01) var sonar_streaks := 0.6
## How many times a second the grain changes (0 = frozen).
@export_range(0.0, 60.0, 1.0) var sonar_grain_rate := 10.0
## Higher = only surfaces facing you answer, so shapes read by their outlines and hollows.
@export_range(0.1, 6.0, 0.05) var sonar_facing := 2.5
## Brightness of the band just behind the travelling front.
@export_range(0.0, 4.0, 0.05) var sonar_front_glow := 1.2
## Afterglow, like the phosphor on a sonar screen: each point flares as the front passes it,
## then settles over this many seconds; the brightest echoes also fade last (0 = off).
@export_range(0.0, 3.0, 0.05) var sonar_afterglow := 0.35
## How bright that flare is, on top of the settled echo.
@export_range(0.0, 6.0, 0.05) var sonar_flare := 1.5
## Distance between range rings drawn into the echo (m, 0 = none).
@export_range(0.0, 20.0, 0.25) var sonar_rings := 5.25
## How much the echo replaces the normal view (1 = completely).
@export_range(0.0, 1.0, 0.01) var sonar_opacity := 1.0

func _apply_highlight() -> void:
	var m := HIGHLIGHT_MATERIAL
	m.set_shader_parameter(&'color', highlight_color)
	m.set_shader_parameter(&'fill', highlight_fill)
	m.set_shader_parameter(&'rim', highlight_rim)
	m.set_shader_parameter(&'rim_sharpness', highlight_rim_sharpness)
	m.set_shader_parameter(&'energy', highlight_energy)
	m.set_shader_parameter(&'pulse_speed', highlight_pulse_speed)
	m.set_shader_parameter(&'pulse_amount', highlight_pulse_amount)
	m.set_shader_parameter(&'surface_offset', highlight_surface_offset)

## Lays the interact highlight over every MeshInstance3D at or below `root` (works on a
## single mesh and on an imported model with its own subtree), or takes it off again.
static func set_highlight(root: Node, on: bool) -> void:
	if root == null:
		return
	var material: Material = HIGHLIGHT_MATERIAL if on else null
	if on:
		current() # make sure the material carries the settings
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		meshes.append(root)
	for m: MeshInstance3D in meshes:
		m.material_overlay = material
