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
@export_enum('256x256:256', '512x512:512', '1024x1024:1024') var map_size := 1024 : # 128 breaks the ocean.
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
## How far away big shapes can still be made out as dark silhouettes against the water (m).
## Detail and colour are lost much sooner (the material's underwater_absorption).
@export_range(5.0, 300.0, 1.0) var silhouette_range := 45.0
## Water brightness looking straight down vs straight up (light comes from above, so things
## below you are hidden in the dark and things above you are black shapes against the glow).
@export_range(0.0, 2.0, 0.01) var fog_brightness_down := 0.35
@export_range(0.0, 4.0, 0.01) var fog_brightness_up := 1.6
## Dim the sun and sky light as the camera goes deeper (same rate as depth_darkening), so
## everything around you is lit like it is that deep. Lamps and other local lights stay bright.
@export var dim_sunlight_underwater := true

## Shadows of things above the water (boats, creatures, cliffs) cut through the underwater light
## shafts and caustics. A small hidden camera renders the scene from the sun, depth only.
@export_group('Water Shadows')
@export var water_shadows_enabled := true :
	set(value):
		water_shadows_enabled = value
		if _shadow_viewport: _shadow_viewport.render_target_update_mode = \
				SubViewport.UPDATE_ALWAYS if value else SubViewport.UPDATE_DISABLED
## Shadow map resolution. Higher = sharper shadow edges, slightly slower.
@export_enum('256:256', '512:512', '1024:1024') var water_shadow_resolution := 512 :
	set(value):
		water_shadow_resolution = value
		if _shadow_viewport: _shadow_viewport.size = Vector2i(value, value)
## Width of the square around the camera that receives water shadows (m).
@export_range(16.0, 512.0, 1.0) var water_shadow_coverage := 128.0
## Blur of the shadow edges, in shadow map texels.
@export_range(0.0, 4.0, 0.05) var water_shadow_softness := 1.0
## Render layers that cast water shadows. The water itself lives on WATER_RENDER_LAYER and
## is never part of it.
@export_flags_3d_render var water_shadow_layers := 0x7FFFF :
	set(value):
		water_shadow_layers = value
		if _shadow_camera: _shadow_camera.cull_mask = value & ~WATER_LAYER_BIT

## Foam trails behind boats (see WakeEmitter). A world-space map around the camera.
@export_group('Wakes')
@export var wakes_enabled := true
## Seconds for a wake to fade away.
@export_range(1.0, 120.0, 0.5) var wake_lifetime := 20.0
## How fast a wake widens as it ages (m/s). This is what opens it into a V behind the boat.
@export_range(0.0, 10.0, 0.05) var wake_spread := 1.2
## Width of the square around the camera that keeps wakes (m). Map resolution is fixed at 512.
@export_range(64.0, 1024.0, 1.0) var wake_coverage := 256.0 :
	set(value):
		wake_coverage = value
		if _wake_map: _wake_map.free_resources(); _wake_map = null

## Marine snow: specks hanging in the water around the camera while it is underwater.
@export_group('Marine Snow')
@export var marine_snow_enabled := true
## Number of specks (spread over the box around the camera).
@export_range(0, 8000, 10) var marine_snow_amount := 3000 :
	set(value):
		marine_snow_amount = value
		if _marine_snow: _marine_snow.amount = maxi(value, 1)
## Size of the box of specks around the camera (m).
@export var marine_snow_box := Vector3(24, 16, 24)
## Speck size (m).
@export_range(0.005, 0.3, 0.001) var marine_snow_size := 0.07
@export_range(0.0, 2.0, 0.01) var marine_snow_drift := 0.12
@export_range(0.0, 1.0, 0.005) var marine_snow_sink := 0.04
@export var marine_snow_color := Color(0.75, 0.82, 0.78)
## Square specks (PS1 look) instead of round ones.
@export var marine_snow_square := true
## Specks further than this fade out (m).
@export_range(1.0, 50.0, 0.5) var marine_snow_fade_distance := 12.0

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
var _shadow_viewport : SubViewport
var _shadow_camera : Camera3D
var _shadow_capture : WaterShadowCapture
var _wake_map : WakeMap
var _marine_snow : GPUParticles3D
# Sunlight dimming underwater: the sun's and environment's own values, restored at the surface.
var _sun_energy_base := -1.0
var _env : Environment
var _env_ambient_base := -1.0
var _env_sky_energy_base := -1.0
const WAKE_MAP_RESOLUTION := 512

var displacement_maps := Texture2DArrayRD.new()
var normal_maps := Texture2DArrayRD.new()

var _accumulator = 0.0;
var _displacement_update_rate: float;
var _img: Image = null;
var _img_height: int;
var _img_width: int;
var map_scales : PackedVector4Array;

