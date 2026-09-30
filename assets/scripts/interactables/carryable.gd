extends RigidBody3D
## A physical item the player can pick up, carry in front of the camera and
## drop anywhere (Amnesia-style). Reading happens by simply holding it close
## (Firewatch-style) — no inspection mode. Pairs with the player's
## CarryController; the one interaction rule lives there.
##
## While carried the body is frozen (kinematic) and its collision disabled,
## following the CarrySocket. Dropping restores physics and inherits the
## player's motion, so a letter left on the deck sails with the ship.
##
## The package uses two extra behaviours (see exports): it is grabbed on touch
## (no aiming/E needed while diving) and it is neutrally buoyant — dropped in
## the water it hangs where it is instead of sinking away forever; dropped in
## air it falls until it meets the water and then holds there.

enum MissionRole { NONE, LETTER, PACKAGE }

@export var item_name: String = ""
@export var mission_role: MissionRole = MissionRole.NONE

@export_group("Package behaviour")
## Grab the moment the player is within pickup_touch_radius — no interact press.
@export var auto_pickup_on_touch: bool = false
@export var pickup_touch_radius: float = 1.8
## Dropped in water it hangs in place instead of sinking; dropped in air it
## falls until it reaches the surface, then holds. Needs `water`.
@export var neutral_buoyancy: bool = false
@export var water: Node

const LAYER_INTERACTABLE := 0b100 # layer 3
const LAYER_ITEMS := 0b1000 # layer 4

var carried := false
var _picked_once := false
var _floating := false # neutral-buoyancy item currently held by the water
var _highlight_material: StandardMaterial3D

func _ready() -> void:
	add_to_group(&'carryable') # the player's feet look through us for the deck beneath
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	# Give the mesh its own material copy so highlighting never leaks to others.
	var mesh_instance: MeshInstance3D = get_node_or_null(^'Mesh')
	if mesh_instance and mesh_instance.get_surface_override_material(0):
		_highlight_material = mesh_instance.get_surface_override_material(0).duplicate()
		mesh_instance.set_surface_override_material(0, _highlight_material)

func _physics_process(_delta: float) -> void:
	if carried:
		return
	if auto_pickup_on_touch and GameState.phase == GameState.Phase.HAS_LETTER:
		var player: Node3D = get_tree().get_first_node_in_group(&'player')
		if player and player.global_position.distance_to(global_position) < pickup_touch_radius:
			get_tree().get_first_node_in_group(&'carry_controller').pick_up(self)
			return
	if neutral_buoyancy and not _floating and water:
		# The moment it reaches (or starts below) the surface, hold it there.
		if global_position.y <= water.get_wave_height(global_position):
			_floating = true
			freeze = true
			linear_velocity = Vector3.ZERO
			angular_velocity = Vector3.ZERO

## Crosshair hover feedback (called by the player's hover system).
func set_highlighted(on: bool) -> void:
	if _highlight_material:
		_highlight_material.emission_enabled = on
		var settings := GameSettings.current() # "Item glow" in game_settings.tres
		_highlight_material.emission = settings.item_glow_color
		_highlight_material.emission_energy_multiplier = settings.item_glow_energy

func interact(_player: Node) -> void:
	get_tree().get_first_node_in_group(&'carry_controller').pick_up(self)

func on_picked_up() -> void:
	carried = true
	_floating = false
	freeze = true
	collision_layer = 0
	collision_mask = 0
	set_highlighted(false)
	if not _picked_once:
		_picked_once = true
		if mission_role == MissionRole.LETTER and GameState.phase == GameState.Phase.WAKE:
			GameState.set_phase(GameState.Phase.HAS_LETTER)
			EventBus.letter_read.emit()
		elif mission_role == MissionRole.PACKAGE and GameState.phase == GameState.Phase.HAS_LETTER:
			GameState.set_phase(GameState.Phase.PICKED_UP)
			EventBus.package_picked_up.emit()

func on_dropped(inherited_velocity: Vector3) -> void:
	carried = false
	_floating = false
	freeze = false
	# Loose items live on their own layer. Not "world": a ship's hull is one big box around
	# the whole vessel, and anything on the world layer lying on her deck is deep inside it --
	# the physics would shove the entire ship to get it out.
	collision_layer = LAYER_ITEMS | LAYER_INTERACTABLE
	collision_mask = 0b11 # land on the world (shore) and on ship decks (layer 2)
	linear_velocity = inherited_velocity
	angular_velocity = Vector3.ZERO
	sleeping = false

## Puts the item back into the world for a new morning.
func restage(world_parent: Node, world_position: Vector3) -> void:
	var controller: Node = get_tree().get_first_node_in_group(&'carry_controller')
	if controller and controller.carried == self:
		controller.carried = null
	on_dropped(Vector3.ZERO)
	_picked_once = false
	if get_parent() != world_parent:
		reparent(world_parent)
	global_transform = Transform3D(Basis.IDENTITY, world_position)
	visible = true

func set_label_text(text: String) -> void:
	if has_node(^'ItemLabel'):
		get_node(^'ItemLabel').text = text
