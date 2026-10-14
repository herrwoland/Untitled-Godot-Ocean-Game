extends Node3D
## The ship's radar: a round screen lying on the table beside the wheel. Click it and a ring
## crawls out from the ship; whatever it passes -- a creature, land -- lights up on the screen
## and glows on like old phosphor, fading slowly. It is a snapshot: what moves after the ring has
## passed keeps glowing where it was. Then the charge bar has to fill before the next ping.
## The screen is a map lying under the plate: a blip sits in the same direction from the screen's
## centre as the real thing lies from the ship. It runs on the ship's power (Boat.set_powered):
## cut it and the screen dies with the rest of the ship.
## Dials are in GameSettings (Radar group); the picture is drawn by radar_screen.gdshader.

const SCREEN_SHADER := preload("res://scenes/boat/radar_screen.gdshader")
const CHARGE_SHADER := preload("res://scenes/boat/radar_charge.gdshader")
const NEVER := -100000.0 # hit time of a texel nothing has touched

## The mesh holding the round screen. The screen is one flat surface of it, UV-mapped top-down
## as a square around the circle (any part of the texture, any way round: the picture follows
## the UVs, read from the mesh itself).
@export var screen: MeshInstance3D
## Which surface (material slot) of `screen` is the glass. -1 = the flattest one.
@export var screen_surface := -1
## The strip that fills while the radar charges. Optional. It fills along its longest side,
## from the end where its U is smallest.
@export var charge_bar: MeshInstance3D
## Which surface (material slot) of `charge_bar` lights up.
@export var charge_bar_surface := 0
## Glows when the radar is charged and ready. Left empty, a child named "radar_light".
@export var ready_light: MeshInstance3D
## Which surface of `ready_light` glows; its own material's emission is switched.
@export var ready_light_surface := 0
## Emission energy of the ready light while it is lit.
@export_range(0.0, 16.0, 0.1) var ready_light_energy := 1.0
## Clicked to ping. Left empty, the first clickable thing (PullInteractable) under the radar.
@export var interactable: Area3D
## Turns the picture on the plate if it comes out the wrong way round (degrees, about the up axis).
@export_range(-180.0, 180.0, 90.0) var screen_turn_deg := 0.0
## The ship it reads power from and centres on. Left empty, the ship this radar is aboard.
@export var ship: Node3D

@onready var _ping_sound: AudioStreamPlayer3D = get_node_or_null(^'ping')
@onready var _ready_sound: AudioStreamPlayer3D = get_node_or_null(^'ready')

var _screen_mat := ShaderMaterial.new()
var _ready_mat: StandardMaterial3D # the ready light's own material, switched on and off
var _screen_du := Vector3.RIGHT # the screen's U and V directions in its mesh's space
var _screen_dv := Vector3.BACK
var _charge_mat := ShaderMaterial.new()
var _image: Image
var _texture: ImageTexture
var _size := 0
var _dirty := false

## Every texel inside the circle as Vector2(distance from the centre 0..1, texel index), nearest
## first: the ring only has to walk this list forward.
var _order: Array[Vector2] = []
var _next := 0 # first entry of _order the ring has not reached yet

var _clock := 0.0 # seconds since start, the time base of the shader
var _front := -1.0 # how far out the ring is, 0..1 of the range; -1 = no ring
var _origin := Vector3.ZERO # where the ship was at the ping
var _axis_u := Vector3.RIGHT # world directions of the screen's U and V, flat
var _axis_v := Vector3.BACK
var _charge := 1.0 # 0..1, the bar; a ping needs it full
var _powered := true
var _terrain: Node # Terrain3D: its heights reach farther than its collision does
var _ray := PhysicsRayQueryParameters3D.new()

