class_name BreachSplash extends Node3D
## The water's answer to a giant body breaking the surface: a creature (Kraken,
## HunterFish) hands it a few points along its body every physics frame
## (track()). Where one goes through the surface fast enough:
##  - bursting out: the water lifted with it is flung up as a tall spray and
##    falls back; plunging in: a crown of water is thrown up and out round it;
##  - the sea itself answers: a ring swell rolls out and a patch of churned
##    foam is left (water shapes, like WaterDeformer: the water shader,
##    buoyancy and the underwater effect all see them);
##  - while a wet part stays out and moves, water streams off it, drying up
##    over a few seconds.
## Cheap when nothing happens: points well under (or over) the sea are not
## sampled against the waves at all.

const SPRAY_TEXTURE := preload('res://assets/water/sea_spray.png')
const BURSTS := 3 # spray bursts that can fly at once (the oldest is reused)
const NEAR_SURFACE := 25.0 # m: a point farther than this (plus its radius) from sea level is not sampled

## Vertical speed (m/s) through the surface that makes any splash at all...
@export var min_speed := 1.5
## ...and the speed that makes the biggest.
@export var full_speed := 12.0
## How much bigger (or smaller) every splash is.
@export_range(0.0, 3.0, 0.05) var strength := 1.0
## Seconds a point must wait before it can splash again (waves bobbing it
## through the surface must not set off a splash every beat).
@export var point_cooldown := 1.2
@export var spray_color := Color(0.93, 0.96, 0.97, 0.9)
## Farther than this from the camera, nothing is drawn or sent to the water.
@export var cull_distance := 900.0

@export_group('Sea')
@export_range(0.0, 1.0, 0.01) var ring_per_radius := 0.14 # m of ring swell per m of the part's radius, at full speed
@export var ring_speed := 9.0 # m/s the ring rolls out
@export var ring_lifetime := 7.0 # s
@export_range(0.0, 2.0, 0.01) var foam := 1.0 # churned white water left where it went through
@export var foam_time := 7.0 # s for that foam to fade
@export_range(1, 4) var max_events := 2 # splashes at once in the sea (each takes 2 of the water's 16 shapes)

var _water: Node
var _bursts: Array[GPUParticles3D] = []
var _next_burst := 0
var _stream: GPUParticles3D
var _above := PackedByteArray() # per point: 1 = its middle is out of the water
var _last_h := PackedFloat32Array() # per point: its height over the surface last frame
var _vel := PackedFloat32Array() # per point: smoothed vertical speed through the water
var _cool := PackedFloat32Array() # per point: s before it may splash again
var _wet := PackedFloat32Array() # per point: s since it came out (water still pouring off)
var _events: Array = [] # [x, z, age, size (0..1), radius]
var _since_burst := 99.0 # s since the last spray burst
const MERGE_TIME := 0.25 # s: one body sliding out (or in) along its length makes one burst, not one per point

func _ready() -> void:
	add_to_group(&'water_deformer') # water.gd advances us and takes our shapes
	for i in BURSTS:
		var p := _make_emitter(260, true)
		_bursts.append(p)
	_stream = _make_emitter(400, false)
	_stream.amount_ratio = 0.0
	_stream.emitting = true

