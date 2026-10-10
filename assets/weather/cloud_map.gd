@tool
class_name CloudMap extends Node
## Renders the sky's clouds into a map of the whole dome (by view direction) on the GPU,
## a slice of it each frame, blending into what was there (see cloud_map.glsl). The sky
## shader then only reads the map. Spreading the work over frames is what pays for the
## clouds' fine detail. Created by the Weather node; reads the cloud settings off the sky
## material every frame, so presets and weather blends drive it as before.

const SHADER_PATH := 'res://assets/shaders/compute/cloud_map.glsl'
const MAP_SIZE := Vector2i(2048, 640)
## How much of a texel each visit replaces (once warmed up). Lower = smoother, slower to follow.
const BLEND := 0.15
## Settings the compute shader reads off the sky material.
const PARAMS : Array[StringName] = [&'coverage', &'density', &'billow', &'cloud_detail',
		&'cloud_erosion', &'cloud_base', &'cloud_thickness', &'cloud_size',
		&'warp_strength', &'wind_speed', &'scud_speed_mult', &'rain_shafts',
		&'wind_direction', &'haze_distance', &'planet_radius',
		&'cloud_lit_color', &'silver_lining', &'cloud_dark_color', &'sun_glow',
		&'zenith_color', &'horizon_color', &'detail_size']

var sky_material : ShaderMaterial
var sun : DirectionalLight3D

var _rd : RenderingDevice
var _shader : RID
var _pipeline : RID
var _map : RID
var _detail : RID
var _sampler : RID
var _params : RID
var _texture := Texture2DRD.new()
var _frame := 0
var _time := 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS # The game starts paused at its menu, under this sky.
	_rd = RenderingServer.get_rendering_device()
	if not _rd: return
	_shader = _rd.shader_create_from_spirv((load(SHADER_PATH) as RDShaderFile).get_spirv())
	if not _shader.is_valid(): return
	_pipeline = _rd.compute_pipeline_create(_shader)

	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = MAP_SIZE.x
	fmt.height = MAP_SIZE.y
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_map = _rd.texture_create(fmt, RDTextureView.new())
	_rd.texture_clear(_map, Color(0, 0, 0, 1), 0, 1, 0, 1)
	_texture.texture_rd_rid = _map
	_detail = _create_detail_noise()

	var s := RDSamplerState.new()
	s.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	s.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	s.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_sampler = _rd.sampler_create(s)
	_params = _rd.uniform_buffer_create(12 * 16)

## Fills the whole map afresh over the next few frames instead of blending into the old clouds
## (for sudden changes, like a preset switch).
func restart() -> void:
	_frame = 0

func _exit_tree() -> void:
	if sky_material:
		RenderingServer.material_set_param(sky_material.get_rid(), &'cloud_map_ready', false)
	if not _rd: return
	_texture.texture_rd_rid = RID()
	for rid in [_params, _sampler, _detail, _map, _shader]:
		if rid.is_valid(): _rd.free_rid(rid) # Freeing the shader also frees its pipeline.
	_rd = null

