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
##  - sinking back down: the water is dragged down into a funnel around the body (the faster it
##    sinks, the deeper), the hole collapses as its top goes under, sending out a swell, then the
##    converging water rebounds in an upwelling hump and leaves a patch of churned foam.
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

@export_group('Submerge')
## How deep the water is dragged down around a sinking body (m).
@export_range(0.0, 50.0, 0.1, 'or_greater') var max_drawdown := 6.0
## Funnel width as a multiple of the radius. Low = a steep hole hugging the body.
@export_range(1.0, 4.0, 0.05) var drawdown_width := 1.4
## Sinking speed (m/s) that produces the full drawdown. Slower sinking drags the water less.
@export_range(0.1, 30.0, 0.1) var drawdown_speed := 4.0
## Height of the upwelling hump when the hole closes over the body (m).
@export_range(0.0, 50.0, 0.1, 'or_greater') var rebound_height := 4.0
## Width of the upwelling as a multiple of the radius.
@export_range(0.2, 4.0, 0.05) var rebound_width := 0.9
## Seconds between the body's top going under and the upwelling peaking.
@export_range(0.0, 5.0, 0.05) var rebound_delay := 0.8
## Seconds the upwelling takes to settle again.
@export_range(0.1, 20.0, 0.1) var rebound_time := 3.0
## Churned foam left over the spot where the body went under.
@export_range(0.0, 2.0, 0.01) var boil_foam := 1.0
## Seconds for the churned foam patch to fade.
@export_range(0.1, 60.0, 0.1) var boil_time := 8.0

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
var _last_y := NAN
var _velocity_y := 0.0 # Smoothed vertical speed (m/s), tells rising from sinking.
var _time_sunk := -1.0 # Seconds since the top went under while sinking (< 0 = not active).

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

## True while the body is moving down.
func is_sinking() -> bool:
	return _velocity_y < -0.25

## Advances the dome and swells. Called by water.gd every frame.
func update_state(delta : float, water_level : float) -> void:
	if delta <= 0.0: return
	var y := global_position.y
	if not is_nan(_last_y):
		# Clamped so teleports don't read as a violent plunge.
		var instant := clampf((y - _last_y) / delta, -50.0, 50.0)
		_velocity_y = lerpf(_velocity_y, instant, 1.0 - exp(-8.0 * delta))
	_last_y = y
	var sinking := is_sinking()
	var sink_factor := clampf(-_velocity_y / drawdown_speed, 0.0, 1.0)

	var above := y + radius - water_level # > 0 once the top has broken through.
	var breached := above > 0.0
	if breached != _breached:
		if breached:
			_time_breached = 0.0
			_time_sunk = -1.0
			emit_ring(1.0)
		else:
			if rings_on_submerge: emit_ring(0.6)
			if sinking: _time_sunk = 0.0 # The hole closes over it: rebound and boil follow.
		_breached = breached
	if _time_sunk >= 0.0:
		_time_sunk += delta
		if _time_sunk > rebound_delay + rebound_time + boil_time:
			_time_sunk = -1.0

	# Fraction of the body still under water (nothing to displace once it's all out).
	var submerged := clampf((water_level - (y - radius)) / (2.0 * radius), 0.0, 1.0)
	var target := 0.0
	if sinking:
		# Water follows the body down: a funnel while it breaks the surface, a gentle sag above
		# it once under.
		var reach := 1.0 if breached else 0.5 * smoothstep(-influence_depth, 0.0, above)
		target = -max_drawdown * sink_factor * reach * minf(submerged * 2.0, 1.0)
	elif not breached:
		target = max_lift * smoothstep(-influence_depth, 0.0, above)
	else:
		_time_breached += delta
		target = max_lift * lerpf(settled_lift, 1.0, exp(-_time_breached / drain_time))
		target *= minf(submerged * 2.0, 1.0)
	_lift = lerpf(_lift, target, 1.0 - exp(-response * delta))

	# Glassy while swelling, white once it breaks or while it's being dragged under.
	var breaking := smoothstep(-0.25 * radius, 0.0, above) if not breached and not sinking else 0.0
	var draining := exp(-_time_breached / drain_time) if breached and not sinking else 0.0
	var dragging := sink_factor if breached and sinking else 0.0
	_foam_level = maxf(maxf(breaking, draining), dragging)

	for i in range(_rings.size() - 1, -1, -1):
		_rings[i].x += delta
		if _rings[i].x > ring_lifetime:
			_rings.remove_at(i)

## Water shapes for the shader, as [a, b] Vector4 pairs. Must match water_shapes_eval() in
## water.gdshader: dome a = (x, z, width, height), b = (trough, calm, 0, foam) (a negative
## height is a funnel, its trough term then becomes a raised rim); ring a = (x, z, radius,
## amplitude), b = (width, 0, 1, foam); boil a = (x, z, width, 0), b = (0, 0, 2, foam).
func pack_shapes() -> Array:
	var shapes := []
	var x := global_position.x
	var z := global_position.z
	var height := _lift * strength
	if absf(height) > 0.001:
		var scale := max_lift if _lift > 0.0 else max_drawdown
		var width := radius * (spread if _lift > 0.0 else drawdown_width)
		var calm_now := calm * clampf(absf(_lift) / maxf(scale, 0.001), 0.0, 1.0)
		shapes.append([Vector4(x, z, width, height),
				Vector4(trough, calm_now, 0.0, foam * _foam_level)])
	if _time_sunk >= 0.0:
		# Upwelling: rises after rebound_delay, peaks, then decays over rebound_time.
		var k := maxf(_time_sunk / maxf(rebound_delay, 0.01), 0.0)
		var rise := k * exp(1.0 - k) if _time_sunk < rebound_delay else exp(-(_time_sunk - rebound_delay) / (0.35 * rebound_time))
		var up := rebound_height * strength * rise
		if up > 0.001:
			shapes.append([Vector4(x, z, radius * rebound_width, up), Vector4(0.0, 0.6 * rise, 0.0, foam * rise)])
		var boil := boil_foam * exp(-_time_sunk / boil_time)
		if boil > 0.01:
			shapes.append([Vector4(x, z, radius * spread * 0.8, 0.0), Vector4(0.0, 0.0, 2.0, boil)])
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
