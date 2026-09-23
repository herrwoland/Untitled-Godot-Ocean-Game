@tool
class_name BubbleEmitter extends GPUParticles3D
## Bubbles rising to the surface from anything underwater. Ways to use it:
##  - trail: bubbles stream off it while it moves (creatures, propellers, a sinking package);
##  - breath: a small puff every `breath_interval` seconds (scuba divers, machines);
##  - burst(): a one-off gush from script, at a strength you choose (a gasp, a body hitting
##    the water, something cracking open);
##  - stream: steady emission while `stream` > 0 (air escaping a drowned body, a leak).
## Only emits while under the water; finds the water node by itself (group "water").

const PROCESS_SHADER := preload('res://assets/shaders/particles/bubbles.gdshader')
const DRAW_SHADER := preload('res://assets/shaders/particles/water_speck.gdshader')

## Speed (m/s) at which the trail streams at full strength (0 = no trail).
@export_range(0.0, 30.0, 0.1) var trail_full_speed := 4.0
## Trail strength at full speed (0..1 of the emitter's particle budget).
@export_range(0.0, 1.0, 0.01) var trail_amount := 0.6
## Seconds between breath puffs (0 = no breathing).
@export_range(0.0, 20.0, 0.1) var breath_interval := 0.0
## Length of each breath puff (s).
@export_range(0.05, 2.0, 0.05) var breath_duration := 0.35
## Steady emission (0..1 of the particle budget), eg. set from script while drowning.
@export_range(0.0, 1.0, 0.01) var stream := 0.0

@export_group('Look')
@export_range(0.001, 0.5, 0.001) var size_min := 0.015 : set = _set_size_min
@export_range(0.001, 0.5, 0.001) var size_max := 0.07 : set = _set_size_max
@export_range(0.1, 5.0, 0.05) var rise_speed := 1.1 : set = _set_rise_speed
@export_range(0.0, 2.0, 0.01) var wobble := 0.35 : set = _set_wobble
@export_range(0.0, 3.0, 0.01) var spawn_radius := 0.15 : set = _set_spawn_radius
@export var bubble_color := Color(0.7, 0.85, 0.85) : set = _set_bubble_color
## Optional sprite for the bubbles (small pixel-art PNG, white/grey on transparent; import
## with Filter off). Tinted by bubble_color and lit like the rest. Empty = built-in ring.
@export var bubble_texture : Texture2D : set = _set_bubble_texture
## Pixelates the built-in ring to this many pixels across (0 = smooth). Ignored with a texture.
@export_range(0, 32) var pixel_grid := 6 : set = _set_pixel_grid

var _water : Node
var _last_position := Vector3.INF
var _breath_timer := 0.0
var _burst_left := 0.0 # Seconds of emission still owed by burst()/breaths.
var _burst_amount := 1.0 # How hard that burst emits (0..1).

func _ready() -> void:
	if not process_material:
		amount = 256
		lifetime = 8.0
		local_coords = false
		randomness = 0.3
		visibility_aabb = AABB(Vector3(-15, -5, -15), Vector3(30, 60, 30))
		cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pm := ShaderMaterial.new()
		pm.shader = PROCESS_SHADER
		process_material = pm
		var mat := ShaderMaterial.new()
		mat.shader = DRAW_SHADER
		mat.set_shader_parameter(&'ring', 1.0)
		var quad := QuadMesh.new()
		quad.material = mat
		draw_pass_1 = quad
	# Whether the materials came from the scene or were just built, the exported values are
	# the ones that count: push them in.
	for prop in [&'size_min', &'size_max', &'rise_speed', &'wobble', &'spawn_radius', &'bubble_color', &'bubble_texture', &'pixel_grid']:
		set(prop, get(prop))
	layers = 1 << 19 # Water render layer: the sun shadow camera skips it (see water.gd).
	amount_ratio = 0.0
	emitting = false # Switched on by _physics_process() only when there's something to emit.
	_breath_timer = randf() * breath_interval

