extends CharacterBody3D
## First person player controller with three states: walking, swimming and
## piloting a ship's helm. Swim state is driven by comparing the player's feet
## height against the wave height sampled from `water`.

enum State { WALK, SWIM, PILOT }

@export var water: Node
@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.5
@export var swim_speed: float = 3.5
@export var jump_velocity: float = 4.5
@export var mouse_sensitivity: float = 0.0025
@export var turn_speed: float = 2.0 # radians/sec, for keyboard look (Q/R) when the mouse isn't captured
@export var swim_enter_depth: float = 0.6 # how deep water must be over the feet before we start swimming
@export var swim_exit_depth: float = 0.45 # while grounded, water shallower than this switches back to walking (wading)
@export var sink_speed: float = 1.0 # constant downward speed while swimming unless swim_up is held
@export var climb_speed: float = 3.0 # speed of hauling up a ship ladder while holding jump/space

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var interact_ray: RayCast3D = $Head/Camera3D/InteractRay
@onready var collider: CollisionShape3D = $Collider
@onready var carry_controller: Node = $CarryController
@onready var splash_particles: GPUParticles3D = $SplashParticles
@onready var surface_ripples: GPUParticles3D = $SurfaceRipples
@onready var splash_player: AudioStreamPlayer = get_node_or_null(^'SplashPlayer')
## Air dragged under as we break the surface. Not breath -- see OxygenController for that;
## this is the cloud that comes down with a body. Tune its look on the node itself.
@onready var plunge_bubbles: BubbleEmitter = get_node_or_null(^'Head/Camera3D/PlungeBubbles')
@onready var gasp_player: AudioStreamPlayer = get_node_or_null(^'GaspPlayer')

var state: State = State.WALK
var piloted_ship: Node = null
var helm_marker: Node3D = null
var hovered_interactable: Object = null
var inspecting: bool = false # set by InspectionController; freezes movement and look
var captured: bool = false # in a hunter's jaws; the CreatureDirector drives our position
## Drowned and limp (see OxygenController): no control, the body just sinks.
var unconscious: bool = false
var unconscious_sink_speed: float = 0.6
var interact_cooldown_until_msec: int = 0
## Ship whose deck is under our feet. Its collision is made of StaticBody3D pieces parented
## to the hull's RigidBody3D, so the physics engine sees them teleport rather than move and
## carries us nowhere: we have to travel with the deck ourselves or it slides out from under us.
var _deck: PhysicsBody3D = null
var _deck_xform: Transform3D
var _deck_coyote: float = 0.0
var _deck_velocity := Vector3.ZERO # measured from the deck's movement, so it is right no
                                   # matter what moves her: engine, waves or a creature
const DECK_COYOTE := 0.35 # keep carrying this long after the deck drops away, so a heaving
                          # sea doesn't shake us loose every time contact is lost
var _climb_target = null # Vector3 deck position, set each frame by a ShipLadder while space is held

const GRAVITY: float = 9.8

@export var underwater_cutoff_hz: float = 600.0 # low-pass cutoff while the camera is submerged

var _lowpass_idx: int = -1
var _last_eye_submersion: float = INF
var _head_base_y: float = 1.6
var _eye_offset: float = 0.0
var _eye_side: float = 1.0 # +1 keeps the eyes above the water, -1 keeps them under
var _ears_underwater: bool = false
var _submerged_at_msec: int = 0 # when the ears last went under, for the surfacing gasp

const GASP_AFTER_SECONDS := 4.0 # dives shorter than this surface without a gasp

## The sea passing exactly through the eyes draws a hard line across the middle of the view:
## a plane through a camera always projects to one. Keep the eyes this far clear of the
## surface, plainly above it or plainly under, rather than sitting in it (0 = allow it).
@export_range(0.0, 0.5, 0.01) var eye_waterline_clearance: float = 0.18
## How fast the surface has to pass the eyes for the plunge to drag a full lungful of air
## under (m/s). Jumping off the deck is well past this; a wave washing over is not.
@export var plunge_full_speed: float = 4.0
## Bubbles from merely drifting through the surface (0..1 of the emitter's budget).
@export_range(0.0, 1.0, 0.01) var plunge_idle_bubbles: float = 0.12
## How long the hardest plunge keeps bubbling (s).
@export_range(0.05, 3.0, 0.05) var plunge_burst_seconds: float = 0.5

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_head_base_y = head.position.y
	floor_snap_length = 0.5 # a deck falling out of a wave can outrun gravity; stay stuck to it
	# Muffle all audio while underwater via a low-pass filter on the Master bus.
	var lowpass := AudioEffectLowPassFilter.new()
	lowpass.cutoff_hz = underwater_cutoff_hz
	_lowpass_idx = AudioServer.get_bus_effect_count(0)
	AudioServer.add_bus_effect(0, lowpass)
	AudioServer.set_bus_effect_enabled(0, _lowpass_idx, false)

