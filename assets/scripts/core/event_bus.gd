extends Node
## Global signal hub (autoload). Systems communicate through these signals
## instead of holding direct references to each other. See DESIGN.md §5.

@warning_ignore_start("unused_signal")
signal day_started(day: int)
signal letter_read
signal package_picked_up
signal package_delivered
signal returned_home
signal player_died
signal strangeness_triggered(tier: int)
## Shake the player's view: trauma rises to at least `trauma` (0..1), then
## fades. Emit once for a jolt, every frame for a held rumble (CameraShake).
signal camera_shake_requested(trauma: float)
@warning_ignore_restore("unused_signal")