const MAX_WAVE_BLOCKERS := 8
const WATER_RENDER_LAYER := 20 # Render layer of the water surface/spray (skipped by the sun shadow camera).
const WATER_LAYER_BIT := 1 << (WATER_RENDER_LAYER - 1)
const MAX_WATER_SHAPES := 16 # Matches the water shader and effect arrays.
var _water_shapes_a := PackedVector4Array()
var _water_shapes_b := PackedVector4Array()
var _water_shape_count := 0
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

	# Domes/swells from WaterDeformer nodes lift the surface and calm the waves riding on it.
	var shape := water_shapes_eval(Vector2(global_position.x, global_position.z))
	var waves := displacement.y * (1.0 - shape.y)
	if masked:
		waves *= blocker_mask(global_position)
	return waves + shape.x

## Water shapes (from WaterDeformer nodes) at a world XZ position: (height offset, calm).
## Must mirror water_shapes_eval() in the water shader.
func water_shapes_eval(p: Vector2) -> Vector2:
	var result := Vector2.ZERO
	for i in _water_shape_count:
		var a := _water_shapes_a[i]
		var b := _water_shapes_b[i]
		var rel := p - Vector2(a.x, a.y)
		if b.z < 0.5: # Dome
			var q := rel.length_squared() / (a.z * a.z)
			if q > 16.0: continue
			var e := exp(-q)
			result.x += a.w * e * (1.0 - b.x * q)
			result.y = maxf(result.y, b.y * e)
		elif b.z < 1.5: # Ring swell (boil patches, b.z = 2, are foam only)
			var u := (rel.length() - a.z) / b.x
			if absf(u) > 4.0: continue
			result.x += a.w * exp(-u * u)
	return result

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

func _enter_tree() -> void:
	# Lets floating things find the ocean without a hand-wired NodePath (see ferry.gd).
	add_to_group(&'water')

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
	_update_water_shapes(delta)
	_update_underwater_effect()
	_update_wakes(delta)
	_update_marine_snow()
	_update_depth_lighting()
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
	_setup_water_shadows()

## Hidden orthographic camera looking down the sunbeams. Renders unshaded, without the scene's
## environment or effects, and hands its depth to the shafts/caustics via WaterShadowCapture.
func _setup_water_shadows() -> void:
	if _shadow_viewport: return
	_shadow_viewport = SubViewport.new()
	_shadow_viewport.name = 'WaterShadowViewport'
	_shadow_viewport.size = Vector2i(water_shadow_resolution, water_shadow_resolution)
	_shadow_viewport.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	_shadow_viewport.positional_shadow_atlas_size = 0
	_shadow_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_shadow_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if water_shadows_enabled else SubViewport.UPDATE_DISABLED
	_shadow_camera = Camera3D.new()
	_shadow_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_shadow_camera.near = 0.5
	_shadow_camera.far = 800.0
	_shadow_camera.cull_mask = water_shadow_layers & ~WATER_LAYER_BIT
	# The water surface and spray are transparent (they'd never cast a shadow) but expensive,
	# so they go on their own layer that the sun camera skips. Normal cameras still see it.
	layers = WATER_LAYER_BIT
	for child in get_children():
		if child is GPUParticles3D: child.layers = WATER_LAYER_BIT
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	_shadow_camera.environment = env
	_shadow_capture = WaterShadowCapture.new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [_shadow_capture]
	_shadow_camera.compositor = compositor
	_shadow_viewport.add_child(_shadow_camera)
	add_child(_shadow_viewport, false, Node.INTERNAL_MODE_BACK) # Internal: never saved into scenes.

func _update_water_shadows(fx_list : Array) -> void:
	var active := water_shadows_enabled and _shadow_camera != null and is_instance_valid(_sun) and _sun.visible
	for fx in fx_list:
		if not fx: continue
		fx.shadow_texture = _shadow_capture.shadow_texture if active else RID()
	if not active: return
	var view_camera := get_viewport().get_camera_3d()
	if Engine.is_editor_hint() and Engine.has_singleton(&'EditorInterface'):
		# Looked up dynamically: EditorInterface doesn't exist in exported builds.
		var editor_vp = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0)
		if editor_vp: view_camera = editor_vp.get_camera_3d()
	if not view_camera: return

	var to_sun := _sun.global_basis.z.normalized()
	var basis := Basis.looking_at(-to_sun, Vector3.UP if absf(to_sun.y) < 0.99 else Vector3.FORWARD)
	# Centre on the camera's spot at water level, snapped to whole texels so edges don't shimmer.
	var center := view_camera.global_position
	center.y = global_position.y
	var texel := water_shadow_coverage / float(water_shadow_resolution)
	var r := snappedf(center.dot(basis.x), texel)
	var u := snappedf(center.dot(basis.y), texel)
	var f := center.dot(-basis.z)
	var snapped := basis.x * r + basis.y * u - basis.z * f
	_shadow_camera.size = water_shadow_coverage
	_shadow_camera.global_transform = Transform3D(basis, snapped + to_sun * 400.0)
	for fx in fx_list:
		if not fx: continue
		fx.shadow_transform = _shadow_camera.global_transform
		fx.shadow_half_size = water_shadow_coverage * 0.5
		fx.shadow_softness = water_shadow_softness