func _ready() -> void:
	add_to_group(&'off_grid') # the screen lights itself, by the power it is given
	if ship == null:
		ship = _find_ship()
	if ship:
		_powered = ship.get(&'powered') != false
		ship.power_changed.connect(_on_power_changed)
	if interactable == null:
		for area: Area3D in find_children("*", "Area3D", true, false):
			if area.has_signal(&'pulled'):
				interactable = area
				break
	if interactable:
		interactable.pulled.connect(func(_player: Node) -> void: ping())
	else:
		push_warning("Radar: nothing to click (no PullInteractable under it).")
	if ready_light == null:
		ready_light = find_child("radar_light", true, false) as MeshInstance3D
	if ready_light and ready_light.mesh and ready_light_surface < ready_light.mesh.get_surface_count():
		var mat := ready_light.get_active_material(ready_light_surface) as StandardMaterial3D
		if mat:
			_ready_mat = mat.duplicate()
			ready_light.set_surface_override_material(ready_light_surface, _ready_mat)
	var terrains := get_tree().root.find_children("*", "Terrain3D", true, false)
	_terrain = terrains[0] if not terrains.is_empty() else null
	_ray.collision_mask = 1
	_ray.hit_back_faces = false
	_screen_mat.shader = SCREEN_SHADER
	_charge_mat.shader = CHARGE_SHADER
	if screen and screen.mesh:
		if screen_surface < 0:
			screen_surface = _flattest_surface(screen.mesh)
		_fit_screen(screen.mesh, screen_surface)
		screen.set_surface_override_material(screen_surface, _screen_mat)
	if charge_bar and charge_bar.mesh:
		_fit_bar(charge_bar.mesh, charge_bar_surface)
		charge_bar.set_surface_override_material(charge_bar_surface, _charge_mat)
	_build(GameSettings.current().radar_resolution)
	_clear()

## Sends a ping if the radar has power and is charged. True if it went.
func ping() -> bool:
	if not _powered or _charge < 1.0:
		return false
	var s := GameSettings.current()
	_charge = 0.0
	_front = 0.0
	_next = 0
	_origin = ship.global_position if ship else global_position
	if _ping_sound and _ping_sound.stream:
		_ping_sound.play()
	EventBus.radar_pinged.emit(_origin, s.radar_range)
	return true

func _process(delta: float) -> void:
	var s := GameSettings.current()
	_clock += delta
	if _powered and _charge < 1.0:
		_charge = 1.0 if s.radar_cooldown <= 0.0 else minf(_charge + delta / s.radar_cooldown, 1.0)
		if _charge >= 1.0 and _ready_sound and _ready_sound.stream:
			_ready_sound.play()
	_update_axes()
	if _dirty:
		_texture.update(_image)
		_dirty = false
	_screen_mat.set_shader_parameter(&'hits', _texture)
	_screen_mat.set_shader_parameter(&'now', _clock)
	_screen_mat.set_shader_parameter(&'ring', _front)
	_screen_mat.set_shader_parameter(&'powered', 1.0 if _powered else 0.0)
	_screen_mat.set_shader_parameter(&'bow', _bow_on_screen())
	_screen_mat.set_shader_parameter(&'tint', s.radar_color)
	_screen_mat.set_shader_parameter(&'energy', s.radar_energy)
	_screen_mat.set_shader_parameter(&'afterglow', s.radar_afterglow)
	_screen_mat.set_shader_parameter(&'flare', s.radar_flare)
	_screen_mat.set_shader_parameter(&'ring_width', s.radar_ring_width)
	_screen_mat.set_shader_parameter(&'grain', s.radar_grain)
	_screen_mat.set_shader_parameter(&'range_rings', float(s.radar_range_rings))
	_screen_mat.set_shader_parameter(&'texels', float(_size))
	_charge_mat.set_shader_parameter(&'fill', _charge)
	_charge_mat.set_shader_parameter(&'powered', 1.0 if _powered else 0.0)
	_charge_mat.set_shader_parameter(&'tint', s.radar_color)
	_charge_mat.set_shader_parameter(&'energy', s.radar_energy)
	_charge_mat.set_shader_parameter(&'now', _clock)
	if _ready_mat:
		_ready_mat.emission_energy_multiplier = ready_light_energy if _powered and _charge >= 1.0 else 0.0

