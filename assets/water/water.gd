# Adapted from https://github.com/Lucactus22/GodotOceanWaves_bouyancy/tree/main
@tool
extends MeshInstance3D
## Handles updating the displacement/normal maps for the water material as well as
## managing wave generation pipelines.

const WATER_MAT := preload('res://assets/water/mat_water.tres')
const SPRAY_MAT := preload('res://assets/water/mat_spray.tres')
const WATER_MESH_HIGH8K := preload('res://assets/water/clipmap_high_8k.obj')
const WATER_MESH_HIGH := preload('res://assets/water/clipmap_high.obj')
const WATER_MESH_LOW := preload('res://assets/water/clipmap_low.obj')

enum MeshQuality { LOW, HIGH, HIGH8K }

# ----- Config Variables ----- #
@export_group('Wave Parameters')
@export_color_no_alpha var water_color : Color = Color(0.1, 0.15, 0.18) :
	set(value): water_color = value; RenderingServer.global_shader_parameter_set(&'water_color', water_color)

@export_color_no_alpha var foam_color : Color = Color(0.73, 0.67, 0.62) :
	set(value): foam_color = value; RenderingServer.global_shader_parameter_set(&'foam_color', foam_color)

## The parameters for wave cascades. Each parameter set represents one cascade.
## Recreates all compute piplines whenever a cascade is added or removed!
@export var parameters : Array[WaveCascadeParameters] :
	set(value):
		var new_size := len(value)
		# All below logic is basically just required for using in the editor!
		for i in range(new_size):
			# Ensure all values in the array have an associated cascade
			if not value[i]: value[i] = WaveCascadeParameters.new()
			if not value[i].is_connected(&'scale_changed', _update_scales_uniform):
				value[i].scale_changed.connect(_update_scales_uniform)
			value[i].spectrum_seed = Vector2i(rng.randi_range(-10000, 10000), rng.randi_range(-10000, 10000))
			value[i].time = 120.0 + PI*i # We make sure to choose a time offset such that cascades don't interfere!
		parameters = value
		_setup_wave_generator()
		_update_scales_uniform()

@export_group('Performance Parameters')
@export_enum('128x128:128', '256x256:256', '512x512:512', '1024x1024:1024') var map_size := 1024 :
	set(value):
		map_size = value
		_setup_wave_generator()

@export var mesh_quality := MeshQuality.HIGH8K :
	set(value):
		mesh_quality = value
		if mesh_quality == MeshQuality.LOW:
			mesh = WATER_MESH_LOW
		if mesh_quality == MeshQuality.HIGH:
			mesh = WATER_MESH_HIGH
		if mesh_quality == MeshQuality.HIGH8K:
			mesh = WATER_MESH_HIGH8K

## How many times the wave simulation should update per second.
## Note: This doesn't reduce the frame stutter caused by FFT calculation, only
##       minimizes GPU time taken by it!
@export_range(0, 60) var updates_per_second := 50.0 :
	set(value):
		next_update_time = next_update_time - (1.0/(updates_per_second + 1e-10) - 1.0/(value + 1e-10))
		updates_per_second = value

@export var displacement_updates_per_second := 10

## Full-screen underwater effect (see underwater_effect.gd). Fog colour and absorption are
## taken from the water material's "Underwater" uniforms so they match the surface.
@export_group('Underwater Effect')
@export var underwater_effect_enabled := true :
	set(value):
		underwater_effect_enabled = value
		if underwater_effect: underwater_effect.enabled = value
## How fast light fades per meter of depth. Higher = darker the deeper you sink.
@export_range(0.0, 0.5, 0.005) var depth_darkening := 0.04
## Screen wobble strength (UV units).
@export_range(0.0, 0.02, 0.0005) var underwater_distortion := 0.0025
## Blur radius in pixels.
@export_range(0.0, 6.0, 0.1) var underwater_blur := 1.5
## Width of the dark meniscus line where a wave crosses the lens, in pixels.
@export_range(0.0, 12.0, 0.1) var waterline_width := 2.5
@export_range(0.0, 1.0, 0.01) var underwater_vignette := 0.35

# ----- Bookkeeping Variables ----- #
var wave_generator : WaveGenerator :
	set(value):
		if wave_generator: wave_generator.queue_free()
		wave_generator = value
		add_child(wave_generator)
var rng = RandomNumberGenerator.new()
var time := 0.0
var next_update_time := 0.0