func _update_underwater_effect() -> void:
	if not underwater_effect or not wave_generator: return
	var fx := underwater_effect
	fx.displacement_map = wave_generator.descriptors[&'displacement_map'].rid
	fx.normal_map = wave_generator.descriptors[&'normal_map'].rid
	fx.map_scales = map_scales
	fx.water_level = global_position.y
	fx.shape_count = _water_shape_count
	fx.shape_a = _water_shapes_a
	fx.shape_b = _water_shapes_b
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
	fx.silhouette_range = silhouette_range
	fx.fog_down = fog_brightness_down
	fx.fog_up = fog_brightness_up
	if is_instance_valid(_sun) and _sun.visible:
		fx.sun_direction = _sun.global_basis.z # A DirectionalLight3D shines along -Z.
		fx.sun_color = _sun.light_color * _sun_base_energy()
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

	_update_water_shadows([underwater_effect, caustics_effect])
	if not caustics_effect: return
	var cx := caustics_effect
	cx.displacement_map = fx.displacement_map
	cx.normal_map = fx.normal_map
	cx.map_scales = map_scales
	cx.shape_count = _water_shape_count
	cx.shape_a = _water_shapes_a
	cx.shape_b = _water_shapes_b
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

## Advances all WaterDeformer nodes and uploads their shapes to the water shader. Effects and
## get_wave_height() read the same packed arrays, so everything agrees on the water height.
func _update_water_shapes(delta : float) -> void:
	_water_shapes_a.resize(MAX_WATER_SHAPES)
	_water_shapes_b.resize(MAX_WATER_SHAPES)
	var count := 0
	for deformer in get_tree().get_nodes_in_group(&'water_deformer'):
		deformer.update_state(delta, global_position.y)
		for shape in deformer.pack_shapes():
			if count >= MAX_WATER_SHAPES: break
			_water_shapes_a[count] = shape[0]
			_water_shapes_b[count] = shape[1]
			count += 1
	_water_shape_count = count
	WATER_MAT.set_shader_parameter(&'water_shape_count', count)
	WATER_MAT.set_shader_parameter(&'water_shape_a', _water_shapes_a)
	WATER_MAT.set_shader_parameter(&'water_shape_b', _water_shapes_b)

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
		if _wake_map: _wake_map.free_resources()

var _quality_base := {}

## Water effects quality preset from the settings menu: 0 = low, 1 = medium, 2 = high (the values
## set in the scene and the water material). Lower levels scale down from those values.
##   low:    no water shadows, no caustics, coarse light shafts, fewer foam samples and specks
##   medium: small shadow map, lighter shafts/foam/specks
func set_effects_quality(level : int) -> void:
	level = clampi(level, 0, 2)
	if _quality_base.is_empty():
		_quality_base = {
			shadows = water_shadows_enabled,
			shadow_res = water_shadow_resolution,
			snow = marine_snow_amount,
			caustics = _water_mat_param(&'caustics_enabled'),
			shaft_quality = _water_mat_param(&'shaft_quality'),
			foam_samples = _water_mat_param(&'contact_foam_samples'),
		}
	var scale : float = [0.3, 0.6, 1.0][level]
	water_shadows_enabled = _quality_base.shadows and level > 0
	water_shadow_resolution = _quality_base.shadow_res if level == 2 else mini(_quality_base.shadow_res, 256)
	marine_snow_amount = maxi(int(_quality_base.snow * scale), 1)
	WATER_MAT.set_shader_parameter(&'caustics_enabled', _quality_base.caustics == true and level > 0)
	WATER_MAT.set_shader_parameter(&'shaft_quality', maxi(int(_quality_base.shaft_quality * scale), 6))
	WATER_MAT.set_shader_parameter(&'contact_foam_samples', maxi(int(_quality_base.foam_samples * scale), 4))

func _sun_base_energy() -> float:
	return _sun_energy_base if _sun_energy_base >= 0.0 else _sun.light_energy