func _update_underwater_audio(delta: float) -> void:
	if not water:
		return
	var submersion: float = water.get_wave_height(camera.global_position) - camera.global_position.y
	var underwater: bool = submersion > 0.0 and not water.is_water_hole(camera.global_position)
	# How fast the surface is passing the eyes, for the plunge below.
	var crossing_speed := 0.0
	if _last_eye_submersion != INF and delta > 0.0:
		crossing_speed = absf(submersion - _last_eye_submersion) / delta
	_last_eye_submersion = submersion
	if underwater != _ears_underwater:
		_ears_underwater = underwater
		AudioServer.set_bus_effect_enabled(0, _lowpass_idx, underwater)
		if underwater:
			_plunge(crossing_speed)
			_submerged_at_msec = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - _submerged_at_msec > GASP_AFTER_SECONDS * 1000.0 \
				and gasp_player and gasp_player.stream and not captured:
			gasp_player.play() # breaking the surface after a long dive

## Nudges the eyes out of the waterline. Which side we take is settled while we are plainly
## on one of them, so a wave washing past cannot make the view flick between the two.
func _keep_eyes_clear_of_waterline(delta: float) -> void:
	var target := 0.0
	if water and eye_waterline_clearance > 0.0 and state != State.PILOT and not captured:
		# Work from where the head would sit untouched, never from the nudged position, or the
		# nudge chases its own tail and settles halfway into the very band it is avoiding.
		var eye := camera.global_position
		var rest_eye := eye.y - _eye_offset
		var submersion: float = water.get_wave_height(eye) - rest_eye
		if absf(submersion) > eye_waterline_clearance:
			_eye_side = -1.0 if submersion > 0.0 else 1.0 # commit while the answer is clear
			target = 0.0
		elif _eye_side > 0.0:
			target = submersion + eye_waterline_clearance # hold them clear above
		else:
			target = submersion - eye_waterline_clearance # push them clear under
	_eye_offset = lerpf(_eye_offset, target, 1.0 - exp(-delta * 10.0))
	head.position.y = _head_base_y + _eye_offset

## The air a body drags under with it. Slipping through the surface barely clouds the water;
## jumping off the deck takes a great gout of it down.
func _plunge(crossing_speed: float) -> void:
	if not plunge_bubbles:
		return
	var hardness := clampf(crossing_speed / maxf(plunge_full_speed, 0.1), 0.0, 1.0)
	plunge_bubbles.burst(lerpf(0.12, plunge_burst_seconds, hardness),
			lerpf(plunge_idle_bubbles, 1.0, hardness))

func _update_interact_hover() -> void:
	var target: Object = null
	if interact_ray.is_colliding():
		var collider_hit := interact_ray.get_collider()
		if collider_hit and collider_hit.has_method(&'interact'):
			target = collider_hit

	if target == hovered_interactable:
		return
	if hovered_interactable and is_instance_valid(hovered_interactable) and hovered_interactable.has_method(&'set_highlighted'):
		hovered_interactable.set_highlighted(false)
	if target and target.has_method(&'set_highlighted'):
		target.set_highlighted(true)
	hovered_interactable = target

func _unhandled_input(event: InputEvent) -> void:
	if unconscious:
		return
	if inspecting:
		return # the InspectionController owns input while an item is held up
	if state == State.PILOT and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		head.rotation.y -= event.relative.x * mouse_sensitivity
		camera.rotation.x -= event.relative.y * mouse_sensitivity
		camera.rotation.x = clampf(camera.rotation.x, -PI / 2.0, PI / 2.0)
	elif event.is_action_pressed(&'interact') and not captured:
		_try_interact()

## While captured the body is dragged by the creature: controls and collisions
## are off, but the head is free to look around on the way down.
func set_captured(caught: bool) -> void:
	captured = caught
	collider.disabled = caught
	_deck = null
	velocity = Vector3.ZERO
	surface_ripples.emitting = false