var underwater_effect : UnderwaterEffect
var caustics_effect : CausticsEffect
var _sun : DirectionalLight3D

var displacement_maps := Texture2DArrayRD.new()
var normal_maps := Texture2DArrayRD.new()

var _accumulator = 0.0;
var _displacement_update_rate: float;
var _img: Image = null;
var _img_height: int;
var _img_width: int;
var map_scales : PackedVector4Array;

const MAX_WAVE_BLOCKERS := 8
var _wave_blockers: Array[Node] = []
var _blocker_a := PackedVector4Array()
var _blocker_b := PackedVector4Array()

# ------ Public Interface ----- #
## `masked = false` ignores wave blockers (eg. buoyancy keeps rocking the ship
## even when a calm zone flattens the water visually around it).
func get_wave_height(global_position: Vector3, masked: bool = true) -> float:
	var uv: Vector2 = Vector2(global_position.x, global_position.z)
	var displacement: Vector3 = Vector3.ZERO

	# TODO: Do once for each cascade for best accuracy
	var i = 0;
	var scales: Vector4 = map_scales[i]
	var sample_uv: Vector2 = uv * Vector2(scales.x, scales.y)
	displacement += _sample_displacement(i, sample_uv) * scales.z

	if masked:
		return displacement.y * blocker_mask(global_position)
	return displacement.y

## Combined wave-blocker attenuation at a position (0 = fully calmed, 1 = untouched).
func blocker_mask(global_position: Vector3) -> float:
	var mask := 1.0
	for i in mini(_wave_blockers.size(), MAX_WAVE_BLOCKERS):
		var blocker = _wave_blockers[i]
		if is_instance_valid(blocker):
			mask = minf(mask, blocker.attenuation(global_position))
	return mask

## True inside a HOLE blocker: there is no water surface here at all.
func is_water_hole(global_position: Vector3) -> bool:
	for blocker in _wave_blockers:
		if is_instance_valid(blocker) and blocker.mode == 1 and blocker.contains(global_position):
			return true
	return false

# ------ Private Methods ----- #
func _init() -> void:
	rng.set_seed(1234) # This seed gives big waves!

func _ready() -> void:
	map_scales.resize(len(parameters))

	RenderingServer.global_shader_parameter_set(&'water_color', water_color)
	RenderingServer.global_shader_parameter_set(&'foam_color', foam_color)

	_img = wave_generator.retrieve_displacement_map(0, _img)
	_img_height = _img.get_height()
	_img_width = _img.get_width()
	_displacement_update_rate = (1 / displacement_updates_per_second)
	_setup_underwater_effect()

func _process(delta : float) -> void:
	_update_wave_blockers()
	_update_underwater_effect()
	# TODO: These should probably be the same update
	# Update waves once every 1.0/updates_per_second.
	if updates_per_second == 0 or time >= next_update_time:
		var target_update_delta := 1.0 / (updates_per_second + 1e-10)
		var update_delta := delta if updates_per_second == 0 else target_update_delta + (time - next_update_time)
		next_update_time = time + target_update_delta
		_update_water(update_delta)
	time += delta
	
	# Resample displacement (async: the data arrives a few frames later, which
	# buoyancy easily tolerates, and avoids a full GPU pipeline stall).
	_accumulator += delta;
	if _accumulator >= _displacement_update_rate:
		_accumulator -= _displacement_update_rate
		wave_generator.retrieve_displacement_map_async(0, _on_displacement_map_data)

func _on_displacement_map_data(data: PackedByteArray) -> void:
	var size: int = wave_generator.map_size if is_instance_valid(wave_generator) else 0
	if size == 0 or data.size() != size * size * 8: # stale readback (eg. resolution just changed)
		return
	if _img == null or _img.get_width() != size:
		_img = Image.create_from_data(size, size, false, Image.FORMAT_RGBAH, data)
	else:
		_img.set_data(size, size, false, Image.FORMAT_RGBAH, data)
	_img.convert(Image.FORMAT_RGBAF) # Convert to workable format
	# map_size may have changed (eg. via settings menu); keep cached dims in sync.
	_img_width = size
	_img_height = size

