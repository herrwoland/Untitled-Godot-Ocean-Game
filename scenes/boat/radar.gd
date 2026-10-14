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

## The round plate. Its UVs must fill 0..1 with the circle's centre at (0.5, 0.5). Seen from
## above, U runs along the mesh's +X and V along its +Z (as a PlaneMesh does).
@export var screen: MeshInstance3D
## The strip that fills while the radar charges. U runs 0 -> 1 along it. Optional.
@export var charge_bar: MeshInstance3D
## Turns the picture on the plate if the model's UVs face another way (degrees, about the up axis).
@export_range(-180.0, 180.0, 90.0) var screen_turn_deg := 0.0
## The ship it reads power from and centres on. Left empty, the ship this radar is aboard.
@export var ship: Node3D

@onready var _interactable: Area3D = get_node_or_null(^'interactable')
@onready var _ping_sound: AudioStreamPlayer3D = get_node_or_null(^'ping')
@onready var _ready_sound: AudioStreamPlayer3D = get_node_or_null(^'ready')

var _screen_mat := ShaderMaterial.new()
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
	if _interactable and _interactable.has_signal(&'pulled'):
		_interactable.pulled.connect(func(_player: Node) -> void: ping())
	var terrains := get_tree().root.find_children("*", "Terrain3D", true, false)
	_terrain = terrains[0] if not terrains.is_empty() else null
	_ray.collision_mask = 1
	_ray.hit_back_faces = false
	_screen_mat.shader = SCREEN_SHADER
	_charge_mat.shader = CHARGE_SHADER
	if screen:
		screen.material_override = _screen_mat
	if charge_bar:
		charge_bar.material_override = _charge_mat
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
	var u := turn * Vector3(basis.x.x, 0.0, basis.x.z)
	var v := turn * Vector3(basis.z.x, 0.0, basis.z.z)
	if u.length_squared() > 1e-6 and v.length_squared() > 1e-6:
		_axis_u = u.normalized()
		_axis_v = v.normalized()

## The ship's bow (-X) as a direction in the screen's UV.
func _bow_on_screen() -> Vector2:
	var bow := -(ship.global_basis.x if ship else global_basis.x)
	var on_screen := Vector2(bow.dot(_axis_u), bow.dot(_axis_v))
	return on_screen.normalized() if on_screen.length_squared() > 1e-6 else Vector2(0.0, -1.0)

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
