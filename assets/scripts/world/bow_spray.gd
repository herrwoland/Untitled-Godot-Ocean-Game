@tool
class_name BowSpray extends GPUParticles3D
## Spray thrown off a boat's bow: a steady sheet that grows with speed, and heavy bursts when
## the bow slams down into a wave. Use one per side: put it just outside the hull at the bow,
## at the waterline, and point `throw_direction` outwards. Finds the water node by itself
## (group "water").

const SPRAY_TEXTURE := preload('res://assets/water/sea_spray.png')

## Direction spray is thrown in, in this node's local space (up and away from the hull).
@export var throw_direction := Vector3(0.0, 1.0, 0.7) :
	set(value):
		throw_direction = value
		if process_material is ParticleProcessMaterial: process_material.direction = value.normalized()
## Speed (m/s) at which the steady spray reaches full strength.
@export_range(0.5, 40.0, 0.1) var full_speed := 5.0
## How much of the spray is emitted steadily at full speed (0..1) vs only on slams.
@export_range(0.0, 1.0, 0.01) var steady_amount := 0.5
## Downward speed of the bow into the water (m/s) that gives a full burst.
@export_range(0.1, 20.0, 0.1) var slam_speed := 3.0
## How high spray is thrown (m/s upwards at full strength).
@export_range(0.0, 40.0, 0.1) var throw_speed := 9.0
## Size of a spray puff (m).
@export_range(0.1, 10.0, 0.05) var puff_size := 3.5
## Spray tint (the storm light makes pure white glow too much).
@export var spray_color := Color(0.95, 0.97, 0.97, 0.9)
## Emits only while the waterline is within this far below the node (m).
@export_range(0.0, 10.0, 0.05) var max_height_above_water := 3.5

var _water : Node
var _last_position := Vector3.INF
var _last_depth := 0.0
var _burst := 0.0

func _ready() -> void:
	if not process_material: # Fresh node: set up sensible defaults once, then they're yours to tune.
		amount = 600
		lifetime = 1.6
		local_coords = false
		explosiveness = 0.0
		randomness = 0.5
		visibility_aabb = AABB(Vector3(-30, -10, -30), Vector3(60, 40, 60))
		cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_build_resources()
	amount_ratio = 0.0
	emitting = true

func _build_resources() -> void:
	var pm := ParticleProcessMaterial.new()
	pm.direction = throw_direction.normalized()
	pm.spread = 30.0
	pm.initial_velocity_min = throw_speed * 0.4
	pm.initial_velocity_max = throw_speed
	pm.gravity = Vector3(0, -9.8, 0)
	pm.damping_min = 1.0
	pm.damping_max = 3.0
	pm.scale_min = 0.6
	pm.scale_max = 1.4
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(2.5, 0.3, 0.3) # Along the hull.
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.3))
	curve.add_point(Vector2(0.25, 1.0))
	curve.add_point(Vector2(1.0, 1.6))
	var scale_tex := CurveTexture.new()
	scale_tex.curve = curve
	pm.scale_curve = scale_tex
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0.0))
	ramp.set_color(1, Color(1, 1, 1, 0.0))
	ramp.add_point(0.1, Color(1, 1, 1, 1.0))
	ramp.add_point(0.6, Color(1, 1, 1, 0.6))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	pm.color_ramp = ramp_tex
	process_material = pm

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = SPRAY_TEXTURE
	mat.albedo_color = spray_color
	mat.disable_receive_shadows = true
	var quad := QuadMesh.new()
	quad.size = Vector2(puff_size, puff_size)
	quad.material = mat
	draw_pass_1 = quad

func _physics_process(delta : float) -> void:
	if Engine.is_editor_hint() or delta <= 0.0: return
	if not is_instance_valid(_water):
		_water = get_tree().get_first_node_in_group(&'water')
		if not _water: return
	var pos := global_position
	var water_height : float = _water.get_wave_height(pos, false)
	var depth := water_height - pos.y # > 0 = bow under the waterline.
	var speed := 0.0
	if _last_position != Vector3.INF:
		speed = Vector2(pos.x - _last_position.x, pos.z - _last_position.z).length() / delta
		# Bow driving down into the water (or the water rising up the bow) makes a burst.
		var plunge := (depth - _last_depth) / delta
		if plunge > 0.0 and depth > -1.5:
			_burst = maxf(_burst, clampf(plunge / slam_speed, 0.0, 1.0))
	_last_position = pos
	_last_depth = depth
	_burst = move_toward(_burst, 0.0, delta * 2.0)

	var near_water := 1.0 - smoothstep(0.0, max_height_above_water, -depth)
	var moving := smoothstep(0.5, full_speed, speed)
	amount_ratio = clampf((steady_amount * moving + _burst * (0.3 + 0.7 * moving)) * near_water, 0.0, 1.0)
	var pm := process_material as ParticleProcessMaterial
	if pm:
		pm.initial_velocity_max = throw_speed * (0.5 + 0.5 * maxf(moving, _burst))