## Every physics frame: where the body is (world points) and how thick it is
## at each (radius, m).
func track(points: PackedVector3Array, radii: PackedFloat32Array, delta: float) -> void:
	if delta <= 0.0:
		return
	if not is_instance_valid(_water):
		_water = get_tree().get_first_node_in_group(&'water')
		if _water == null:
			return
	_since_burst += delta
	var n := points.size()
	if _above.size() != n:
		_above.resize(n)
		_last_h.resize(n)
		_vel.resize(n)
		_cool.resize(n)
		_wet.resize(n)
		for i in n:
			_above[i] = 1 if points[i].y > _water.global_position.y else 0
			_last_h[i] = INF
			_cool[i] = 0.0
			_wet[i] = 99.0
	var cam := get_viewport().get_camera_3d()
	var seen := cam != null and cam.global_position.distance_to(points[0]) < cull_distance
	var sea: float = _water.global_position.y
	var out_sum := Vector3.ZERO
	var out_lo := Vector3.INF
	var out_hi := -Vector3.INF
	var pouring := 0.0
	var outs := 0
	for i in n:
		var p := points[i]
		var r := radii[i]
		_cool[i] = maxf(_cool[i] - delta, 0.0)
		var h: float
		if absf(p.y - sea) > NEAR_SURFACE + r:
			h = p.y - sea # clearly under (or over) the waves: no need to sample them
		else:
			h = p.y - _water.get_wave_height(p, false)
		if _last_h[i] != INF:
			var v := (h - _last_h[i]) / delta
			_vel[i] = lerpf(_vel[i], clampf(v, -60.0, 60.0), 1.0 - exp(-10.0 * delta))
		_last_h[i] = h
		# a band round the surface, so a part riding the waterline does not flicker in and out
		var band := maxf(0.15 * r, 0.5)
		var now_above := _above[i]
		if h > band:
			now_above = 1
		elif h < -band:
			now_above = 0
		if now_above != _above[i]:
			_above[i] = now_above
			if now_above == 1:
				_wet[i] = 0.0
			var speed := absf(_vel[i])
			if seen and speed > min_speed and _cool[i] <= 0.0:
				_cool[i] = point_cooldown
				_splash(Vector3(p.x, p.y - h, p.z), r, smoothstep(min_speed, full_speed, speed), now_above == 1)
		if now_above == 1:
			_wet[i] += delta
			var w := exp(-_wet[i] / 2.5) # it drains over a few seconds
			if w > 0.05 and h < r * 4.0:
				outs += 1
				pouring += w * r
				out_sum += p
				out_lo = out_lo.min(p)
				out_hi = out_hi.max(p)
	_update_stream(seen and outs > 0, out_sum / maxf(outs, 1), out_lo, out_hi, pouring / maxf(outs, 1) if outs > 0 else 0.0, sea)

## One part through the surface at `at` (on the surface): spray, a ring, foam.
func _splash(at: Vector3, radius: float, size: float, out: bool) -> void:
	size = clampf(size * strength, 0.0, 3.0)
	if size <= 0.01:
		return
	if _since_burst < MERGE_TIME:
		return # the burst just thrown covers it
	_since_burst = 0.0
	var p := _bursts[_next_burst]
	_next_burst = (_next_burst + 1) % _bursts.size()
	var pm := p.process_material as ParticleProcessMaterial
	# the higher it is flung, the longer it hangs: sqrt(2 g h) up, 2 v / g in the air
	var up := lerpf(8.0, 30.0, minf(size, 1.0)) * sqrt(maxf(radius, 1.0) / 8.0)
	pm.emission_ring_radius = radius * (0.8 if out else 1.1)
	pm.emission_ring_inner_radius = 0.0 if out else radius * 0.75
	pm.emission_ring_height = radius * 0.2
	pm.direction = Vector3.UP
	pm.spread = 14.0 if out else 30.0
	pm.initial_velocity_min = up * 0.45
	pm.initial_velocity_max = up
	# bursting out, the water rises with the body; plunging in, it is thrown out round it
	pm.radial_velocity_min = 0.0 if out else up * 0.15
	pm.radial_velocity_max = up * (0.08 if out else 0.35)
	pm.scale_min = 0.6 * maxf(radius / 8.0, 0.4)
	pm.scale_max = 1.5 * maxf(radius / 8.0, 0.4)
	p.lifetime = clampf(2.0 * up / 9.8 + 0.6, 1.0, 6.0)
	p.amount_ratio = clampf(0.35 + 0.65 * size, 0.0, 1.0)
	p.global_position = at
	p.restart()
	_events.push_back([at.x, at.z, 0.0, minf(size, 1.5), radius])
	while _events.size() > max_events:
		_events.pop_front()

