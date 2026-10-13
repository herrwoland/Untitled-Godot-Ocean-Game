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
## The player sent a sonar pulse from `origin` (SonarPulse). Anything that should hear it --
## a creature drawn to the sound -- can listen here.
signal sonar_pulsed(origin: Vector3, reach: float)
## The ship's power was cut or restored at the power panel (Boat.set_powered). Creatures drawn
## to a lit ship listen here; `ship.powered` tells the current state at any time.
signal ship_power_changed(ship: Node3D, on: bool)
@warning_ignore_restore("unused_signal")
