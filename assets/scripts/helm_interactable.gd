extends Area3D
## Placed on a ship's deck. Pressing the interact key while looking at this
## area hands helm control (throttle/rudder) to `ship`, and moves the player
## camera to `helm_marker` for the duration.

@export var ship: Node
@export var helm_marker: Node3D
@export var highlight_mesh: Node3D # visual (eg. the wheel) to outline when targeted; every mesh under it glows

func interact(player: Node) -> void:
	if player.has_method(&'enter_pilot'):
		player.enter_pilot(ship, helm_marker)

## Look and feel: the "Interact highlight" group in res://assets/settings/game_settings.tres.
func set_highlighted(on: bool) -> void:
	GameSettings.set_highlight(highlight_mesh, on)
