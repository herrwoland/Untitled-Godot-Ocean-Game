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
## Their waters: an Area3D whose CollisionShape3D children (boxes, spheres,
## cylinders, capsules — as many as you like, any size) mark where the fish
## live. Idle, they patrol inside it; they hunt only a player inside it (or
## within hunt_reach of its edge) and give up once the player leaves that.
## Left empty, they orbit round the player anywhere, as before.
## The bodies are ~150 m long and turn in ~100 m circles: make the waters
## several hundred meters across or they will swim along the edge.
@export var fish_waters: Area3D
@export var hunt_reach := 50.0 # m past the edge of the waters a hunt may still follow the player
## Patrolling, they keep at least this far apart (between their bodies'
## middles) — a 150 m body needs a lot of room.
@export var patrol_spacing := 220.0
@export var patrol_margin := 100.0 # m patrol points keep inside the edge of the waters (about a turn radius: they swing wide)
@export var patrol_point_reached := 80.0 # m from a patrol point before it picks the next
@export var patrol_speed := 8.0 # m/s a patrolling body drifts at
## No hunting inside this zone (the Isle of the Dead — the eel rules there).
@export var hunt_exclusion_center := Vector3(260, 0, -260)
@export var hunt_exclusion_radius := 60.0

const SHORE_X_LIMIT := -85.0 # keep creatures out of the cove's shallows
const PATROL_FORESIGHT := 20.0 # s ahead a patrolling fish judges its spacing

var _creatures: Array[Node3D] = []
var _orbit_radius: Array[float] = []
var _orbit_depth: Array[float] = []
var _orbit_phase: Array[float] = []
var _grace := 0.0 # no hunting for a few seconds after a morning restage
var _shapes: Array[CollisionShape3D] = [] # fish_waters' shapes
var _patrol: Array[Vector3] = [] # each fish's patrol point in the waters
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var scene := creature_scene if creature_scene else HUNTER_SCENE
	var time := Time.get_ticks_msec() / 1000.0
	_rng.seed = 7331
	if fish_waters:
		for child in fish_waters.find_children("*", "CollisionShape3D", true, false):
			var sh: Shape3D = child.shape
			if sh is BoxShape3D or sh is SphereShape3D or sh is CylinderShape3D or sh is CapsuleShape3D:
				_shapes.append(child)
			else:
				push_warning("CreatureDirector: fish_waters shape %s is not a box, sphere, cylinder or capsule; ignored." % child.name)
		if _shapes.is_empty():
			push_warning("CreatureDirector: fish_waters has no usable CollisionShape3D; the fish roam as before.")
	for i in creature_count:
		var creature: Node3D = scene.instantiate()
		add_child(creature)
		_creatures.append(creature)
		_orbit_radius.append(rng.randf_range(orbit_radius_range.x, orbit_radius_range.y))
		_orbit_depth.append(rng.randf_range(orbit_depth_range.x, orbit_depth_range.y))
		# Evenly spaced around the circle (plus jitter) so they never clump.
		_orbit_phase.append(TAU * float(i) / float(creature_count) + rng.randf_range(-0.3, 0.3))
		if _shapes.is_empty():
			creature.global_position = _orbit_target(i, time) # start in place, not at origin
		else:
			_patrol.append(Vector3.ZERO)
			creature.global_position = _spaced_point(i) # start in its waters, apart from the others
			_patrol[i] = _spaced_point(i)
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
		and not in_exclusion and not held and _grace <= 0.0 \
		and _near_waters(player.global_position, 0.0, true)
	var escaped: bool = not swimming or player_depth < escape_depth or in_exclusion or held \
		or not _near_waters(player.global_position, hunt_reach, true)

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
		if _shapes.is_empty():
			# Slow orbit around the player's patch of sea, far below the waves —
			# swum forward like everything else they do, never slid.
			creature.cruise_toward(_orbit_target(i, time), delta)
		else:
			creature.cruise_toward(_patrol_target(i), delta)

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

