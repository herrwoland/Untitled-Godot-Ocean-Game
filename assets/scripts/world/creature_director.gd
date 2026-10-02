extends Node3D
## Spawns the giant deep-water creatures and decides who hunts. Idle bodies
## drift in huge, well-separated orbits far below the player's patch of sea —
## the bodies are ~150 m long, so the spacing is measured in hundreds of
## meters. When the player dives past hunt_depth, the nearest lurker is told
## to hunt; the stalking, the lunge and the carry all live in hunter_fish.gd,
## tuned by exports on that scene.

const HUNTER_SCENE := preload("res://assets/models/creatures/hunter_fish.tscn")

@export var creature_scene: PackedScene
@export var player: Node3D
@export var water: Node
@export var creature_count := 6
@export var stalker_count := 1 # hunters at once — one lone stalker reads scarier
## Scales every hunter's swim speeds (approach, run-up, charge, carry) and
## acceleration — not the slow stalking creep. Turn radii stay put, so turns
## get quicker, not tighter.
@export var speed_multiplier := 3.0
@export var hunt_depth := 3.0 # player depth (m below surface) that triggers hunting
@export var escape_depth := 0.8 # shallower than this (or out of the water) calls it off
## Idle orbit shape. Radii spread wide so the bodies never crowd each other.
@export var orbit_radius_range := Vector2(180.0, 420.0)
@export var orbit_depth_range := Vector2(-140.0, -80.0)
@export var orbit_speed := 0.06
## No hunting inside this zone (the Isle of the Dead — the eel rules there).
@export var hunt_exclusion_center := Vector3(260, 0, -260)
@export var hunt_exclusion_radius := 60.0

const SHORE_X_LIMIT := -85.0 # keep creatures out of the cove's shallows

var _creatures: Array[Node3D] = []
var _orbit_radius: Array[float] = []
var _orbit_depth: Array[float] = []
var _orbit_phase: Array[float] = []
var _grace := 0.0 # no hunting for a few seconds after a morning restage

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var scene := creature_scene if creature_scene else HUNTER_SCENE
	var time := Time.get_ticks_msec() / 1000.0
	for i in creature_count:
		var creature: Node3D = scene.instantiate()
		add_child(creature)
		_creatures.append(creature)
		_orbit_radius.append(rng.randf_range(orbit_radius_range.x, orbit_radius_range.y))
		_orbit_depth.append(rng.randf_range(orbit_depth_range.x, orbit_depth_range.y))
		# Evenly spaced around the circle (plus jitter) so they never clump.
		_orbit_phase.append(TAU * float(i) / float(creature_count) + rng.randf_range(-0.3, 0.3))
		creature.global_position = _orbit_target(i, time) # start in place, not at origin
	EventBus.day_started.connect(_on_day_started)

func _on_day_started(_day: int) -> void:
	_grace = 3.0
	for creature in _creatures:
		if creature.has_method(&'abort_hunt'):
			creature.abort_hunt()
	if player.has_method(&'set_captured'):
		player.set_captured(false)

func _physics_process(delta: float) -> void:
	_grace = maxf(_grace - delta, 0.0)
	var surface_y: float = water.get_wave_height(player.global_position)
	var player_depth: float = surface_y - player.global_position.y
	var in_exclusion := Vector2(player.global_position.x - hunt_exclusion_center.x,
		player.global_position.z - hunt_exclusion_center.z).length() < hunt_exclusion_radius
	var swimming: bool = (&'state' in player and player.state == 1) # Player State.SWIM
	# Hunters may follow the player into a kraken's waters (that is the lure: a
	# kraken takes a giant fish over the player). Only a player already held by
	# something is left alone.
	var held: bool = player.get(&'captured') == true
	var huntable: bool = swimming and player_depth > hunt_depth \
		and not in_exclusion and not held and _grace <= 0.0
	var escaped: bool = not swimming or player_depth < escape_depth or in_exclusion or held

	if huntable:
		_assign_stalkers()

	var time := Time.get_ticks_msec() / 1000.0
	for i in _creatures.size():
		var creature := _creatures[i]
		creature.speed_multiplier = speed_multiplier # live, so it can be tuned while playing
		if creature.is_busy():
			if escaped and not creature.is_carrying():
				creature.end_hunt()
			continue
		# Slow orbit around the player's patch of sea, far below the waves —
		# swum forward like everything else they do, never slid.
		creature.cruise_toward(_orbit_target(i, time), delta)

func _orbit_target(i: int, time: float) -> Vector3:
	var angle := time * orbit_speed + _orbit_phase[i]
	var target := Vector3(
		player.global_position.x + cos(angle) * _orbit_radius[i],
		_orbit_depth[i],
		player.global_position.z + sin(angle) * _orbit_radius[i]
	)
	target.x = maxf(target.x, SHORE_X_LIMIT)
	# Idle, they keep out of a kraken's waters; only a hunt leads them in.
	for kraken in get_tree().get_nodes_in_group(&'kraken'):
		target = kraken.keep_out(target)
	return target

## Wake the nearest idle lurkers until stalker_count of them are on the hunt.
func _assign_stalkers() -> void:
	var busy := 0
	for creature in _creatures:
		if creature.is_busy():
			busy += 1
	while busy < stalker_count:
		var nearest: Node3D = null
		var nearest_d := INF
		for creature in _creatures:
			if creature.is_busy():
				continue
			var d := creature.global_position.distance_to(player.global_position)
			if d < nearest_d:
				nearest_d = d
				nearest = creature
		if nearest == null:
			return
		nearest.begin_hunt(player)
		busy += 1
