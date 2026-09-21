@tool
class_name UnderwaterEffect extends CompositorEffect
## Full-screen underwater effect: absorption/in-scattering, wobble, blur, vignette and a
## waterline that follows the FFT waves across the lens. Runs after the transparent pass so
## the water surface (Snell's window) is included. Configured and fed by water.gd.

const SHADER_PATH := 'res://assets/shaders/compute/underwater_post.glsl'
const COPY_SHADER_PATH := 'res://assets/shaders/compute/image_copy.glsl'
const PARAMS_SIZE := 256 # 2 mat4 + 4 vec4 map scales + 4 vec4, std140.

# ----- Set every frame by water.gd ----- #
var displacement_map := RID()
var map_scales := PackedVector4Array()
var water_level := 0.0
var fog_color := Color(0.04, 0.13, 0.14)
var absorption := Vector3(0.22, 0.06, 0.05)
var depth_darkening := 0.04
var distortion := 0.0025
var blur := 1.5
var waterline_width := 2.5
var vignette := 0.35

var _rd : RenderingDevice
var _shader : RID
var _pipeline : RID
var _copy_shader : RID
var _copy_pipeline : RID
var _linear_sampler : RID
var _repeat_sampler : RID
var _params_buffer : RID
var _temp_tex : RID
var _temp_size := Vector2i.ZERO
var _temp_format := -1

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_init_compute)

func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		for rid in [_temp_tex, _params_buffer, _repeat_sampler, _linear_sampler, _copy_shader, _shader]:
			if rid.is_valid(): _rd.free_rid(rid) # Freeing the shader also frees the pipeline.

func _init_compute() -> void:
	_rd = RenderingServer.get_rendering_device()
	if not _rd: return
	_copy_shader = _rd.shader_create_from_spirv(load(COPY_SHADER_PATH).get_spirv())
	_shader = _rd.shader_create_from_spirv(load(SHADER_PATH).get_spirv())
	if not _shader.is_valid() or not _copy_shader.is_valid(): return
	_copy_pipeline = _rd.compute_pipeline_create(_copy_shader)
	_pipeline = _rd.compute_pipeline_create(_shader)

	var sampler := RDSamplerState.new()
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_linear_sampler = _rd.sampler_create(sampler)
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_repeat_sampler = _rd.sampler_create(sampler)
	_params_buffer = _rd.uniform_buffer_create(PARAMS_SIZE)

func _render_callback(_callback_type : int, render_data : RenderData) -> void:
	if not _pipeline.is_valid() or not displacement_map.is_valid() or not _rd.texture_is_valid(displacement_map):
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data() as RenderSceneDataRD
	if not buffers or not scene_data: return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0: return

	var push := PackedFloat32Array([size.x, size.y, 0.0, 0.0]).to_byte_array()
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		_ensure_temp_texture(color, size)
		_update_params(scene_data, view)
		var groups := Vector3i(ceili(size.x / 8.0), ceili(size.y / 8.0), 1)

		var copy_set := UniformSetCacheRD.get_cache(_copy_shader, 0, [
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color]),
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [_temp_tex]),
		])
		var copy_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(copy_list, _copy_pipeline)
		_rd.compute_list_bind_uniform_set(copy_list, copy_set, 0)
		_rd.compute_list_dispatch(copy_list, groups.x, groups.y, 1)
		_rd.compute_list_end()

		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_linear_sampler, depth]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_linear_sampler, _temp_tex]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_repeat_sampler, displacement_map]),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 4, [_params_buffer]),
		])
		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		_rd.compute_list_set_push_constant(compute_list, push, push.size())
		_rd.compute_list_dispatch(compute_list, groups.x, groups.y, 1)
		_rd.compute_list_end()

func _ensure_temp_texture(color : RID, size : Vector2i) -> void:
	var color_format := _rd.texture_get_format(color)
	if _temp_tex.is_valid() and _temp_size == size and _temp_format == color_format.format: return
	if _temp_tex.is_valid(): _rd.free_rid(_temp_tex)
	var fmt := RDTextureFormat.new()
	fmt.format = color_format.format
	fmt.width = size.x
	fmt.height = size.y
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_temp_tex = _rd.texture_create(fmt, RDTextureView.new())
	_temp_size = size
	_temp_format = color_format.format

func _update_params(scene_data : RenderSceneDataRD, view : int) -> void:
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
	data.append_array([fog_color.r, fog_color.g, fog_color.b, depth_darkening])
	data.append_array([absorption.x, absorption.y, absorption.z, float(cascades)])
	data.append_array([Time.get_ticks_msec() / 1000.0, distortion, blur, waterline_width])
	data.append_array([vignette, water_level, 0.0, 0.0])
	var bytes := data.to_byte_array()
	_rd.buffer_update(_params_buffer, 0, bytes.size(), bytes)

static func _uniform(type : RenderingDevice.UniformType, binding : int, ids : Array) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids: u.add_id(id)
	return u