## ---- fish waters ---------------------------------------------------------------

## Patrolling: on to its patrol point (a new one, well away from the others',
## once it gets there), steered off any fish closer than patrol_spacing.
func _patrol_target(i: int) -> Vector3:
	var me := _creatures[i]
	var pos := me.global_position
	if pos.distance_to(_patrol[i]) < patrol_point_reached:
		_patrol[i] = _spaced_point(i)
	# crowded: veer off sideways, away from the others (a body this size
	# cannot turn on the spot, so "away" is a heading, not a point behind it)
	# — judged both now and where the two will be in PATROL_FORESIGHT s, so
	# they start turning apart long before they meet
	var push := Vector3.ZERO
	var my_next: Vector3 = pos + me._heading() * patrol_speed * PATROL_FORESIGHT
	for j in _creatures.size():
		if j == i or not _creatures[j].is_visible_in_tree():
			continue
		var other := _creatures[j]
		var away := pos - other.global_position
		var their_next: Vector3 = other.global_position + other._heading() * patrol_speed * PATROL_FORESIGHT
		if my_next.distance_to(their_next) < away.length():
			away = my_next - their_next # closing in: steer by where they will be
		away.y = 0.0 # they part sideways, swimming level, not by climbing out of the waters
		var d := away.length()
		if d < patrol_spacing and d > 0.01:
			push += away / d * (1.0 - d / patrol_spacing)
			# another one is nearer its patrol point than the spacing: pick another
			if _creatures[j].global_position.distance_to(_patrol[i]) < patrol_spacing:
				_patrol[i] = _spaced_point(i)
	var dir := (_patrol[i] - pos).normalized()
	# heading out of the waters: turn back before the edge, not after it — it
	# needs about two turn radii of water to come round
	var ahead: Vector3 = pos + me._heading() * float(me.turn_radius) * 2.0
	var at_edge := not _near_waters(ahead, 0.0)
	if at_edge:
		dir = (_into_waters(ahead, patrol_margin * 2.0) - pos).normalized()
	# and away from a crowding fish — at the edge a little too, so two of them
	# are not pinned side by side, but the edge comes first
	if push.length() > 0.001:
		var urgency := clampf(push.length() * 3.0, 0.0, 1.0)
		dir = dir.lerp(push.normalized(), urgency * (0.3 if at_edge else 0.8)).normalized()
	# a carrot just ahead: cruise_toward swims faster the farther its point
	# (0.3 per m), so this holds it at patrol_speed
	var target := pos + dir * patrol_speed / 0.3
	target.y = _patrol[i].y # at its patrol point's depth, inside the waters
	for kraken in get_tree().get_nodes_in_group(&'kraken'):
		target = kraken.keep_out(target) # idle, they keep out of a kraken's waters
	return target

## A patrol point in the waters as far as can be found from the other fish
## and their patrol points (best of a few random tries).
func _spaced_point(i: int) -> Vector3:
	var best := Vector3.ZERO
	var best_d := -1.0
	for _try in 12:
		var p := _random_in_waters()
		var nearest := INF
		for j in _creatures.size():
			if j == i:
				continue
			nearest = minf(nearest, p.distance_to(_creatures[j].global_position))
			if j < _patrol.size():
				nearest = minf(nearest, p.distance_to(_patrol[j]))
		if nearest > best_d:
			best_d = nearest
			best = p
	return best