## Water pouring off the parts that are out, over where they are.
func _update_stream(on: bool, mid: Vector3, lo: Vector3, hi: Vector3, pour: float, sea: float) -> void:
	if not on:
		_stream.amount_ratio = 0.0
		return
	_stream.global_position = mid
	var pm := _stream.process_material as ParticleProcessMaterial
	pm.emission_box_extents = ((hi - lo) * 0.5).max(Vector3.ONE * 2.0)
	_stream.amount_ratio = clampf(pour / 10.0, 0.0, 1.0) * clampf(strength, 0.0, 1.0)

## ---- the sea's side (called by water.gd, like a WaterDeformer) ------------------

func update_state(delta: float, _water_level: float) -> void:
	for i in range(_events.size() - 1, -1, -1):
		_events[i][2] += delta
		if _events[i][2] > maxf(ring_lifetime, foam_time):
			_events.remove_at(i)

## Same packing as WaterDeformer.pack_shapes(): ring a = (x, z, radius,
## amplitude), b = (width, 0, 1, foam); boil a = (x, z, width, 0), b = (0, 0, 2, foam).
func pack_shapes() -> Array:
	var shapes := []
	for e in _events:
		var age: float = e[2]
		var r: float = e[4]
		var ring_r := r + ring_speed * age
		var amp: float = ring_per_radius * r * e[3] * strength * sqrt(r / ring_r) \
			* smoothstep(0.0, 0.4, age) * (1.0 - smoothstep(0.5 * ring_lifetime, ring_lifetime, age))
		if amp > 0.01:
			shapes.append([Vector4(e[0], e[1], ring_r, amp), Vector4(r * 0.6 + 0.3 * age, 0.0, 1.0, 0.8 * foam)])
		var white: float = foam * minf(e[3], 1.0) * exp(-age / foam_time)
		if white > 0.02:
			shapes.append([Vector4(e[0], e[1], r * (1.6 + 0.08 * age), 0.0), Vector4(0.0, 0.0, 2.0, white)])
	return shapes

## ---- particles -----------------------------------------------------------------

func _make_emitter(count: int, burst: bool) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.top_level = true # left where the water was, not carried with the body
	p.amount = count
	p.one_shot = burst
	p.emitting = false
	p.explosiveness = 0.85 if burst else 0.0
	p.randomness = 0.5
	p.lifetime = 3.0 if burst else 1.8
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-80, -20, -80), Vector3(160, 120, 160))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.gravity = Vector3(0, -9.8, 0)
	pm.damping_min = 0.3
	pm.damping_max = 1.2
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	if burst:
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		pm.emission_ring_axis = Vector3.UP
	else:
		# streaming off: barely thrown, it falls
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.direction = Vector3.DOWN
		pm.spread = 25.0
		pm.initial_velocity_min = 0.0
		pm.initial_velocity_max = 2.0
		pm.scale_min = 0.3
		pm.scale_max = 0.8
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.4))
	curve.add_point(Vector2(0.3, 1.0))
	curve.add_point(Vector2(1.0, 1.8)) # puffs spread into mist as they fall
	var scale_tex := CurveTexture.new()
	scale_tex.curve = curve
	pm.scale_curve = scale_tex
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0.0))
	ramp.set_color(1, Color(1, 1, 1, 0.0))
	ramp.add_point(0.08, Color(1, 1, 1, 1.0))
	ramp.add_point(0.65, Color(1, 1, 1, 0.55))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	pm.color_ramp = ramp_tex
	p.process_material = pm
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = SPRAY_TEXTURE
	mat.albedo_color = spray_color
	mat.disable_receive_shadows = true
	mat.render_priority = 1 # drawn after the water (priority 0), never hidden behind it
	var quad := QuadMesh.new()
	quad.size = Vector2(6.0, 6.0) if burst else Vector2(3.0, 3.0)
	quad.material = mat
	p.draw_pass_1 = quad
	add_child(p)
	return p
