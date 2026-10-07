extends Area3D
## Something the player pulls, presses or turns: a handle, a lever, a button. Interacting
## (look at it + E or click) emits `pulled`; whatever it belongs to listens and decides what
## happens. Put it on the interact layer (3) so the player's aim finds it.

signal pulled(player: Node)

## Visual to outline when looked at; every mesh under it glows. Defaults to this area's parent.
@export var highlight_mesh: Node3D
## Can be reached from the helm too (eg. a lever beside the wheel), not only on foot.
@export var usable_from_helm: bool = false

func _ready() -> void:
	if highlight_mesh == null:
		highlight_mesh = get_parent() as Node3D

func interact(player: Node) -> void:
	pulled.emit(player)

## Look and feel: the "Interact highlight" group in res://assets/settings/game_settings.tres.
func set_highlighted(on: bool) -> void:
	GameSettings.set_highlight(highlight_mesh, on)