## Sunlight and skylight only reach the depth through the water: dim them as the camera sinks.
## The originals are remembered and put back when the camera surfaces (and in the editor).
func _update_depth_lighting() -> void:
	if Engine.is_editor_hint() or not is_instance_valid(_sun): return
	if not _env:
		var envs := (owner if owner else get_parent()).find_children('*', 'WorldEnvironment', true, false)
		if not envs.is_empty(): _env = envs[0].environment
	if _sun_energy_base < 0.0:
		_sun_energy_base = _sun.light_energy
		if _env:
			_env_ambient_base = _env.ambient_light_energy
			_env_sky_energy_base = _env.background_energy_multiplier
	var cam := _view_camera()
	var depth := 0.0
	if dim_sunlight_underwater and cam:
		depth = maxf(get_wave_height(cam.global_position, false) - cam.global_position.y, 0.0)
	var light := exp(-depth_darkening * depth)
	_sun.light_energy = _sun_energy_base * light
	if _env:
		_env.ambient_light_energy = _env_ambient_base * light
		_env.background_energy_multiplier = _env_sky_energy_base * light

func _view_camera() -> Camera3D:
	var cam := get_viewport().get_camera_3d()
	if Engine.is_editor_hint() and Engine.has_singleton(&'EditorInterface'):
		var editor_vp = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0)
		if editor_vp: cam = editor_vp.get_camera_3d()
	return cam

## Keeps the marine snow box centred on the camera; hidden above water.
func _update_marine_snow() -> void:
	var cam := _view_camera()
	var active := marine_snow_enabled and cam != null and cam.global_position.y < get_wave_height(cam.global_position, false)
	if not _marine_snow:
		if not active: return
		_marine_snow = GPUParticles3D.new()
		_marine_snow.name = 'MarineSnow'
		_marine_snow.amount = maxi(marine_snow_amount, 1)
		_marine_snow.lifetime = 600.0
		_marine_snow.explosiveness = 1.0 # All specks exist at once; they never die, just wrap around.
		_marine_snow.local_coords = false
		_marine_snow.fixed_fps = 0
		_marine_snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_marine_snow.layers = WATER_LAYER_BIT # Skipped by the sun shadow camera.
		var pm := ShaderMaterial.new()
		pm.shader = preload('res://assets/shaders/particles/marine_snow.gdshader')
		_marine_snow.process_material = pm
		var mat := ShaderMaterial.new()
		mat.shader = preload('res://assets/shaders/particles/water_speck.gdshader')
		var quad := QuadMesh.new()
		quad.material = mat
		_marine_snow.draw_pass_1 = quad
		add_child(_marine_snow, false, Node.INTERNAL_MODE_BACK) # Internal: never saved into scenes.
	_marine_snow.visible = active
	if not active: return
	var center := cam.global_position
	_marine_snow.global_position = center
	_marine_snow.visibility_aabb = AABB(-marine_snow_box * 0.5 - Vector3.ONE, marine_snow_box + Vector3.ONE * 2.0)
	var pm := _marine_snow.process_material as ShaderMaterial
	pm.set_shader_parameter(&'center', center)
	pm.set_shader_parameter(&'box_size', marine_snow_box)
	pm.set_shader_parameter(&'size', marine_snow_size)
	pm.set_shader_parameter(&'drift_speed', marine_snow_drift)
	pm.set_shader_parameter(&'sink_speed', marine_snow_sink)
	var mat := (_marine_snow.draw_pass_1 as QuadMesh).material as ShaderMaterial
	mat.set_shader_parameter(&'color', marine_snow_color)
	mat.set_shader_parameter(&'fade_distance', marine_snow_fade_distance)
	mat.set_shader_parameter(&'square', marine_snow_square)
	mat.set_shader_parameter(&'water_level', global_position.y)
	mat.set_shader_parameter(&'depth_darkening', depth_darkening)

## Stamps every WakeEmitter's path into the wake map and hands it to the water material.
func _update_wakes(delta : float) -> void:
	if not wakes_enabled:
		WATER_MAT.set_shader_parameter(&'wake_map_rect', Vector4.ZERO)
		return
	if not _wake_map:
		_wake_map = WakeMap.new(WAKE_MAP_RESOLUTION, wake_coverage)
		WATER_MAT.set_shader_parameter(&'wake_map', _wake_map.texture)
	var view_camera := get_viewport().get_camera_3d()
	if Engine.is_editor_hint() and Engine.has_singleton(&'EditorInterface'):
		var editor_vp = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0)
		if editor_vp: view_camera = editor_vp.get_camera_3d()
	var center := view_camera.global_position if view_camera else global_position
	var stamps := []
	for emitter in get_tree().get_nodes_in_group(&'wake_emitter'):
		var stamp : Array = emitter.get_stamp(delta, get_wave_height(emitter.global_position, false))
		if not stamp.is_empty(): stamps.append(stamp)
	_wake_map.update(delta, center, stamps, wake_lifetime, wake_spread)
	WATER_MAT.set_shader_parameter(&'wake_map_rect', _wake_map.rect)

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
