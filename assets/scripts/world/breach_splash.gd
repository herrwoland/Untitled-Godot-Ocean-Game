class_name BreachSplash extends Node3D
## The water's answer to a giant body breaking the surface: a creature (Kraken,
## HunterFish) hands it a few points along its body every physics frame
## (track()). Where one goes through the surface fast enough:
##  - spray in layers, as a real splash is built: a crown sheet of big chunky
##    water thrown up and out round the rim, thousands of small drops flung
##    off it as streaks, and fine mist that hangs and drifts long after; a
##    body plunging in also leaves an air cavity whose collapse shoots a tall
##    column (Worthington jet) straight up a moment later. Bursting out there
##    is no jet: the water rides up with the body and falls off it;
##  - the sea itself answers: a ring swell rolls out and a patch of churned
##    foam is left (water shapes, like WaterDeformer: the water shader,
##    buoyancy and the underwater effect all see them);
##  - while a wet part stays out and moves, water streams off it, drying up
##    over a few seconds.
## Cheap when nothing happens: points well under (or over) the sea are not
## sampled against the waves at all.

const SPRAY_TEXTURE := preload('res://assets/water/sea_spray.png')
const SLOTS := 4 # splashes whose spray can fly at once; a slot still flying is never restarted
enum Layer { CROWN, DROPS, MIST, JET } # a slot holds the first three; jets have their own pool
const DROP_TEXTURE_SIZE := 32
const NEAR_SURFACE := 25.0 # m: a point farther than this (plus its radius) from sea level is not sampled

## Vertical speed (m/s) through the surface that makes any splash at all...
@export var min_speed := 1.5
## ...and the speed that makes the biggest.
@export var full_speed := 12.0
## How much bigger (or smaller) every splash is.
@export_range(0.0, 3.0, 0.05) var strength := 1.0
## The size of the water thrown, for the size of the body: a fast breach
## flings it this many times the part's radius high (a 150 m fish, radius 9:
## ~70 m), a slow one far lower; the puffs are a few radii across.
## Turn it up or down to taste (the height follows real gravity, so a taller
## splash also hangs in the air longer).
@export_range(0.1, 5.0, 0.05) var splash_scale := 1.0
const HEIGHT_PER_RADIUS := 8.0
const PUFF_PER_RADIUS := 2.4 # crown puff size (m) per m of radius as it leaves the water; it grows ~2x as it falls
## Seconds a point must wait before it can splash again (waves bobbing it
## through the surface must not set off a splash every beat).
@export var point_cooldown := 1.2
@export var spray_color := Color(0.84, 0.9, 0.92, 0.95) # sea water, a touch grey-green: not cloud white
## Farther than this from the camera, nothing is drawn or sent to the water.
@export var cull_distance := 900.0

@export_group('Sound')
## The crash of a big body going through the surface. Empty: a placeholder made
## in code (a thump, the roar of falling water, a patter of drops).
@export var big_splash_sound: AudioStream
## A splash only sounds when it is at least this big (0..1: how fast it went
## through) and the part this thick (m): a whole body, not an arm tip.
@export_range(0.0, 1.0, 0.01) var big_splash_min_size := 0.35
@export var big_splash_min_radius := 4.0
@export var big_splash_volume_db := 0.0
@export var sound_bus := &'SFX'

@export_group('Sea')
@export_range(0.0, 1.0, 0.01) var ring_per_radius := 0.14 # m of ring swell per m of the part's radius, at full speed
@export var ring_speed := 9.0 # m/s the ring rolls out
@export var ring_lifetime := 7.0 # s
@export_range(0.0, 2.0, 0.01) var foam := 1.0 # churned white water left where it went through
@export var foam_time := 7.0 # s for that foam to fade
@export_range(1, 4) var max_events := 2 # splashes at once in the sea (each takes 2 of the water's 16 shapes)