func _setup_wave_generator() -> void:
	if parameters.size() <= 0: return
	for param in parameters:
		param.should_generate_spectrum = true

	wave_generator = WaveGenerator.new()
	wave_generator.map_size = map_size
	wave_generator.init_gpu(maxi(2, parameters.size())) # FIXME: This is needed because my RenderContext API sucks...

	displacement_maps.texture_rd_rid = RID()
	normal_maps.texture_rd_rid = RID()
	displacement_maps.texture_rd_rid = wave_generator.descriptors[&'displacement_map'].rid
	normal_maps.texture_rd_rid = wave_generator.descriptors[&'normal_map'].rid

	RenderingServer.global_shader_parameter_set(&'num_cascades', parameters.size())
	RenderingServer.global_shader_parameter_set(&'displacements', displacement_maps)
	RenderingServer.global_shader_parameter_set(&'normals', normal_maps)

## Adds the caustics and underwater effects to the scene's WorldEnvironment compositor
## (reusing ones that are already there, eg. saved into the scene by the editor).
func _setup_underwater_effect() -> void:
	var scene_root := owner if owner else get_parent()
	if not scene_root: return
	var envs := scene_root.find_children('*', 'WorldEnvironment', true, false)
	if envs.is_empty():
		push_warning('Water: no WorldEnvironment found, underwater effect disabled.')
		return
	var suns := scene_root.find_children('*', 'DirectionalLight3D', true, false)
	if not suns.is_empty(): _sun = suns[0]
	var env : WorldEnvironment = envs[0]
	if not env.compositor: env.compositor = Compositor.new()
	var effects := env.compositor.compositor_effects
	for effect in effects:
		if effect is UnderwaterEffect: underwater_effect = effect
		if effect is CausticsEffect: caustics_effect = effect
	if not caustics_effect:
		caustics_effect = CausticsEffect.new()
		effects.append(caustics_effect)
	if not underwater_effect:
		underwater_effect = UnderwaterEffect.new()
		effects.append(underwater_effect)
	env.compositor.compositor_effects = effects
	underwater_effect.enabled = underwater_effect_enabled

func _update_underwater_effect() -> void:
	if not underwater_effect or not wave_generator: return
	var fx := underwater_effect
	fx.displacement_map = wave_generator.descriptors[&'displacement_map'].rid
	fx.normal_map = wave_generator.descriptors[&'normal_map'].rid
	fx.map_scales = map_scales
	fx.water_level = global_position.y
	var fog = _water_mat_param(&'underwater_color')
	var absorb = _water_mat_param(&'underwater_absorption')
	if fog is Vector3: fog = Color(fog.x, fog.y, fog.z)
	if absorb is Color: absorb = Vector3(absorb.r, absorb.g, absorb.b)
	if fog is Color: fx.fog_color = fog
	if absorb is Vector3: fx.absorption = absorb
	fx.depth_darkening = depth_darkening
	fx.distortion = underwater_distortion
	fx.blur = underwater_blur
	fx.waterline_width = waterline_width
	fx.vignette = underwater_vignette
	if is_instance_valid(_sun) and _sun.visible:
		fx.sun_direction = _sun.global_basis.z # A DirectionalLight3D shines along -Z.
		fx.sun_color = _sun.light_color * _sun.light_energy
	else:
		fx.sun_direction = Vector3.ZERO
	# Light shaft controls live in the water material's "Light Shafts" uniform group.
	var shaft_tint = _water_mat_param(&'shaft_tint')
	if shaft_tint is Vector3: shaft_tint = Color(shaft_tint.x, shaft_tint.y, shaft_tint.z)
	if shaft_tint is Color: fx.shaft_tint = shaft_tint
	fx.shaft_strength = _water_mat_param(&'shaft_strength') if _water_mat_param(&'shafts_enabled') == true else 0.0
	fx.shaft_max_brightness = _water_mat_param(&'shaft_max_brightness')
	fx.shaft_contrast = _water_mat_param(&'shaft_contrast')
	fx.shaft_threshold = _water_mat_param(&'shaft_threshold')
	fx.shaft_softness = _water_mat_param(&'shaft_softness')
	fx.shaft_scale = _water_mat_param(&'shaft_scale')
	fx.shaft_focus_depth = _water_mat_param(&'shaft_focus_depth')
	fx.shaft_max_distance = _water_mat_param(&'shaft_max_distance')
	fx.shaft_scattering = _water_mat_param(&'shaft_scattering')
	fx.shaft_steps = _water_mat_param(&'shaft_quality')

	if not caustics_effect: return
	var cx := caustics_effect
	cx.displacement_map = fx.displacement_map
	cx.normal_map = fx.normal_map
	cx.map_scales = map_scales
	cx.water_level = fx.water_level
	cx.absorption = fx.absorption
	cx.sun_direction = fx.sun_direction
	cx.sun_color = fx.sun_color
	# Caustic controls live in the water material's "Caustics" uniform group.
	cx.enabled = _water_mat_param(&'caustics_enabled') == true
	var tint = _water_mat_param(&'caustic_tint')
	if tint is Vector3: tint = Color(tint.x, tint.y, tint.z)
	if tint is Color: cx.tint = tint
	cx.strength = _water_mat_param(&'caustic_strength')
	cx.max_brightness = _water_mat_param(&'caustic_max_brightness')
	cx.contrast = _water_mat_param(&'caustic_contrast')
	cx.darkening = _water_mat_param(&'caustic_darkening')
	cx.pattern_scale = _water_mat_param(&'caustic_scale')
	cx.focus_depth = _water_mat_param(&'caustic_focus_depth')
	cx.fade_depth = _water_mat_param(&'caustic_fade_depth')
	cx.dispersion = _water_mat_param(&'caustic_dispersion')
	cx.cascade = _water_mat_param(&'caustic_cascade')