func _physics_process(delta: float) -> void:
	_update_underwater_audio(delta)
	if captured:
		return # the creature moves us; nothing to simulate
	if unconscious:
		velocity = Vector3(0.0, -unconscious_sink_speed, 0.0)
		move_and_slide() # Limp: drift down until the sea floor stops us.
		return
	if inspecting:
		velocity = Vector3.ZERO
		move_and_slide()
		return
	_process_turn_keys(delta)
	if _climb_target != null and state != State.PILOT:
		_process_climb(delta)
		_climb_target = null # the ladder re-requests every frame space is held
		return
	if state != State.PILOT:
		_update_interact_hover()
	match state:
		State.WALK:
			_process_walk(delta)
			_check_enter_swim()
		State.SWIM:
			_process_swim(delta)
			_check_exit_swim()
		State.PILOT:
			_process_pilot(delta)

	_keep_eyes_clear_of_waterline(delta)

func _process_turn_keys(delta: float) -> void:
	var turn := Input.get_action_strength(&'turn_left') - Input.get_action_strength(&'turn_right')
	if turn != 0.0:
		head.rotation.y += turn * turn_speed * delta

## Called each frame by a ShipLadder while the player is on it and holding jump.
func request_climb(deck_position: Vector3) -> void:
	_climb_target = deck_position

## Haul up the ladder: rise until level with the deck point, then step inward
## onto it. Carrying is preserved, so the package can be brought aboard.
func _process_climb(_delta: float) -> void:
	var target: Vector3 = _climb_target
	if global_position.y < target.y - 0.3:
		velocity = Vector3(0, climb_speed, 0) # still below the rail: climb straight up
	else:
		var inward := (target - global_position)
		inward.y = 0.0
		velocity = inward.normalized() * climb_speed # over the rail: step onto the deck
	move_and_slide()
	if global_position.distance_to(target) < 0.6:
		global_position = target
		state = State.WALK

func _process_walk(delta: float) -> void:
	_carry_with_deck(delta)
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif Input.is_action_just_pressed(&'jump'):
		velocity.y = jump_velocity

	var speed := sprint_speed if Input.is_action_pressed(&'sprint') else walk_speed
	var input_dir := Vector2(
		Input.get_action_strength(&'move_right') - Input.get_action_strength(&'move_left'),
		Input.get_action_strength(&'move_back') - Input.get_action_strength(&'move_forward')
	).normalized()
	var move_dir := (head.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	velocity.x = move_dir.x * speed
	velocity.z = move_dir.z * speed

	move_and_slide()
	_update_deck()

## Moves us by however much the deck moved since the last frame and turns us with it, so
## standing still on a boat under way keeps us standing on the same plank.
func _carry_with_deck(delta: float) -> void:
	if not is_instance_valid(_deck):
		_deck = null
		return
	_deck_coyote -= delta
	if _deck_coyote <= 0.0:
		_release_deck() # airborne too long to still count as standing on her
		return
	var step := _deck_step()
	var carried_to := step * global_position
	_deck_velocity = (carried_to - global_position) / delta
	global_position = carried_to
	head.rotation.y += step.basis.get_euler().y

## The deck's movement since we last looked.
func _deck_step() -> Transform3D:
	var step := _deck.global_transform * _deck_xform.affine_inverse()
	_deck_xform = _deck.global_transform
	return step

## Re-anchors to whatever we are standing on at the end of a frame.
func _update_deck() -> void:
	if not is_on_floor():
		return # the coyote timer keeps us aboard for a moment; _carry_with_deck runs it down
	var ship := _ship_under_feet()
	if not ship:
		if _deck: _release_deck() # stepped off onto the island, or a jetty
		return
	if ship != _deck:
		_deck_velocity = Vector3.ZERO
	_deck = ship
	_deck_xform = ship.global_transform
	_deck_coyote = DECK_COYOTE

## Lets go of the deck, keeping its momentum, so stepping off a moving boat throws us
## forward the way it should instead of dropping us straight down.
func _release_deck() -> void:
	velocity += _deck_velocity
	_deck = null
	_deck_coyote = 0.0
	_deck_velocity = Vector3.ZERO

## The hull under our feet, found by looking past the deck's static collision pieces to the
## body they hang from -- a ship, or anything else built to move under us. A ray rather than
## the slide collisions: standing perfectly still reports none.
func _ship_under_feet() -> PhysicsBody3D:
	var from := global_position + Vector3.UP * 0.3
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 0.8,
			collision_mask, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var node = hit.get('collider') if hit else null
	while node is Node:
		if node is RigidBody3D or node is AnimatableBody3D:
			return node
		node = node.get_parent() # the deck's own StaticBody3D pieces are not what carries us
	return null

func _process_swim(delta: float) -> void:
	var surface_y: float = water.get_wave_height(global_position)
	var swim_top_y: float = surface_y - 0.4 # highest the feet can get: head roughly at the surface

	var input_dir := Vector2(
		Input.get_action_strength(&'move_right') - Input.get_action_strength(&'move_left'),
		Input.get_action_strength(&'move_back') - Input.get_action_strength(&'move_forward')
	).normalized()
	var move_dir := head.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)
	if move_dir.length() > 0.0:
		move_dir = move_dir.normalized()

	velocity.x = move_dir.x * swim_speed
	velocity.z = move_dir.z * swim_speed

	# The player constantly sinks; swim_up (space) is required to rise or stay afloat,
	# swim_down speeds up the sinking.
	if Input.is_action_pressed(&'swim_up'):
		velocity.y = swim_speed
	elif Input.is_action_pressed(&'swim_down'):
		velocity.y = -swim_speed
	else:
		velocity.y = -sink_speed

	move_and_slide()

	# You can't swim out of the water: clamp to the wave surface so holding
	# swim_up rides the waves instead of launching into the sky.
	if global_position.y > swim_top_y:
		global_position.y = swim_top_y
		velocity.y = minf(velocity.y, 0.0)

	# Keep the surface ripples sitting on the waves above us.
	surface_ripples.global_position = Vector3(global_position.x, surface_y, global_position.z)

