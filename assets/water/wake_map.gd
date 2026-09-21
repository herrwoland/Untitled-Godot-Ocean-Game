class_name WakeMap extends RefCounted
## World-space trail map of ship wakes around the camera (r = foam, g = churn), updated on the
## GPU every frame from WakeEmitter nodes and read by the water shader. Owned by water.gd.

const SHADER_PATH := 'res://assets/shaders/compute/wake_update.glsl'
const MAX_STAMPS := 16
const STAMPS_SIZE := 32 + MAX_STAMPS * 32 # 2 vec4 + 2x16 vec4, std140.

## Texture the water material samples.
var texture := Texture2DRD.new()
## World xz of the map's corner and its size (m), for the shader: (x, z, size, 1 = active).
var rect := Vector4.ZERO

var _rd : RenderingDevice
var _scroll_shader : RID
var _update_shader : RID
var _scroll_pipeline : RID
var _update_pipeline : RID
var _tex_a : RID # The map (sampled by the water).
var _tex_b : RID # Scratch copy.
var _stamps_buffer : RID
var _resolution := 0
var _coverage := 0.0
var _origin_texel := Vector2i.ZERO
var _valid := false

func _init(resolution : int, coverage : float) -> void:
	_rd = RenderingServer.get_rendering_device()
	if not _rd: return
	var file : RDShaderFile = load(SHADER_PATH)
	_scroll_shader = _rd.shader_create_from_spirv(file.get_spirv(&'scroll'))
	_update_shader = _rd.shader_create_from_spirv(file.get_spirv(&'update'))
	if not _scroll_shader.is_valid() or not _update_shader.is_valid(): return
	_scroll_pipeline = _rd.compute_pipeline_create(_scroll_shader)
	_update_pipeline = _rd.compute_pipeline_create(_update_shader)
	_resolution = resolution
	_coverage = coverage
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = resolution
	fmt.height = resolution
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var zeros := PackedByteArray()
	zeros.resize(resolution * resolution * 8)
	_tex_a = _rd.texture_create(fmt, RDTextureView.new(), [zeros])
	_tex_b = _rd.texture_create(fmt, RDTextureView.new(), [zeros])
	_stamps_buffer = _rd.uniform_buffer_create(STAMPS_SIZE)
	texture.texture_rd_rid = _tex_a
	_valid = true

func free_resources() -> void:
	if not _rd: return
	texture.texture_rd_rid = RID()
	for rid in [_stamps_buffer, _tex_b, _tex_a, _update_shader, _scroll_shader]:
		if rid.is_valid(): _rd.free_rid(rid) # Freeing a shader also frees its pipeline.
	_valid = false

## Advances the map one frame. `stamps` holds [Vector4(x0, z0, x1, z1), Vector4(half width,
## foam, churn, edge bias)] pairs.
func update(delta : float, center : Vector3, stamps : Array, lifetime : float, spread : float) -> void:
	if not _valid: return
	var texel := _coverage / _resolution
	# Keep the camera in the middle, moving the map in whole texels so the trail doesn't smear.
	var origin := Vector2i(floori(center.x / texel) - _resolution / 2, floori(center.z / texel) - _resolution / 2)
	var shift := origin - _origin_texel
	if absi(shift.x) >= _resolution or absi(shift.y) >= _resolution:
		shift = Vector2i(_resolution, _resolution) # Teleported: start fresh.
	_origin_texel = origin
	rect = Vector4(origin.x * texel, origin.y * texel, _coverage, 1.0)

	var data := PackedFloat32Array()
	# Fade so that foam is ~5% after `lifetime`; churn lingers twice as long.
	var fade := exp(-3.0 * delta / maxf(lifetime, 0.1))
	var churn_fade := exp(-1.5 * delta / maxf(lifetime, 0.1))
	var count := mini(stamps.size(), MAX_STAMPS)
	data.append_array([fade, churn_fade, clampf(spread * delta / texel, 0.0, 0.25), float(count)])
	data.append_array([rect.x, rect.y, _coverage, float(_resolution)])
	for part in 2:
		for i in MAX_STAMPS:
			var v : Vector4 = stamps[i][part] if i < count else Vector4.ZERO
			data.append_array([v.x, v.y, v.z, v.w])
	var bytes := data.to_byte_array()
	_rd.buffer_update(_stamps_buffer, 0, bytes.size(), bytes)

	var groups := ceili(_resolution / 8.0)
	var push := PackedInt32Array([shift.x, shift.y, 0, 0]).to_byte_array()
	var list := _rd.compute_list_begin()
	# A -> B (scrolled), then B -> A (spread, fade, stamp).
	_rd.compute_list_bind_compute_pipeline(list, _scroll_pipeline)
	_rd.compute_list_bind_uniform_set(list, UniformSetCacheRD.get_cache(_scroll_shader, 0, [
		_image(0, _tex_a), _image(1, _tex_b)]), 0)
	_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_bind_compute_pipeline(list, _update_pipeline)
	var u_stamps := RDUniform.new()
	u_stamps.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u_stamps.binding = 2
	u_stamps.add_id(_stamps_buffer)
	_rd.compute_list_bind_uniform_set(list, UniformSetCacheRD.get_cache(_update_shader, 0, [
		_image(0, _tex_b), _image(1, _tex_a), u_stamps]), 0)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_end()

static func _image(binding : int, rid : RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(rid)
	return u
