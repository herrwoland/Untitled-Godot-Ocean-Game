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
var _climb_target = null # Vector3 deck position, set each frame by a ShipLadder while space is held

const GRAVITY: float = 9.8

@export var underwater_cutoff_hz: float = 600.0 # low-pass cutoff while the camera is submerged

var _lowpass_idx: int = -1
var _ears_underwater: bool = false
var _submerged_at_msec: int = 0 # when the ears last went under, for the surfacing gasp

const GASP_AFTER_SECONDS := 4.0 # dives shorter than this surface without a gasp

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# Muffle all audio while underwater via a low-pass filter on the Master bus.
	var lowpass := AudioEffectLowPassFilter.new()
	lowpass.cutoff_hz = underwater_cutoff_hz
	_lowpass_idx = AudioServer.get_bus_effect_count(0)
	AudioServer.add_bus_effect(0, lowpass)
	AudioServer.set_bus_effect_enabled(0, _lowpass_idx, false)

func _update_underwater_audio() -> void:
	if not water:
		return
	var underwater: bool = camera.global_position.y < water.get_wave_height(camera.global_position) \
		and not water.is_water_hole(camera.global_position)
	if underwater != _ears_underwater:
		_ears_underwater = underwater
		AudioServer.set_bus_effect_enabled(0, _lowpass_idx, underwater)
		if underwater:
			_submerged_at_msec = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - _submerged_at_msec > GASP_AFTER_SECONDS * 1000.0 \
				and gasp_player and gasp_player.stream and not captured:
			gasp_player.play() # breaking the surface after a long dive

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
	velocity = Vector3.ZERO
	surface_ripples.emitting = false

func _physics_process(delta: float) -> void:
	_update_underwater_audio()
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