var _water: Node
var _slots: Array = [] # per slot: [crown, drops, mist] GPUParticles3D
var _next_slot := 0
var _jets: Array[GPUParticles3D] = [] # their own pool: a jet still to come is never cut off by the next splash
var _next_jet := 0
var _pending_jets: Array = [] # [seconds left, at, radius, up, amount] — the cavity has not collapsed yet
var _stream: GPUParticles3D
var _above := PackedByteArray() # per point: 1 = its middle is out of the water
var _last_h := PackedFloat32Array() # per point: its height over the surface last frame
var _vel := PackedFloat32Array() # per point: smoothed vertical speed through the water
var _cool := PackedFloat32Array() # per point: s before it may splash again
var _wet := PackedFloat32Array() # per point: s since it came out (water still pouring off)
var _events: Array = [] # [x, z, age, size (0..1), radius]
var _since_burst := 99.0 # s since the last spray burst
var _clock := 0.0 # s, our own time
var _busy_until := {} # emitter -> _clock when its last particle has landed
var _voices: Array[AudioStreamPlayer3D] = []
var _next_voice := 0
static var _placeholder_crash: AudioStreamWAV # made once, shared by every creature
const MERGE_TIME := 0.5 # s: one body sliding out (or in) along its length makes one burst, not one per point

func _ready() -> void:
	add_to_group(&'water_deformer') # water.gd advances us and takes our shapes
	var drop_tex := _drop_texture()
	for i in SLOTS:
		# few, big puffs where overdraw is the cost; many small streaks where it is not
		_slots.append([
			_make_emitter(Layer.CROWN, 100, SPRAY_TEXTURE),
			_make_emitter(Layer.DROPS, 420, drop_tex),
			_make_emitter(Layer.MIST, 18, SPRAY_TEXTURE),
		])
		_jets.append(_make_emitter(Layer.JET, 90, SPRAY_TEXTURE))
	_stream = _make_emitter(-1, 500, drop_tex)
	if big_splash_sound == null:
		if _placeholder_crash == null:
			_placeholder_crash = _make_crash_stream()
		big_splash_sound = _placeholder_crash
	for i in 2:
		var v := AudioStreamPlayer3D.new()
		v.top_level = true
		v.stream = big_splash_sound
		v.bus = sound_bus
		v.unit_size = 60.0 # a body this size is loud from far off
		v.max_distance = 1800.0
		v.attenuation_filter_cutoff_hz = 3500.0 # far away, only the roar carries
		v.attenuation_filter_db = -18.0
		add_child(v)
		_voices.append(v)
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
	# a slot whose spray is still in the air is never restarted (that would cut
	# it off mid-flight): with none free, the spray already flying covers this one
	var slot: Array = []
	for i in _slots.size():
		var idx := (_next_slot + i) % _slots.size()
		if not _is_busy(_slots[idx][Layer.CROWN]):
			slot = _slots[idx]
			_next_slot = (idx + 1) % _slots.size()
			break
	if slot.is_empty():
		_events.push_back([at.x, at.z, 0.0, minf(size, 1.5), radius]) # the sea still churns there
		while _events.size() > max_events:
			_events.pop_front()
		return
	_since_burst = 0.0
	var k := minf(size, 1.0)
	# heights follow real gravity: v = sqrt(2 g h) up, 2 v / g in the air
	# a slow one stays low, a fast one goes high (height grows with the speed squared)
	var height := HEIGHT_PER_RADIUS * radius * splash_scale * lerpf(0.12, 1.0, k * k)
	var up := sqrt(2.0 * 9.8 * height)
	var wide := radius * sqrt(splash_scale)
	var puff := PUFF_PER_RADIUS * radius * splash_scale
	var amount := clampf(0.45 + 0.55 * size, 0.0, 1.0)
	if size >= big_splash_min_size and radius >= big_splash_min_radius:
		_sound(at, size, radius)

	# crown: the sheet of water round the rim, big chunks; plunging in it is
	# thrown up and outward in a widening cone, bursting out it rides up the body
	var c: GPUParticles3D = slot[Layer.CROWN]
	var pm := c.process_material as ParticleProcessMaterial
	pm.emission_ring_radius = wide * (1.0 if out else 1.4)
	pm.emission_ring_inner_radius = wide * (0.0 if out else 0.9)
	pm.emission_ring_height = wide * 0.3
	pm.spread = 12.0 if out else 22.0
	pm.initial_velocity_min = up * 0.55
	pm.initial_velocity_max = up
	pm.radial_velocity_min = 0.0 if out else up * 0.08
	pm.radial_velocity_max = up * (0.04 if out else 0.2) # a sheet this heavy falls back close round the body
	pm.scale_min = puff * 0.55
	pm.scale_max = puff * 1.15
	_fire(c, at, 2.0 * up / 9.8 + 0.6, amount, wide * 2.0 + up * 0.5 + puff * 2.0, height + puff * 3.0)

	# drops: thousands flung off the crown's edge, small streaks along their
	# path, wider and a little faster than the sheet they tear from
	var d: GPUParticles3D = slot[Layer.DROPS]
	pm = d.process_material as ParticleProcessMaterial
	pm.emission_ring_radius = wide * 1.5
	pm.emission_ring_inner_radius = wide * (0.5 if out else 1.0)
	pm.emission_ring_height = wide * 0.4
	pm.spread = 22.0 if out else 28.0
	pm.initial_velocity_min = up * 0.4
	pm.initial_velocity_max = up * 1.05
	pm.radial_velocity_min = up * 0.03
	pm.radial_velocity_max = up * (0.14 if out else 0.28)
	var drop := clampf(radius * 0.3, 1.0, 4.0) * sqrt(splash_scale) # clumps of drops, big enough to read from afar
	pm.scale_min = drop * 0.5
	pm.scale_max = drop * 1.3
	_fire(d, at, 2.2 * up / 9.8 + 0.4, amount, wide * 2.5 + up * 0.8, height * 1.3 + 20.0)

	# mist: fine spray that hangs, spreads and drifts off long after the rest
	# has fallen; faint, huge, slow
	# (mist hangs far longer than the rest: old mist still drifting is left be)
	var m: GPUParticles3D = slot[Layer.MIST]
	if not _is_busy(m):
		pm = m.process_material as ParticleProcessMaterial
		pm.emission_box_extents = Vector3(wide * 1.6, height * 0.15, wide * 1.6)
		pm.emission_shape_offset = Vector3(0.0, height * 0.08, 0.0)
		pm.initial_velocity_min = up * 0.04
		pm.initial_velocity_max = up * 0.12
		pm.scale_min = puff * 1.8
		pm.scale_max = puff * 3.2
		_fire(m, at, clampf(8.0 + height * 0.04, 8.0, 16.0), amount, wide * 4.0 + puff * 5.0, height * 0.8 + puff * 5.0)

	# the jet: the cavity a plunging body leaves collapses, a moment later, and
	# shoots a column up out of the middle, taller than the crown
	# only a big body leaves a cavity big enough for a jet; from a thin arm it
	# would be a needle
	if not out and radius >= big_splash_min_radius and size >= big_splash_min_size:
		_pending_jets.append([clampf(0.4 * up / 9.8, 0.5, 3.0), at, radius, up, amount])
	_events.push_back([at.x, at.z, 0.0, minf(size, 1.5), radius])
	while _events.size() > max_events:
		_events.pop_front()

