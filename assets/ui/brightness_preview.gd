extends Control
## Brightness calibration, the way horror games do it: three dark symbols on black, drawn
## through the same curve as the game. Set the slider so the left one disappears, the middle
## one is barely visible and the right one plainly shows.

## Brightness of the symbols before the curve (0..1, display values): too dark to see,
## just at the edge of seeing, and clearly there.
const SYMBOLS: Array[float] = [0.018, 0.045, 0.11]

## The brightness curve's exponent (see settings_menu.gd): below 1 lifts the shadows.
var exponent := 1.0:
	set(value):
		exponent = value
		queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)
	var r := minf(size.y * 0.32, size.x / 10.0)
	for i in SYMBOLS.size():
		var v := pow(SYMBOLS[i], exponent)
		var centre := Vector2(size.x * (i + 1) / (SYMBOLS.size() + 1), size.y * 0.5)
		# A crescent: a disc with a black bite taken out of it.
		draw_circle(centre, r, Color(v, v, v))
		draw_circle(centre + Vector2(r * 0.45, -r * 0.2), r * 0.85, Color.BLACK)