func _process_pilot(delta: float) -> void:
	if not is_instance_valid(helm_marker):
		exit_pilot()
		return

	global_position = helm_marker.global_position
	velocity = Vector3.ZERO
	if is_instance_valid(_deck):
		head.rotation.y += _deck_step().basis.get_euler().y # the helm turns with her

	var throttle := Input.get_action_strength(&'move_forward') - Input.get_action_strength(&'move_back')
	var rudder := Input.get_action_strength(&'move_right') - Input.get_action_strength(&'move_left')
	if piloted_ship and piloted_ship.has_method(&'set_helm_input'):
		piloted_ship.set_helm_input(throttle, rudder)

	if Input.is_action_just_pressed(&'jump'):
		exit_pilot()

func _check_enter_swim() -> void:
	if not water:
		return
	if water.is_water_hole(global_position):
		return # inside a HOLE wave blocker (eg. a dry shaft) there is no water to swim in
	var surface_y: float = water.get_wave_height(global_position)
	if surface_y - global_position.y > swim_enter_depth:
		state = State.SWIM
		_release_deck()
		collider.disabled = false
		_play_splash(surface_y)
		surface_ripples.emitting = true

func _check_exit_swim() -> void:
	if not water:
		return
	# Standing on ground (eg. a beach slope or the ship's deck) in shallow-enough
	# water means we can wade: back to walking, which also restores jumping.
	var surface_y: float = water.get_wave_height(global_position)
	if is_on_floor() and surface_y - global_position.y < swim_exit_depth:
		state = State.WALK
		surface_ripples.emitting = false

func _play_splash(surface_y: float) -> void:
	splash_particles.global_position = Vector3(global_position.x, surface_y, global_position.z)
	splash_particles.restart()
	if splash_player and splash_player.stream:
		splash_player.play()

func _try_interact() -> void:
	if state == State.PILOT:
		return # piloting is only exited via the jump (space) key
	if Time.get_ticks_msec() < interact_cooldown_until_msec:
		return # eg. the press that just closed an inspection
	if carry_controller.is_carrying():
		carry_controller.drop() # hands full: interact always means "put it down"
		return
	if hovered_interactable and hovered_interactable.has_method(&'interact'):
		hovered_interactable.interact(self)

func enter_pilot(ship: Node, marker: Node3D) -> void:
	if state == State.PILOT:
		return
	if hovered_interactable and hovered_interactable.has_method(&'set_highlighted'):
		hovered_interactable.set_highlighted(false)
	hovered_interactable = null
	state = State.PILOT
	piloted_ship = ship
	helm_marker = marker
	_deck = ship as PhysicsBody3D
	if _deck: _deck_xform = _deck.global_transform
	collider.disabled = true
	velocity = Vector3.ZERO
	if ship.has_method(&'set_piloted'):
		ship.set_piloted(true)

func exit_pilot() -> void:
	if piloted_ship and piloted_ship.has_method(&'set_piloted'):
		piloted_ship.set_piloted(false)
	if is_instance_valid(helm_marker):
		global_position = helm_marker.global_position + helm_marker.global_transform.basis.y * 0.1
	state = State.WALK
	piloted_ship = null
	helm_marker = null
	collider.disabled = false
	if is_instance_valid(_deck): # step off the helm already moving with her
		_deck_xform = _deck.global_transform
		_deck_coyote = DECK_COYOTE