## The crash: louder the faster it went through, deeper the bigger the body.
func _sound(at: Vector3, size: float, radius: float) -> void:
	var v := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	v.global_position = at
	v.volume_db = big_splash_volume_db + linear_to_db(clampf(0.4 + 0.6 * minf(size, 1.0), 0.0, 1.0))
	v.pitch_scale = clampf(1.15 - radius * 0.02, 0.75, 1.1) * randf_range(0.94, 1.06)
	v.play()

func _is_busy(p: GPUParticles3D) -> bool:
	return _busy_until.get(p, 0.0) > _clock

func _physics_process(delta: float) -> void:
	_clock += delta
	for i in range(_pending_jets.size() - 1, -1, -1):
		var j: Array = _pending_jets[i]
		j[0] -= delta
		if j[0] > 0.0:
			continue
		_pending_jets.remove_at(i)
		var radius: float = j[2]
		var up: float = j[3] * 0.85 # a bit lower than the crown
		var p: GPUParticles3D = null
		for n in _jets.size():
			var idx := (_next_jet + n) % _jets.size()
			if not _is_busy(_jets[idx]):
				p = _jets[idx]
				_next_jet = (idx + 1) % _jets.size()
				break
		if p == null:
			continue # every jet still flying: never cut one off
		var pm := p.process_material as ParticleProcessMaterial
		pm.emission_sphere_radius = radius * 0.6 * sqrt(splash_scale) # a column as thick as the body, not a needle
		pm.initial_velocity_min = up * 0.55
		pm.initial_velocity_max = up
		var puff := PUFF_PER_RADIUS * radius * splash_scale
		pm.scale_min = puff * 0.6
		pm.scale_max = puff * 1.1
		var h := up * up / (2.0 * 9.8)
		_fire(p, j[1], 2.0 * up / 9.8 + 0.5, j[4], radius * 3.0 + puff * 2.0, h + puff * 3.0)