## The ring moves (and looks around) in physics time: it casts rays for rock.
func _physics_process(delta: float) -> void:
	if _front < 0.0:
		return
	var s := GameSettings.current()
	if s.radar_resolution != _size:
		_build(s.radar_resolution)
		_clear()
	_front += delta * s.radar_speed / s.radar_range
	var reach := minf(_front, 1.0)
	if _next < _order.size() and _order[_next].x <= reach:
		_sweep(reach, s)
	if _front >= 1.0 + s.radar_ring_width * 4.0:
		_front = -1.0 # its tail has run off the rim

## Paints every texel between the ring's last position and `reach` that holds something.
func _sweep(reach: float, s: GameSettings) -> void:
	var bodies := _creature_bodies(s)
	var space := get_world_3d().direct_space_state
	var texel := 2.0 * s.radar_range / _size # m one texel spans
	while _next < _order.size() and _order[_next].x <= reach:
		var index := int(_order[_next].y)
		_next += 1
		var x := index % _size
		var y := index / _size
		var offset := (Vector2(x + 0.5, y + 0.5) / _size - Vector2(0.5, 0.5)) * 2.0 * s.radar_range
		var world := _origin + _axis_u * offset.x + _axis_v * offset.y
		var strength := 0.0
		var flat := Vector2(world.x, world.z)
		for body: Array in bodies:
			if Geometry2D.get_closest_point_to_segment(flat, body[0], body[1]).distance_to(flat) <= body[2] + texel * 0.5:
				strength = 1.0
				break
		if strength == 0.0 and _is_land(world, space, s):
			strength = s.radar_land_strength
		if strength > 0.0:
			_image.set_pixel(x, y, Color(_clock, strength, 0.0))
			_dirty = true

## Every creature as a flat capsule [from, to, radius] in world XZ.
func _creature_bodies(s: GameSettings) -> Array:
	var bodies := []
	for kraken in get_tree().get_nodes_in_group(&'kraken'):
		var at: Vector3 = kraken.body_position()
		var p := Vector2(at.x, at.z)
		bodies.append([p, p, kraken.body_size() * s.radar_blip_scale])
	for fish in get_tree().get_nodes_in_group(&'giant_fish'):
		if not fish.is_visible_in_tree() or not fish.has_method(&'body_point'):
			continue
		var radius: float = fish.body_length * 0.06 * s.radar_blip_scale # a body ~1/16 as thick as long
		var last: Vector3 = fish.body_point(0.0)
		for i in range(1, 7): # a bent body as a few straight pieces
			var point: Vector3 = fish.body_point(i / 6.0)
			bodies.append([Vector2(last.x, last.z), Vector2(point.x, point.z), radius])
			last = point
	return bodies

## Ground (terrain heights) or rock (a ray down) at or above the land level.
func _is_land(world: Vector3, space: PhysicsDirectSpaceState3D, s: GameSettings) -> bool:
	if _terrain:
		var height: float = _terrain.data.get_height(world)
		if not is_nan(height) and height >= s.radar_land_level:
			return true
	_ray.from = Vector3(world.x, 150.0, world.z)
	_ray.to = Vector3(world.x, s.radar_land_level, world.z)
	var hit := space.intersect_ray(_ray)
	if hit.is_empty():
		return false
	var collider: Node = hit.collider
	return not (ship and (collider == ship or ship.is_ancestor_of(collider)))

## Where the screen's U and V point in the world, kept flat and turned by screen_turn_deg.
func _update_axes() -> void:
	var basis := screen.global_basis if screen else global_basis
	var turn := Basis(Vector3.UP, deg_to_rad(screen_turn_deg))
	var du := basis * _screen_du
	var dv := basis * _screen_dv
	var u := turn * Vector3(du.x, 0.0, du.z)
	var v := turn * Vector3(dv.x, 0.0, dv.z)
	if u.length_squared() > 1e-6 and v.length_squared() > 1e-6:
		_axis_u = u.normalized()
		_axis_v = v.normalized()

## The ship's bow (-X) as a direction in the screen's UV.
func _bow_on_screen() -> Vector2:
	var bow := -(ship.global_basis.x if ship else global_basis.x)
	var on_screen := Vector2(bow.dot(_axis_u), bow.dot(_axis_v))
	return on_screen.normalized() if on_screen.length_squared() > 1e-6 else Vector2(0.0, -1.0)

