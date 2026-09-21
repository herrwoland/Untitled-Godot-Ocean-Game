@tool
class_name WaterShadowCapture extends CompositorEffect
## Runs on the water's sun shadow camera (see water.gd): turns its depth buffer into a linear
## depth map that the light shafts and caustics use to find what blocks the sun above the water.

const SHADER_PATH := 'res://assets/shaders/compute/depth_to_linear.glsl'

## Linear depth (m) along the shadow camera's view direction. Read by the other water effects.
var shadow_texture := RID()

var _rd : RenderingDevice
var _shader : RID
var _pipeline : RID
var _sampler : RID
var _size := Vector2i.ZERO

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE
	RenderingServer.call_on_render_thread(_init_compute)

func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		for rid in [shadow_texture, _sampler, _shader]:
			if rid.is_valid(): _rd.free_rid(rid) # Freeing the shader also frees the pipeline.

func _init_compute() -> void:
	_rd = RenderingServer.get_rendering_device()
	if not _rd: return
	_shader = _rd.shader_create_from_spirv(load(SHADER_PATH).get_spirv())
	if not _shader.is_valid(): return
	_pipeline = _rd.compute_pipeline_create(_shader)
	var sampler := RDSamplerState.new()
	_sampler = _rd.sampler_create(sampler)

func _render_callback(_callback_type : int, render_data : RenderData) -> void:
	if not _pipeline.is_valid(): return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data() as RenderSceneDataRD
	if not buffers or not scene_data: return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0: return
	if not shadow_texture.is_valid() or size != _size:
		if shadow_texture.is_valid(): _rd.free_rid(shadow_texture)
		var fmt := RDTextureFormat.new()
		fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
		fmt.width = size.x
		fmt.height = size.y
		fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		shadow_texture = _rd.texture_create(fmt, RDTextureView.new())
		_size = size

	var inv_proj := scene_data.get_view_projection(0).inverse()
	var push := PackedFloat32Array()
	for column in [inv_proj.x, inv_proj.y, inv_proj.z, inv_proj.w]:
		push.append_array([column.x, column.y, column.z, column.w])
	var bytes := push.to_byte_array()

	var u_out := RDUniform.new()
	u_out.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_out.binding = 0
	u_out.add_id(shadow_texture)
	var u_depth := RDUniform.new()
	u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth.binding = 1
	u_depth.add_id(_sampler)
	u_depth.add_id(buffers.get_depth_layer(0))
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [u_out, u_depth])

	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	_rd.compute_list_set_push_constant(compute_list, bytes, bytes.size())
	_rd.compute_list_dispatch(compute_list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	_rd.compute_list_end()