## Throw one layer: its life, how much of it, and bounds big enough to hold it
## all (top_level: its local space is round `at`).
func _fire(p: GPUParticles3D, at: Vector3, life: float, amount: float, reach: float, height: float) -> void:
	p.lifetime = clampf(life, 0.8, 18.0)
	# it spawns over (1 - explosiveness) of a lifetime, and the last one lives a whole lifetime
	_busy_until[p] = _clock + p.lifetime * (2.0 - p.explosiveness) + 0.1
	p.amount_ratio = amount
	p.visibility_aabb = AABB(Vector3(-reach, -reach * 0.3, -reach), Vector3(reach * 2.0, height + reach * 0.3, reach * 2.0))
	p.global_position = at
	p.restart()

## Water pouring off the parts that are out, over where they are.
func _update_stream(on: bool, mid: Vector3, lo: Vector3, hi: Vector3, pour: float, sea: float) -> void:
	if not on:
		_stream.amount_ratio = 0.0
		return
	_stream.global_position = mid
	var pm := _stream.process_material as ParticleProcessMaterial
	var half := ((hi - lo) * 0.5).max(Vector3.ONE * 2.0)
	pm.emission_box_extents = half
	_stream.visibility_aabb = AABB(-half - Vector3(30, 60, 30), half * 2.0 + Vector3(60, 90, 60))
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
			shapes.append([Vector4(e[0], e[1], r * sqrt(splash_scale) * (2.4 + 0.1 * age), 0.0), Vector4(0.0, 0.0, 2.0, white)])
	return shapes

## ---- particles -----------------------------------------------------------------

