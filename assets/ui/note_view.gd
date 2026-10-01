extends CanvasLayer
## Fullscreen diegetic text overlay for letters, notes and short messages.
## Pauses the game while open; interact (E) puts the note away.

@onready var note_label: Label = %NoteLabel
@onready var paper_player: AudioStreamPlayer = get_node_or_null(^'PaperPlayer')

var _closable_after_msec: int = 0

func _ready() -> void:
	add_to_group(&'note_view')

func show_note(text: String) -> void:
	note_label.text = text
	visible = true
	get_tree().paused = true
	_play_paper()
	# The interact press that opened the note must not immediately close it.
	_closable_after_msec = Time.get_ticks_msec() + 250

func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&'interact') and Time.get_ticks_msec() > _closable_after_msec:
		# The press that closes the note must not also reach the player, who
		# would re-interact with whatever was hovered before the pause.
		get_viewport().set_input_as_handled()
		visible = false
		get_tree().paused = false
		_play_paper()

func _play_paper() -> void:
	if paper_player and paper_player.stream:
		paper_player.play()
