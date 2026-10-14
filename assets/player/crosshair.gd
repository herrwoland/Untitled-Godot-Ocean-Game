extends Control
## A small square dot at the center of the viewport: where you look and what you'll touch, no
## more. A faint dark border keeps it readable against a bright sky or sea foam.

## Width of the dot in pixels.
@export var dot_size: float = 4.0
@export var color: Color = Color(1.0, 1.0, 1.0, 0.55)
## Width of the dark border around the dot (0 = none).
@export var outline: float = 1.0
@export var outline_color: Color = Color(0.0, 0.0, 0.0, 0.2)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)

func _draw() -> void:
	var center := (size / 2.0).round()
	var dot := Rect2(center - Vector2.ONE * dot_size / 2.0, Vector2.ONE * dot_size)
	if outline > 0.0:
		# A frame around the dot, not a square under it: both are see-through, so a dark square
		# behind would grey the dot.
		var o := outline
		var p := dot.position
		var w := dot_size
		draw_rect(Rect2(p + Vector2(-o, -o), Vector2(w + 2.0 * o, o)), outline_color) # top
		draw_rect(Rect2(p + Vector2(-o, w), Vector2(w + 2.0 * o, o)), outline_color) # bottom
		draw_rect(Rect2(p + Vector2(-o, 0.0), Vector2(o, w)), outline_color) # left
		draw_rect(Rect2(p + Vector2(w, 0.0), Vector2(o, w)), outline_color) # right
	draw_rect(dot, color)