## The surface lying flattest (least height for its width): the glass of a screen.
static func _flattest_surface(mesh: Mesh) -> int:
	var best := 0
	var best_ratio := INF
	for i in mesh.get_surface_count():
		var box := _bounds(mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX])
		var ratio := box.size.y / maxf(maxf(box.size.x, box.size.z), 1e-6)
		if ratio < best_ratio:
			best_ratio = ratio
			best = i
	return best

static func _bounds(verts: PackedVector3Array) -> AABB:
	var box := AABB(verts[0], Vector3.ZERO)
	for v in verts:
		box = box.expand(v)
	return box

## Reads where the screen's circle sits in its UVs, and which way U and V run across the
## mesh (a least-squares fit of position against UV over the surface's vertices).
func _fit_screen(mesh: Mesh, surface: int) -> void:
	var arrays := mesh.surface_get_arrays(surface)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if uvs.is_empty():
		return
	var uv_min := uvs[0]
	var uv_max := uvs[0]
	var uv_mean := Vector2.ZERO
	var pos_mean := Vector3.ZERO
	for i in uvs.size():
		uv_min = uv_min.min(uvs[i])
		uv_max = uv_max.max(uvs[i])
		uv_mean += uvs[i]
		pos_mean += verts[i]
	uv_mean /= uvs.size()
	pos_mean /= uvs.size()
	var suu := 0.0
	var suv := 0.0
	var svv := 0.0
	var bu := Vector3.ZERO
	var bv := Vector3.ZERO
	for i in uvs.size():
		var d := uvs[i] - uv_mean
		var p := verts[i] - pos_mean
		suu += d.x * d.x
		suv += d.x * d.y
		svv += d.y * d.y
		bu += p * d.x
		bv += p * d.y
	var det := suu * svv - suv * suv
	if absf(det) > 1e-12:
		_screen_du = (bu * svv - bv * suv) / det
		_screen_dv = (bv * suu - bu * suv) / det
	_screen_mat.set_shader_parameter(&'uv_center', (uv_min + uv_max) * 0.5)
	_screen_mat.set_shader_parameter(&'uv_half', ((uv_max - uv_min) * 0.5).max(Vector2(1e-4, 1e-4)))

## The bar fills along its longest side, starting from the end where its U is smallest.
func _fit_bar(mesh: Mesh, surface: int) -> void:
	var arrays := mesh.surface_get_arrays(surface)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var box := _bounds(verts)
	var axis := Vector3.ZERO
	axis[box.get_longest_axis_index()] = 1.0
	var half := box.get_longest_axis_size() * 0.5
	var from := box.get_center() - axis * half
	var to := box.get_center() + axis * half
	if not uvs.is_empty():
		var lo := 0
		var hi := 0
		for i in uvs.size():
			if uvs[i].x < uvs[lo].x: lo = i
			if uvs[i].x > uvs[hi].x: hi = i
		if (verts[hi] - verts[lo]).dot(axis) < 0.0:
			var swap := from
			from = to
			to = swap
	_charge_mat.set_shader_parameter(&'bar_from', from)
	_charge_mat.set_shader_parameter(&'bar_to', to)

func _on_power_changed(on: bool) -> void:
	_powered = on
	_front = -1.0 # a cut kills the ring and every glow on the screen
	_charge = 0.0 # and it charges up from nothing when the power is back
	_clear()

func _build(size: int) -> void:
	_size = size
	_image = Image.create_empty(size, size, false, Image.FORMAT_RGF)
	_texture = ImageTexture.create_from_image(_image)
	_order.clear()
	var half := size * 0.5
	for y in size:
		for x in size:
			var r := Vector2(x + 0.5 - half, y + 0.5 - half).length() / half
			if r <= 1.0:
				_order.append(Vector2(r, y * size + x))
	_order.sort()

func _clear() -> void:
	_image.fill(Color(NEVER, 0.0, 0.0))
	_dirty = true

## The nearest ancestor with a power switch.
func _find_ship() -> Node3D:
	var node := get_parent()
	while node:
		if node.has_signal(&'power_changed'):
			return node as Node3D
		node = node.get_parent()
	return null