## A layer's emitter (layer -1: the steady stream off a wet body).
func _make_emitter(layer: int, count: int, texture: Texture2D) -> GPUParticles3D:
	var burst := layer >= 0
	var streak := layer == Layer.DROPS or layer == -1
	var p := GPUParticles3D.new()
	p.top_level = true # left where the water was, not carried with the body
	p.amount = count
	p.one_shot = burst
	p.emitting = false
	p.randomness = 0.5
	p.local_coords = false
	p.lifetime = 3.0
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-80, -20, -80), Vector3(160, 120, 160))
	match layer:
		Layer.CROWN: p.explosiveness = 0.9
		Layer.JET: p.explosiveness = 0.35 # poured out over a moment: a column, not a ball
		Layer.DROPS: p.explosiveness = 0.8
		Layer.MIST: p.explosiveness = 0.5
		_: p.explosiveness = 0.0
	var pm := ParticleProcessMaterial.new()
	pm.gravity = Vector3(0, -9.8, 0)
	pm.direction = Vector3.UP
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.damping_min = 0.2
	pm.damping_max = 0.8
	match layer:
		Layer.CROWN, Layer.DROPS:
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
			pm.emission_ring_axis = Vector3.UP
			# air holds spray back hard: it rises less far and drops close in
			pm.damping_min = 1.5 if layer == Layer.CROWN else 1.0
			pm.damping_max = 3.0 if layer == Layer.CROWN else 2.0
		Layer.JET:
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
			pm.spread = 9.0
			pm.damping_min = 1.0
			pm.damping_max = 2.0
		Layer.MIST:
			# barely thrown, barely falling: it hangs and spreads
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			pm.spread = 70.0
			pm.gravity = Vector3(0.6, -0.15, 0.3) # a breath of wind carries it off
			pm.damping_min = 0.4
			pm.damping_max = 1.0
		_:
			# streaming off a wet body: let go, it falls
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			pm.direction = Vector3.DOWN
			pm.spread = 15.0
			pm.initial_velocity_min = 0.0
			pm.initial_velocity_max = 3.0
			pm.scale_min = 0.8
			pm.scale_max = 2.2
	if streak:
		pm.particle_flag_align_y = true # stretched along where it flies
		pm.angle_min = 0.0
		pm.angle_max = 0.0
	var curve := Curve.new()
	if layer == Layer.MIST:
		curve.add_point(Vector2(0.0, 0.5))
		curve.add_point(Vector2(1.0, 2.2)) # it spreads as it hangs
	elif streak:
		curve.add_point(Vector2(0.0, 1.0))
		curve.add_point(Vector2(1.0, 0.6)) # drops get smaller as they break up
	else:
		curve.add_point(Vector2(0.0, 0.4))
		curve.add_point(Vector2(0.3, 1.0))
		curve.add_point(Vector2(1.0, 1.8)) # chunks spread into spray as they fall
	var scale_tex := CurveTexture.new()
	scale_tex.curve = curve
	pm.scale_curve = scale_tex
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0.0))
	ramp.set_color(1, Color(1, 1, 1, 0.0))
	if layer == Layer.MIST:
		ramp.add_point(0.2, Color(1, 1, 1, 0.38))
		ramp.add_point(0.65, Color(1, 1, 1, 0.22))
	elif streak:
		ramp.add_point(0.05, Color(1, 1, 1, 1.0))
		ramp.add_point(0.7, Color(1, 1, 1, 0.7))
	else:
		# a sheet thins out and breaks into spray as it falls: opaque going up, faint coming down
		ramp.add_point(0.05, Color(1, 1, 1, 1.0))
		ramp.add_point(0.35, Color(1, 1, 1, 0.8))
		ramp.add_point(0.7, Color(1, 1, 1, 0.22))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	pm.color_ramp = ramp_tex
	p.process_material = pm
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# lit like the rest of the world: bright by day, dim under the moon
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	mat.roughness = 1.0
	mat.metallic_specular = 0.0
	if streak:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y # turns to the eye round its flight line
	else:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true # else each particle's own size is thrown away
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = texture
	mat.albedo_color = spray_color
	mat.disable_receive_shadows = true
	mat.render_priority = 1 # drawn after the water (priority 0), never hidden behind it
	var quad := QuadMesh.new()
	quad.size = Vector2(0.45, 1.1) if streak else Vector2.ONE # a drop is a streak along its path
	quad.material = mat
	p.draw_pass_1 = quad
	add_child(p)
	return p

## A soft round drop (white centre, fading edge), made once.
func _drop_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.45, Color(1, 1, 1, 0.8))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = DROP_TEXTURE_SIZE
	t.height = DROP_TEXTURE_SIZE
	return t

## A big splash generated in code (placeholder until a real recording): the
## low thump of the impact, the roar of a mass of water thrown up and crashing
## down, then a patter of drops falling back. Mono, 4 s.
static func _make_crash_stream() -> AudioStreamWAV:
	var rate := 22050
	var length := rate * 4
	var data := PackedByteArray()
	data.resize(length * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 41
	var low := 0.0
	var low2 := 0.0
	var prev := 0.0
	for i in length:
		var t := float(i) / rate
		var n := rng.randf_range(-1.0, 1.0)
		low += (n - low) * 0.06 # a deep rushing roar
		low2 += (low - low2) * 0.2
		var hiss := n - prev # the fine edge of spray
		prev = n
		# the thump: a falling low tone, gone in half a second
		var thump := sin(TAU * (55.0 - 25.0 * minf(t, 0.5)) * t) * exp(-t * 7.0) * 0.9
		# the roar swells in over a moment and dies away over a couple of seconds
		var roar := low2 * 3.2 * smoothstep(0.0, 0.12, t) * exp(-t * 1.1)
		var spray := hiss * 0.18 * smoothstep(0.0, 0.05, t) * exp(-t * 1.8)
		# then the patter: drops landing, sparser as it ends
		var patter := 0.0
		if t > 0.8 and rng.randf() < 0.012 * exp(-(t - 0.8) * 0.8):
			patter = rng.randf_range(-0.6, 0.6)
		var s := thump + roar + spray + patter * exp(-(t - 0.8) * 0.9)
		s *= 1.0 - smoothstep(3.6, 4.0, t) # no click at the end
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 26000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.data = data
	return wav