## Somewhere inside the waters (patrol_margin in from the edge), the bigger
## shapes picked more often.
func _random_in_waters() -> Vector3:
	var total := 0.0
	for s in _shapes:
		total += _volume(s)
	var pick := _rng.randf() * total
	var shape := _shapes[-1]
	for s in _shapes:
		pick -= _volume(s)
		if pick <= 0.0:
			shape = s
			break
	var m := patrol_margin
	var local := Vector3.ZERO
	var sh: Shape3D = shape.shape
	if sh is BoxShape3D:
		var h: Vector3 = ((sh as BoxShape3D).size * 0.5 - Vector3.ONE * m).max(Vector3.ZERO)
		local = Vector3(_rng.randf_range(-h.x, h.x), _rng.randf_range(-h.y, h.y), _rng.randf_range(-h.z, h.z))
	elif sh is SphereShape3D:
		local = _random_in_disc(maxf((sh as SphereShape3D).radius - m, 0.0), true)
	else: # cylinder, capsule (taken as its cylinder)
		var r: float = maxf(sh.radius - m, 0.0)
		var hh: float = maxf(sh.height * 0.5 - m, 0.0)
		local = _random_in_disc(r, false) + Vector3.UP * _rng.randf_range(-hh, hh)
	return shape.global_transform * local

func _random_in_disc(r: float, ball: bool) -> Vector3:
	for _try in 32:
		var p := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1) if ball else 0.0, _rng.randf_range(-1, 1))
		if p.length_squared() <= 1.0:
			return p * r
	return Vector3.ZERO

func _volume(s: CollisionShape3D) -> float:
	var sh: Shape3D = s.shape
	if sh is BoxShape3D:
		var b: Vector3 = (sh as BoxShape3D).size
		return b.x * b.y * b.z
	if sh is SphereShape3D:
		return 4.18879 * pow((sh as SphereShape3D).radius, 3.0)
	return PI * sh.radius * sh.radius * sh.height

## [how far p is outside the shape (negative: that deep inside), the nearest
## point to p at least `inset` inside it]. In the shape's own space: keep the
## shapes unscaled (size them with their own handles).
## flat: only over its footprint, whatever the height (a swimmer above deep
## waters is over them).
func _shape_gap(s: CollisionShape3D, p: Vector3, inset: float, flat := false) -> Array:
	var xf := s.global_transform
	var l := xf.affine_inverse() * p
	var sh: Shape3D = s.shape
	if flat:
		l.y = 0.0
	if sh is BoxShape3D:
		var h: Vector3 = (sh as BoxShape3D).size * 0.5
		var q := l.abs() - h
		var gap := maxf(q.x, maxf(q.y, q.z)) if q.x <= 0.0 and q.y <= 0.0 and q.z <= 0.0 else q.max(Vector3.ZERO).length()
		var hi: Vector3 = (h - Vector3.ONE * inset).max(Vector3.ZERO)
		return [gap, xf * l.clamp(-hi, hi)]
	if sh is SphereShape3D:
		var rs: float = (sh as SphereShape3D).radius
		return [l.length() - rs, xf * l.limit_length(maxf(rs - inset, 0.0))]
	var r: float = sh.radius
	var hh: float = sh.height * 0.5
	var xz := Vector2(l.x, l.z)
	var dr := xz.length() - r
	var dy := absf(l.y) - hh
	var gap := maxf(dr, dy) if dr <= 0.0 and dy <= 0.0 else Vector2(maxf(dr, 0.0), maxf(dy, 0.0)).length()
	var f := xz.limit_length(maxf(r - inset, 0.0))
	var hi := maxf(hh - inset, 0.0)
	return [gap, xf * Vector3(f.x, clampf(l.y, -hi, hi), f.y)]

## Within `reach` of the waters (always, without any). flat: over them, at any height.
func _near_waters(p: Vector3, reach: float, flat := false) -> bool:
	if _shapes.is_empty():
		return true
	for s in _shapes:
		if _shape_gap(s, p, 0.0, flat)[0] <= reach:
			return true
	return false

## p if it lies at least `inset` inside the waters, else the nearest such point.
func _into_waters(p: Vector3, inset: float) -> Vector3:
	var best := p
	var best_d := INF
	for s in _shapes:
		var g: Array = _shape_gap(s, p, inset)
		if g[0] <= -inset:
			return p
		var d := p.distance_to(g[1])
		if d < best_d:
			best_d = d
			best = g[1]
	return best

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
