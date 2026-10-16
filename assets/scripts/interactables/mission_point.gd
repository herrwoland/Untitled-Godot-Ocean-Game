extends Area3D
## Debug pickup/delivery point (Milestone 1). Later the pickup becomes an
## underwater package and the delivery a staged hand-off.

enum Kind { PICKUP, DELIVERY }

@export var kind: Kind = Kind.PICKUP

func set_active(active: bool) -> void:
	visible = active
	set_deferred(&'monitorable', active)
	for child in get_children():
		if child is CollisionShape3D:
			child.set_deferred(&'disabled', not active)