## A one-off gush of bubbles lasting `seconds`. `strength` (0..1) sets how much of the
## particle budget it uses, so a body slipping in and a body crashing in look different.
func burst(seconds := 0.4, strength := 1.0) -> void:
	if seconds <= 0.0 or strength <= 0.0: return
	if _burst_left <= 0.0 or strength > _burst_amount:
		_burst_amount = clampf(strength, 0.0, 1.0)
	_burst_left = maxf(_burst_left, seconds)

func _physics_process(delta : float) -> void:
	if Engine.is_editor_hint() or delta <= 0.0: return
	if not is_instance_valid(_water):
		_water = get_tree().get_first_node_in_group(&'water')
		if not _water: return
	var pos := global_position
	var surface : float = _water.get_wave_height(pos, false)
	var velocity := Vector3.ZERO
	if _last_position != Vector3.INF:
		velocity = (pos - _last_position) / delta
		if velocity.length() > 100.0: velocity = Vector3.ZERO # Teleported.
	_last_position = pos

	if draw_pass_1 is PrimitiveMesh and draw_pass_1.material is ShaderMaterial:
		# Dim with depth like everything else underwater (see water.gd's depth_darkening).
		draw_pass_1.material.set_shader_parameter(&'water_level', _water.global_position.y)
		draw_pass_1.material.set_shader_parameter(&'depth_darkening', _water.get(&'depth_darkening'))
	var pm := process_material as ShaderMaterial
	if pm:
		pm.set_shader_parameter(&'surface_y', surface)
		pm.set_shader_parameter(&'inherit_velocity', velocity)

	if breath_interval > 0.0:
		_breath_timer -= delta
		if _breath_timer <= 0.0:
			_breath_timer = breath_interval * randf_range(0.8, 1.2)
			burst(breath_duration)
	_burst_left = maxf(_burst_left - delta, 0.0)

	var under := pos.y < surface - 0.05
	var trail := trail_amount * smoothstep(0.2, trail_full_speed, velocity.length()) if trail_full_speed > 0.0 else 0.0
	var bursting := _burst_amount if _burst_left > 0.0 else 0.0
	amount_ratio = clampf(maxf(maxf(trail, stream), bursting), 0.0, 1.0) if under else 0.0
	# amount_ratio = 0 alone doesn't stop a custom-shader particle system: switch emission off.
	emitting = amount_ratio > 0.001

func _set_size_min(v : float) -> void: size_min = v; _pm_param(&'size_min', v)
func _set_size_max(v : float) -> void: size_max = v; _pm_param(&'size_max', v)
func _set_rise_speed(v : float) -> void: rise_speed = v; _pm_param(&'rise_speed', v)
func _set_wobble(v : float) -> void: wobble = v; _pm_param(&'wobble', v)
func _set_spawn_radius(v : float) -> void: spawn_radius = v; _pm_param(&'spawn_radius', v)
func _set_bubble_color(v : Color) -> void:
	bubble_color = v
	if draw_pass_1 is PrimitiveMesh and draw_pass_1.material is ShaderMaterial:
		draw_pass_1.material.set_shader_parameter(&'color', v)

func _set_bubble_texture(v : Texture2D) -> void:
	bubble_texture = v
	_draw_param(&'sprite', v)
	_draw_param(&'use_sprite', v != null)
func _set_pixel_grid(v : int) -> void: pixel_grid = v; _draw_param(&'pixel_grid', float(v))

func _draw_param(param : StringName, value) -> void:
	if draw_pass_1 is PrimitiveMesh and draw_pass_1.material is ShaderMaterial:
		draw_pass_1.material.set_shader_parameter(param, value)

func _pm_param(param : StringName, value) -> void:
	if process_material is ShaderMaterial: process_material.set_shader_parameter(param, value)
