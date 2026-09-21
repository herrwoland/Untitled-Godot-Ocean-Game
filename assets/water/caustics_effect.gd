@tool
class_name CausticsEffect extends CompositorEffect
## Caustics on everything opaque below the FFT water surface. Runs before the transparent
## pass so they show from above (through the water's refraction) and from below. Configured
## and fed by water.gd, like UnderwaterEffect.

const FOCUS_SHADER_PATH := 'res://assets/shaders/compute/caustics.glsl'
const APPLY_SHADER_PATH := 'res://assets/shaders/compute/caustics_apply.glsl'
const PARAMS_SIZE := 288 # 2 mat4 + 4 vec4 map scales + 6 vec4, std140.
const FOCUS_MAP_SIZE := 512
const WATER_IOR := 1.333

# ----- Set every frame by water.gd ----- #
var displacement_map := RID()
var normal_map := RID()
var map_scales := PackedVector4Array()
var water_level := 0.0
var absorption := Vector3(0.22, 0.06, 0.05)
var sun_direction := Vector3.ZERO # Towards the sun. Zero = no caustics.
var sun_color := Color.WHITE      # Already multiplied by energy.
var strength := 0.6
var tint := Color.WHITE
var max_brightness := 1.5
var contrast := 1.0
var darkening := 0.5
var pattern_scale := 1.0
var focus_depth := 6.0
var fade_depth := 9.0
var dispersion := 0.004
var cascade := -1 # Which wave cascade makes the caustics. -1 = the smallest (last) one.

var _rd : RenderingDevice
var _focus_shader : RID
var _focus_pipeline : RID
var _apply_shader : RID
var _apply_pipeline : RID
var _linear_sampler : RID
var _repeat_sampler : RID
var _params_buffer : RID
var _focus_tex : RID

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	RenderingServer.call_on_render_thread(_init_compute)

func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		for rid in [_focus_tex, _params_buffer, _repeat_sampler, _linear_sampler, _apply_shader, _focus_shader]:
			if rid.is_valid(): _rd.free_rid(rid) # Freeing a shader also frees its pipeline.

func _init_compute() -> void:
	_rd = RenderingServer.get_rendering_device()
	if not _rd: return
	_focus_shader = _rd.shader_create_from_spirv(load(FOCUS_SHADER_PATH).get_spirv())
	_apply_shader = _rd.shader_create_from_spirv(load(APPLY_SHADER_PATH).get_spirv())
	if not _focus_shader.is_valid() or not _apply_shader.is_valid(): return
	_focus_pipeline = _rd.compute_pipeline_create(_focus_shader)
	_apply_pipeline = _rd.compute_pipeline_create(_apply_shader)

	var sampler := RDSamplerState.new()
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_linear_sampler = _rd.sampler_create(sampler)
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_repeat_sampler = _rd.sampler_create(sampler)
	_params_buffer = _rd.uniform_buffer_create(PARAMS_SIZE)

	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	fmt.width = FOCUS_MAP_SIZE
	fmt.height = FOCUS_MAP_SIZE
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_focus_tex = _rd.texture_create(fmt, RDTextureView.new())

func _render_callback(_callback_type : int, render_data : RenderData) -> void:
	if not _apply_pipeline.is_valid() or sun_direction == Vector3.ZERO or strength <= 0.0 or map_scales.is_empty():
		return
	for rid in [displacement_map, normal_map]:
		if not rid.is_valid() or not _rd.texture_is_valid(rid): return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data() as RenderSceneDataRD
	if not buffers or not scene_data: return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0: return

	var layer := _cascade_index()
	_update_focus_map(layer)
	var push := PackedFloat32Array([size.x, size.y, 0.0, 0.0]).to_byte_array()
	for view in buffers.get_view_count():
		_update_params(scene_data, view, layer)
		var uniform_set := UniformSetCacheRD.get_cache(_apply_shader, 0, [
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [buffers.get_color_layer(view)]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_linear_sampler, buffers.get_depth_layer(view)]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_repeat_sampler, displacement_map]),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 4, [_params_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 5, [_repeat_sampler, _focus_tex]),
		])
		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _apply_pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		_rd.compute_list_set_push_constant(compute_list, push, push.size())
		_rd.compute_list_dispatch(compute_list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		_rd.compute_list_end()

func _cascade_index() -> int:
	var count := mini(map_scales.size(), 4)
	return count - 1 if cascade < 0 or cascade >= count else cascade

func _update_focus_map(layer : int) -> void:
	var scales := map_scales[layer]
	var tile_meters := 1.0 / maxf(scales.x, 1e-6)
	var bend := 1.0 - 1.0 / WATER_IOR # Sideways bend of a refracted beam per unit of slope.
	# Differenced over a single texel: caustics want every ripple.
	var push := PackedFloat32Array([tile_meters / FOCUS_MAP_SIZE, scales.w, focus_depth * bend, FOCUS_MAP_SIZE, layer, 1.0, 0.0, 0.0]).to_byte_array()
	var uniform_set := UniformSetCacheRD.get_cache(_focus_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [_focus_tex]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_repeat_sampler, normal_map]),
	])
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _focus_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	_rd.compute_list_set_push_constant(compute_list, push, push.size())
	_rd.compute_list_dispatch(compute_list, FOCUS_MAP_SIZE / 8, FOCUS_MAP_SIZE / 8, 1)
	_rd.compute_list_end()

func _update_params(scene_data : RenderSceneDataRD, view : int, layer : int) -> void:
	var data := PackedFloat32Array()
	var inv_proj := scene_data.get_view_projection(view).inverse()
	for column in [inv_proj.x, inv_proj.y, inv_proj.z, inv_proj.w]:
		data.append_array([column.x, column.y, column.z, column.w])
	var cam := scene_data.get_cam_transform()
	data.append_array([cam.basis.x.x, cam.basis.x.y, cam.basis.x.z, 0.0])
	data.append_array([cam.basis.y.x, cam.basis.y.y, cam.basis.y.z, 0.0])
	data.append_array([cam.basis.z.x, cam.basis.z.y, cam.basis.z.z, 0.0])
	data.append_array([cam.origin.x, cam.origin.y, cam.origin.z, 1.0])
	var cascades := mini(map_scales.size(), 4)
	for i in 4:
		var s := map_scales[i] if i < cascades else Vector4.ZERO
		data.append_array([s.x, s.y, s.z, s.w])
	var sun := sun_direction.normalized()
	data.append_array([sun.x, sun.y, sun.z, strength])
	data.append_array([sun_color.r, sun_color.g, sun_color.b, focus_depth])
	data.append_array([absorption.x, absorption.y, absorption.z, float(cascades)])
	data.append_array([water_level, float(layer), dispersion, 0.0])
	data.append_array([tint.r, tint.g, tint.b, max_brightness])
	data.append_array([contrast, darkening, pattern_scale, fade_depth])
	var bytes := data.to_byte_array()
	_rd.buffer_update(_params_buffer, 0, bytes.size(), bytes)

static func _uniform(type : RenderingDevice.UniformType, binding : int, ids : Array) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids: u.add_id(id)
	return u
