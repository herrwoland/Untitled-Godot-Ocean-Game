@tool
class_name WaterDeformer extends Node3D
## Makes the ocean react to something huge rising out of (or sinking into) the sea.
##
## Put it on a creature/rock at the centre of its body. It reads its own depth every frame:
##  - deep down: nothing;
##  - rising: a smooth dome of water swells above it (small waves smooth out on it, a slight
##    trough pulls in around it);
##  - breaching: the body punches through, the dome's flanks sheet off it in white water and a
##    ring swell rolls outwards; the hump then drains down to a small bulge around the body;
##  - sinking back under: another ring swell.
## `strength` scales everything and can be animated for cinematic timing; emit_ring() adds
## extra swells (tail slams, footsteps...).
##
## water.gd gathers all deformers each frame and feeds their shapes to the water shader,
## buoyancy and the underwater/caustics effects, so everything agrees on the water height.

const MAX_RINGS := 3

## Radius of the body at the waterline (m). Its top is at global y + radius.
@export_range(0.5, 200.0, 0.1, 'or_greater') var radius := 10.0
## Master multiplier for the whole effect. Animate it to fake or exaggerate an emergence.
@export_range(0.0, 3.0, 0.01) var strength := 1.0

@export_group('Dome')
## Height of the water dome at the moment the body breaks the surface (m).
@export_range(0.0, 50.0, 0.1, 'or_greater') var max_lift := 6.0
## Dome width as a multiple of the radius.
@export_range(1.0, 6.0, 0.05) var spread := 2.0
## How deep the body's top can be and still start lifting the water (m).
@export_range(1.0, 200.0, 0.5, 'or_greater') var influence_depth := 30.0
## Water drawn in around the dome (0 = none).
@export_range(0.0, 1.0, 0.01) var trough := 0.25
## How much the dome smooths away the waves riding on it (the water is being lifted and stretched).
@export_range(0.0, 1.0, 0.01) var calm := 0.85
## White water on the dome's flanks. The dome stays glassy while it swells; foam appears as the
## water is about to break, peaks at the breach and fades as it drains.
@export_range(0.0, 2.0, 0.01) var foam := 1.0
## Fraction of the dome that stays as a bulge while the body remains surfaced.
@export_range(0.0, 1.0, 0.01) var settled_lift := 0.25
## Seconds for the water to drain off the body after breaching.
@export_range(0.1, 30.0, 0.1) var drain_time := 5.0
## How quickly the dome follows the body (per second). Lower = heavier, laggier water.
@export_range(0.1, 10.0, 0.05) var response := 2.0

@export_group('Ring Swells')
## Height of the swell sent out when the body breaches (m).
@export_range(0.0, 20.0, 0.05, 'or_greater') var ring_amplitude := 2.5
## How fast swells travel outwards (m/s).
@export_range(0.5, 50.0, 0.1) var ring_speed := 10.0
## Width of a swell (m).
@export_range(0.5, 50.0, 0.1) var ring_width := 6.0
## Seconds before a swell has died out.
@export_range(0.5, 60.0, 0.1) var ring_lifetime := 8.0
## Foam on the swell crests.
@export_range(0.0, 2.0, 0.01) var ring_foam := 0.8
## Also send out a (smaller) swell when the body sinks back under.
@export var rings_on_submerge := true

var _lift := 0.0
var _foam_level := 0.0 # 0..1, how broken/white the dome's water currently is.
var _breached := false
var _time_breached := 0.0
var _rings : Array[Vector2] = [] # (age in seconds, amplitude scale)

func _ready() -> void:
	add_to_group(&'water_deformer')

## Sends out an extra ring swell from the body. `scale` multiplies ring_amplitude.
func emit_ring(scale := 1.0) -> void:
	_rings.push_back(Vector2(0.0, scale))
	if _rings.size() > MAX_RINGS:
		_rings.pop_front()

## True while the body's top is above the water level.
func is_breached() -> bool:
	return _breached

## Advances the dome and swells. Called by water.gd every frame.
func update_state(delta : float, water_level : float) -> void:
	var above := global_position.y + radius - water_level # > 0 once the top has broken through.
	var breached := above > 0.0
	if breached != _breached:
		if breached:
			_time_breached = 0.0
			emit_ring(1.0)
		elif rings_on_submerge:
			emit_ring(0.6)
		_breached = breached

	var target := 0.0
	if not breached:
		target = max_lift * smoothstep(-influence_depth, 0.0, above)
	else:
		_time_breached += delta
		target = max_lift * lerpf(settled_lift, 1.0, exp(-_time_breached / drain_time))
		# Nothing left to displace once the whole body is out of the water.
		var submerged := clampf((water_level - (global_position.y - radius)) / (2.0 * radius), 0.0, 1.0)
		target *= minf(submerged * 2.0, 1.0)
	_lift = lerpf(_lift, target, 1.0 - exp(-response * delta))

	# Glassy while swelling, white once it breaks.
	var breaking := smoothstep(-0.25 * radius, 0.0, above)
	var draining := exp(-_time_breached / drain_time) if breached else 0.0
	_foam_level = maxf(breaking if not breached else 0.0, draining)

	for i in range(_rings.size() - 1, -1, -1):
		_rings[i].x += delta
		if _rings[i].x > ring_lifetime:
			_rings.remove_at(i)

## Water shapes for the shader, as [a, b] Vector4 pairs. Must match water_shapes_eval() in
## water.gdshader: dome a = (x, z, width, height), b = (trough, calm, 0, foam);
## ring a = (x, z, radius, amplitude), b = (width, 0, 1, foam).
func pack_shapes() -> Array:
	var shapes := []
	var height := _lift * strength
	if height > 0.001:
		var calm_now := calm * clampf(_lift / maxf(max_lift, 0.001), 0.0, 1.0)
		shapes.append([Vector4(global_position.x, global_position.z, radius * spread, height),
				Vector4(trough, calm_now, 0.0, foam * _foam_level)])
	for ring in _rings:
		var age := ring.x
		var ring_radius := radius + ring_speed * age
		# Energy spreads over a growing circle, and the swell dies out over its lifetime.
		var amplitude := ring_amplitude * ring.y * strength * sqrt(radius / ring_radius) \
				* (1.0 - smoothstep(0.5 * ring_lifetime, ring_lifetime, age))
		if amplitude > 0.001:
			shapes.append([Vector4(global_position.x, global_position.z, ring_radius, amplitude),
					Vector4(ring_width * (1.0 + 0.05 * age), 0.0, 1.0, ring_foam)])
	return shapes
