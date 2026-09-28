extends Node
## Stages each day: resets player/ship, positions the mission points from the
## current DayConfig and reacts to mission events. Milestone 1 uses in-code
## placeholder day data; real content moves to DayConfig .tres files later.

const DayConfig := preload("res://assets/scripts/core/day_config.gd")
const CoordinateSystem := preload("res://assets/scripts/core/coordinate_system.gd")

@export var player: Node3D
@export var boat: RigidBody3D
@export var player_spawn: Node3D
@export var letter_point: Node3D
@export var pickup_point: Node3D
@export var delivery_point: Node3D
@export var package: Node3D
@export var ending_fish: Node3D
@export var note_view: CanvasLayer
@export var sleep_fade: ColorRect

const LETTER_HOME := Vector3(-129.4, 3.3, 10)
const DELIVERY_RADIUS := 4.0 # how close the package must get to complete the hand-off

var days: Array[DayConfig] = []
var _boat_start: Transform3D

func _ready() -> void:
	add_to_group(&'mission_controller')
	_build_placeholder_days()
	_boat_start = boat.global_transform
	EventBus.package_picked_up.connect(_on_package_picked_up)
	EventBus.package_delivered.connect(_on_package_delivered)
	EventBus.player_died.connect(_on_player_died)
	EventBus.day_started.connect(_on_day_started)
	GameState.start_day.call_deferred()

func _config() -> DayConfig:
	return days[clampi(GameState.current_day, 1, days.size()) - 1]

## Public accessor for other systems (eg. the SanityDirector).
func current_config() -> DayConfig:
	return _config()

func _on_day_started(_day: int) -> void:
	var cfg := _config()

	# Reset actors to their morning positions.
	player.global_position = player_spawn.global_position
	player.velocity = Vector3.ZERO
	player.state = 0 # State.WALK
	boat.global_transform = _boat_start
	boat.linear_velocity = Vector3.ZERO
	boat.angular_velocity = Vector3.ZERO

	# Nothing is carried on a new morning.
	get_tree().get_first_node_in_group(&'carry_controller').reset_day()

	# Stage the mission props. The letter carries the pickup coordinates; the
	# package rests below the surface marker and carries the delivery ones.
	letter_point.restage(get_parent(), LETTER_HOME)
	letter_point.set_label_text("%s\n\nPickup:\n%s" % [cfg.letter_text, CoordinateSystem.format_position(cfg.pickup_position)])
	package.restage(get_parent(), cfg.pickup_position + Vector3.DOWN * cfg.package_depth)
	package.set_label_text("DELIVER TO:\n%s" % CoordinateSystem.format_position(cfg.delivery_position))
	pickup_point.global_position = cfg.pickup_position
	pickup_point.set_active(true)
	delivery_point.global_position = cfg.delivery_position
	delivery_point.set_active(true)
	ending_fish.set_active(false)

func _on_package_picked_up() -> void:
	pickup_point.set_active(false)

## The package is delivered simply by bringing it to the delivery point. It is
## left there physically (never destroyed), so the world stays consistent.
func _physics_process(_delta: float) -> void:
	if GameState.phase != GameState.Phase.PICKED_UP:
		return
	if package.global_position.distance_to(delivery_point.global_position) < DELIVERY_RADIUS:
		GameState.set_phase(GameState.Phase.DELIVERED)
		EventBus.package_delivered.emit()

func _on_package_delivered() -> void:
	delivery_point.set_active(false)
	# Drop the crate at the hand-off point and leave it resting there.
	var carry: Node = get_tree().get_first_node_in_group(&'carry_controller')
	if carry.carried == package:
		carry.drop()
	if GameState.current_day >= GameState.FINAL_DAY:
		ending_fish.appear()
		note_view.show_note("It is done.\n\nSomething is waiting on the shore,\nin front of your house.")
	else:
		note_view.show_note("It is out of your hands now.\n\nGo home.")

var _dying := false

## Death is never a game over: fast fade to black, then the SAME morning
## restages and you wake panting in your bed.
func _on_player_died() -> void:
	if _dying:
		return
	_dying = true
	var tween := create_tween()
	tween.tween_property(sleep_fade, "modulate:a", 1.0, 0.5)
	tween.tween_callback(func() -> void:
		GameState.start_day()
		note_view.show_note("You wake, panting.\n\nThe same grey morning. The same letter."))
	tween.tween_interval(0.4)
	tween.tween_property(sleep_fade, "modulate:a", 0.0, 1.0)
	tween.tween_callback(func() -> void: _dying = false)

## Called by the bed. Fades out, advances the day, saves, then fades back into
## the next morning. On the final day sleep is refused — the fish is the exit.
func do_sleep() -> void:
	if GameState.current_day >= GameState.FINAL_DAY:
		note_view.show_note("You cannot sleep.\n\nIt is still waiting on the shore.")
		return
	var tween := create_tween()
	tween.tween_property(sleep_fade, "modulate:a", 1.0, 1.2)
	tween.tween_callback(_advance_after_fade)
	tween.tween_interval(0.6)
	tween.tween_property(sleep_fade, "modulate:a", 0.0, 1.2)

func _advance_after_fade() -> void:
	GameState.sleep_advance()
	GameState.start_day()

func _build_placeholder_days() -> void:
	var texts: Array[String] = [
		"A letter, damp at the corners.\n\n\"The first one is close. Bring it before dark.\"",
		"The handwriting is worse today.\n\n\"They are waiting. Do not open the crate.\"",
		"No greeting this time.\n\n\"You were seen. Deliver it anyway.\"",
		"The paper smells of low tide.\n\n\"The island. The well. Bring what sleeps at the bottom.\"",
		"The letter is addressed to you.\n\n\"Come home.\"",
	]
	var pickups: Array[Vector3] = [
		Vector3(150, 0, 60),
		Vector3(220, 0, -120),
		Vector3(320, 0, 180),
		Vector3(260, 0, -260), # day 4: the well at the Isle of the Dead
		Vector3(180, 0, 20),
	]
	var package_depths: Array[float] = [6.0, 6.0, 6.0, 18.0, 6.0] # day 4: bottom of the well shaft
	var deliveries: Array[Vector3] = [
		Vector3(40, 0, -160),
		Vector3(-40, 0, 240),
		Vector3(400, 0, -40),
		Vector3(60, 0, 320),
		Vector3(-112, 1, 12), # day 5: home
	]
	# Full strangeness state per morning (prop_id -> variant tier), plus swaps
	# that fire when the player returns home. Placeholder content — the real
	# transformations arrive with the user's models.
	var wake_swaps: Array[Dictionary] = [
		{&'ship_funnel': 0, &'shack_roof': 0},
		{&'ship_funnel': 1, &'shack_roof': 0},
		{&'ship_funnel': 1, &'shack_roof': 0},
		{&'ship_funnel': 1, &'shack_roof': 1},
		{&'ship_funnel': 1, &'shack_roof': 1},
	]
	var return_swaps: Array[Dictionary] = [
		{},
		{},
		{&'shack_roof': 1}, # day 3: the roof is wrong when you come back
		{},
		{},
	]
	for i in 5:
		var cfg := DayConfig.new()
		cfg.day = i + 1
		cfg.letter_text = texts[i]
		cfg.pickup_position = pickups[i]
		cfg.delivery_position = deliveries[i]
		cfg.package_depth = package_depths[i]
		cfg.wake_swaps = wake_swaps[i]
		cfg.return_home_swaps = return_swaps[i]
		days.append(cfg)