## Material value, falling back to the shader default when it was never changed.
func _water_mat_param(param : StringName) -> Variant:
	var value = WATER_MAT.get_shader_parameter(param)
	if value == null:
		value = RenderingServer.shader_get_parameter_default(WATER_MAT.shader.get_rid(), param)
	return value

## Uploads all WaveBlocker nodes to the water shader (they can move each frame,
## eg. a calm zone parented to the ship) and caches them for CPU sampling.
func _update_wave_blockers() -> void:
	_wave_blockers = get_tree().get_nodes_in_group(&'wave_blocker')
	var count := mini(_wave_blockers.size(), MAX_WAVE_BLOCKERS)
	_blocker_a.resize(MAX_WAVE_BLOCKERS)
	_blocker_b.resize(MAX_WAVE_BLOCKERS)
	for i in count:
		_blocker_a[i] = _wave_blockers[i].pack_a()
		_blocker_b[i] = _wave_blockers[i].pack_b()
	WATER_MAT.set_shader_parameter(&'wave_blocker_count', count)
	WATER_MAT.set_shader_parameter(&'wave_blocker_a', _blocker_a)
	WATER_MAT.set_shader_parameter(&'wave_blocker_b', _blocker_b)

func _update_scales_uniform() -> void:
	map_scales.resize(len(parameters))
	for i in len(parameters):
		var params := parameters[i]
		var uv_scale := Vector2.ONE / params.tile_length
		map_scales[i] = Vector4(uv_scale.x, uv_scale.y, params.displacement_scale, params.normal_scale)
	
	# No global shader parameter for arrays :(
	WATER_MAT.set_shader_parameter(&'map_scales', map_scales)
	SPRAY_MAT.set_shader_parameter(&'map_scales', map_scales)

func _update_water(delta : float) -> void:
	if wave_generator == null: _setup_wave_generator()
	wave_generator.update(delta, parameters)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		displacement_maps.texture_rd_rid = RID()
		normal_maps.texture_rd_rid = RID()

func _sample_displacement(cascade: int, uv: Vector2) -> Vector3:
	# Wrap UVs
	uv.x = wrapf(uv.x, 0.0, 1.0)
	uv.y = wrapf(uv.y, 0.0, 1.0)
	
	# Calculate coordinates
	var x: float = uv.x * (_img_width - 1)
	var y: float = uv.y * (_img_width - 1)
	
	var x0 := int(floor(x))
	var y0 := int(floor(y))
	var x1 = min(x0 + 1, _img_width - 1)
	var y1 = min(y0 + 1, _img_width - 1)
	
	var fx := x - x0
	var fy := y - y0
	
	# Get cached pixel data
	var c00: Color = _img.get_pixel(x0, y0) # _cached_displacements[y0 * img_width + x0]
	var c10: Color = _img.get_pixel(x1, y0) # _cached_displacements[y0 * img_width + x1]
	var c01: Color = _img.get_pixel(x0, y1) #_cached_displacements[y1 * img_width + x0]
	var c11: Color = _img.get_pixel(x1, y1) #_cached_displacements[y1 * img_width + x1]
	
	# Bilinear interpolation
	var col_x0 := c00.lerp(c10, fx)
	var col_x1 := c01.lerp(c11, fx)
	var col := col_x0.lerp(col_x1, fy)
	
	return Vector3(col.r, col.g, col.b)
