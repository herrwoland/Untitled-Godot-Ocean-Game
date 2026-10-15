class_name SubmergeLens extends CanvasLayer
## Screen-space layer for the moment of going under (submerge_lens.gdshader): as the surface
## reaches the lens, the dark water in front of it rises up the screen from the bottom; once
## under, the exposure is near to black and comes back, and beads of air are left on the lens.
## Sits over the 3D image, water and underwater effect included, and under the PS1
## post-process. Made and fed by water.gd; hidden (and free) the rest of the time.

const SHADER := preload('res://assets/shaders/post/submerge_lens.gdshader')

var enabled := true # The beads; the rest has its own dials.
var duration := 0.6
var count := 9
var bead_size := 0.009
var refraction := 0.6
var brightness := 0.9
var tint := Color(0.75, 0.85, 0.9)
var blur := 2.0
var rise := 0.25
var wobble := 1.0
var exposure_dip := 0.97
var exposure_hold := 0.1
var exposure_time := 0.5
var wipe_height := 0.18 # (m) above the surface the lens is when the water starts up the screen.
var wipe_wave := 0.07
var wipe_softness := 0.06
var wipe_sheen := 0.4
var min_air_time := 0.3 # Bobbing at the surface doesn't leave beads again and again.

var _rect : ColorRect
var _age := INF # Since going under.
var _bead_age := INF
var _was_under := false
var _air_time := 0.0

func _init() -> void:
	name = 'SubmergeLens'
	layer = -3 # Under the rain drops (-2) and the PS1 post-process (-1).
	visible = false
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	_rect.material = mat
	add_child(_rect)

## `submersion`: how far the lens is under the surface (m, negative above it). `dry`: inside a
## hull or the like, where the lens is never underwater.
func update(submersion : float, dry : bool, delta : float) -> void:
	var underwater := submersion > 0.0 and not dry
	# Every crossing goes dark (the water has just covered the screen); beads only on a real dive.
	if underwater and not _was_under:
		_age = 0.0
		if _air_time >= min_air_time:
			_bead_age = 0.0
			_rect.material.set_shader_parameter(&'seed', randf() * 100.0)
	_air_time = 0.0 if underwater else _air_time + delta
	_was_under = underwater
	_age += delta
	_bead_age += delta
	# Above water and close to it: the lens is about to go under, the water rises up the screen.
	var wipe := 0.0
	if not underwater and not dry and exposure_dip > 0.0 and wipe_height > 0.0:
		wipe = clampf(1.0 + submersion / wipe_height, 0.0, 1.0)
	var dark := exposure_dip > 0.0 and _age < exposure_time
	var beads := enabled and _bead_age < duration
	visible = wipe > 0.0 or (underwater and (dark or beads))
	if not visible: return
	var mat := _rect.material as ShaderMaterial
	mat.set_shader_parameter(&'age', _age if underwater else 100.0)
	mat.set_shader_parameter(&'bead_age', _bead_age if underwater else 100.0)
	mat.set_shader_parameter(&'wipe', wipe)
	mat.set_shader_parameter(&'wipe_wave', wipe_wave)
	mat.set_shader_parameter(&'wipe_softness', wipe_softness)
	mat.set_shader_parameter(&'wipe_sheen', wipe_sheen)
	mat.set_shader_parameter(&'duration', duration)
	mat.set_shader_parameter(&'count', count if enabled else 0)
	mat.set_shader_parameter(&'bead_size', bead_size)
	mat.set_shader_parameter(&'refraction', refraction)
	mat.set_shader_parameter(&'brightness', brightness)
	mat.set_shader_parameter(&'tint', tint)
	mat.set_shader_parameter(&'blur', blur)
	mat.set_shader_parameter(&'rise', rise)
	mat.set_shader_parameter(&'wobble', wobble)
	mat.set_shader_parameter(&'exposure_dip', exposure_dip)
	mat.set_shader_parameter(&'exposure_hold', exposure_hold)
	mat.set_shader_parameter(&'exposure_time', exposure_time)