func _process(delta : float) -> void:
	if not _pipeline.is_valid() or not sky_material: return
	var noise : Texture2D = sky_material.get_shader_parameter(&'noise_texture')
	var noise_rd := RenderingServer.texture_get_rd_texture(noise.get_rid()) if noise else RID()
	if not noise_rd.is_valid(): return # The noise is still being generated.
	_time += delta

	var v := {}
	for key in PARAMS:
		var value : Variant = sky_material.get_shader_parameter(key)
		if value == null: value = RenderingServer.shader_get_parameter_default(sky_material.shader.get_rid(), key)
		v[key] = value
	var lit : Color = (v[&'cloud_lit_color'] as Color).srgb_to_linear()
	var dark : Color = (v[&'cloud_dark_color'] as Color).srgb_to_linear()
	var zenith : Color = (v[&'zenith_color'] as Color).srgb_to_linear()
	var horizon : Color = (v[&'horizon_color'] as Color).srgb_to_linear()
	var to_light := Vector3.UP
	var light_on := 0.0
	var light_color := Color.BLACK
	if sun and sun.is_visible_in_tree() and sun.sky_mode != DirectionalLight3D.SKY_MODE_LIGHT_ONLY:
		to_light = sun.global_transform.basis.z.normalized()
		light_on = 1.0
		light_color = sun.light_color.srgb_to_linear()
	var wind : Vector2 = v[&'wind_direction']
	# A texel is visited every 16th frame; until each has been visited once, replace outright.
	var blend := 1.0 if _frame < 16 else BLEND
	# Texels in (or near) the camera's view are refreshed every round, the rest one round in
	# eight. Before the map has filled, everything is.
	var forward := Vector3.FORWARD
	var cone := -1.0
	var cam := get_viewport().get_camera_3d() if not Engine.is_editor_hint() else null
	if Engine.is_editor_hint():
		var ei := Engine.get_singleton(&'EditorInterface')
		var vp : SubViewport = ei.get_editor_viewport_3d(0) if ei else null
		cam = vp.get_camera_3d() if vp else null
	if cam:
		forward = -cam.global_transform.basis.z
		var half_v := deg_to_rad(cam.fov) * 0.5
		var aspect := float(get_viewport().get_visible_rect().size.x) / maxf(get_viewport().get_visible_rect().size.y, 1.0)
		var half_diag := atan(tan(half_v) * sqrt(1.0 + aspect * aspect))
		cone = cos(minf(half_diag + deg_to_rad(15.0), PI)) # margin for turning
	var all_round := 1.0 if _frame < 16 or (_frame / 16) % 8 == 0 else 0.0
	var data := PackedFloat32Array([
		v[&'coverage'], v[&'density'], v[&'billow'], v[&'cloud_detail'],
		v[&'cloud_erosion'], v[&'cloud_base'], v[&'cloud_thickness'], v[&'cloud_size'],
		v[&'warp_strength'], v[&'wind_speed'], v[&'scud_speed_mult'], v[&'rain_shafts'],
		wind.x, wind.y, v[&'haze_distance'], v[&'planet_radius'],
		lit.r, lit.g, lit.b, v[&'silver_lining'],
		dark.r, dark.g, dark.b, v[&'sun_glow'],
		zenith.r, zenith.g, zenith.b, _time,
		horizon.r, horizon.g, horizon.b, v[&'detail_size'],
		to_light.x, to_light.y, to_light.z, light_on,
		light_color.r, light_color.g, light_color.b, float(_frame % 1000000),
		MAP_SIZE.x, MAP_SIZE.y, blend, cone,
		forward.x, forward.y, forward.z, all_round])
	var bytes := data.to_byte_array()
	_rd.buffer_update(_params, 0, bytes.size(), bytes)

	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, UniformSetCacheRD.get_cache(_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [_map]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_sampler, noise_rd]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_sampler, _detail]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 3, [_params])]), 0)
	# One thread per 4x4 block: each frame refreshes one texel in sixteen.
	_rd.compute_list_dispatch(list, ceili(MAP_SIZE.x / 4.0 / 8.0), ceili(MAP_SIZE.y / 4.0 / 8.0), 1)
	_rd.compute_list_end()
	_frame += 1

	# Handed to the sky through the RenderingServer rather than the material resource, so the
	# editor never saves a GPU texture into the scene or a preset.
	var mat := sky_material.get_rid()
	RenderingServer.material_set_param(mat, &'cloud_map', _texture.get_rid())
	RenderingServer.material_set_param(mat, &'cloud_map_ready', _frame >= 16)

## Seamless fractal 3D noise (64^3) with its mipmaps, generated once on the CPU.
func _create_detail_noise() -> RID:
	const SIZE := 64
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = 1337
	noise.frequency = 1.0 / 16.0
	noise.fractal_octaves = 4
	var slices : Array[Image] = noise.get_seamless_image_3d(SIZE, SIZE, SIZE, false, 0.1, true)
	var level := PackedByteArray()
	for img in slices:
		img.convert(Image.FORMAT_L8)
		level.append_array(img.get_data())
	# Mipmaps: each level averages 2x2x2 voxels of the one above.
	var all := level.duplicate()
	var n := SIZE
	var levels := 1
	while n > 1:
		var m := n / 2
		var next := PackedByteArray()
		next.resize(m * m * m)
		for z in m:
			for y in m:
				for x in m:
					var sum := 0
					for dz in 2:
						for dy in 2:
							var row := ((z * 2 + dz) * n + (y * 2 + dy)) * n + x * 2
							sum += level[row] + level[row + 1]
					next[(z * m + y) * m + x] = sum >> 3
		level = next
		all.append_array(level)
		n = m
		levels += 1
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	fmt.width = SIZE
	fmt.height = SIZE
	fmt.depth = SIZE
	fmt.mipmaps = levels
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return _rd.texture_create(fmt, RDTextureView.new(), [all])

static func _uniform(type : RenderingDevice.UniformType, binding : int, ids : Array) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids: u.add_id(id)
	return u
