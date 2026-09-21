extends Area3D
## Defines a region where ocean waves are damped (CALM) or the water surface is
## absent entirely (HOLE — eg. inside a tube/well going down through the sea).
##
## The footprint comes from a child CollisionShape3D, which doubles as the editor
## gizmo: BoxShape3D = box footprint, SphereShape3D/CylinderShape3D = circular
## footprint, CapsuleShape3D = its top-down outline (a "stadium", eg. a hull).
## The footprint follows the shape node's own position and yaw (it may be offset
## from this node), is 2D in the XZ plane and extends infinitely vertically.
## The Area itself takes no part in physics (no layers, no monitoring).
##
## water.gd gathers all blockers each frame and feeds them to the water shader
## and to get_wave_height(), so visuals and gameplay always agree.

enum Mode { CALM, HOLE }
enum Kind { CIRCLE, BOX, CAPSULE }

@export var mode: Mode = Mode.CALM
@export var fade_width: float = 8.0 # meters over which waves fade back to full height

var _kind := Kind.CIRCLE
var _radius := 5.0
var _half_extents := Vector2(5, 5)
var _capsule_half_height := 0.0 # Half the capsule's straight section, along its axis.
var _shape_node: Node3D

func _ready() -> void:
	add_to_group(&'wave_blocker')
	# Purely a marker volume — never participate in physics.
	monitoring = false
	monitorable = false
	collision_layer = 0
	collision_mask = 0
	refresh_from_shape()

## Reads the footprint from the first CollisionShape3D child. Call again if
## the shape is changed at runtime.
func refresh_from_shape() -> void:
	for child in get_children():
		if child is CollisionShape3D and child.shape:
			_shape_node = child
			var s: Shape3D = child.shape
			if s is BoxShape3D:
				_kind = Kind.BOX
				_half_extents = Vector2(s.size.x, s.size.z) * 0.5
			elif s is SphereShape3D:
				_kind = Kind.CIRCLE
				_radius = s.radius
			elif s is CylinderShape3D:
				_kind = Kind.CIRCLE
				_radius = s.radius
			elif s is CapsuleShape3D:
				_kind = Kind.CAPSULE
				_radius = s.radius
				_capsule_half_height = maxf(s.height * 0.5 - s.radius, 0.0)
			else:
				push_warning("WaveBlocker '%s': unsupported shape %s (use Box/Sphere/Cylinder/Capsule)" % [name, s.get_class()])
			return
	push_warning("WaveBlocker '%s' has no CollisionShape3D child to define its footprint." % name)

## World-space centre of the footprint.
func _center() -> Vector3:
	return _shape_node.global_position if is_instance_valid(_shape_node) else global_position

## (cos, sin) of the footprint's frame in the XZ plane, as used by pack_a() and the shader.
## Box: the shape's yaw. Capsule: its axis, projected onto the water plane.
func _frame() -> Vector2:
	var node: Node3D = _shape_node if is_instance_valid(_shape_node) else self
	if _kind == Kind.CAPSULE:
		var axis := node.global_basis.y
		var flat := Vector2(axis.x, axis.z)
		return flat.normalized() if flat.length() > 1e-4 else Vector2(1, 0)
	var yaw := node.global_rotation.y
	return Vector2(cos(yaw), sin(yaw))

## Capsule straight section as seen from above (shrinks as the capsule tilts upright).
func _capsule_half_length() -> float:
	var node: Node3D = _shape_node if is_instance_valid(_shape_node) else self
	var axis := node.global_basis.y.normalized()
	return _capsule_half_height * Vector2(axis.x, axis.z).length()

## Signed distance from the footprint in the XZ plane (negative = inside).
## Must mirror wave_blocker_eval() in the water shader exactly.
func distance_xz(world_pos: Vector3) -> float:
	var c := _center()
	var rel := Vector2(world_pos.x - c.x, world_pos.z - c.z)
	var f := _frame()
	var local_p := Vector2(f.x * rel.x + f.y * rel.y, -f.y * rel.x + f.x * rel.y)
	match _kind:
		Kind.BOX:
			var q := Vector2(absf(local_p.x), absf(local_p.y)) - _half_extents
			return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0)
		Kind.CAPSULE:
			return Vector2(maxf(absf(local_p.x) - _capsule_half_length(), 0.0), local_p.y).length() - _radius
	return rel.length() - _radius

## 0 inside the footprint, rising to 1 across fade_width outside it.
func attenuation(world_pos: Vector3) -> float:
	return smoothstep(0.0, maxf(fade_width, 0.001), distance_xz(world_pos))

func contains(world_pos: Vector3) -> bool:
	return distance_xz(world_pos) <= 0.0

## Shader packing — a: (center.x, center.z, frame cos, frame sin)
func pack_a() -> Vector4:
	var c := _center()
	var f := _frame()
	return Vector4(c.x, c.z, f.x, f.y)

## Shader packing — b: (half x / radius, half z / capsule half length, fade width,
## flags: +1 box, +2 hole, +4 capsule)
func pack_b() -> Vector4:
	var flags := (2 if mode == Mode.HOLE else 0)
	match _kind:
		Kind.BOX:
			return Vector4(_half_extents.x, _half_extents.y, fade_width, float(flags + 1))
		Kind.CAPSULE:
			return Vector4(_radius, _capsule_half_length(), fade_width, float(flags + 4))
	return Vector4(_radius, 0.0, fade_width, float(flags))
