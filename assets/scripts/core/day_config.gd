extends Resource
## Data for one in-game day (DESIGN.md §2). The campaign is an array of these.

@export var day: int = 1
@export_multiline var letter_text: String = ""
@export var pickup_position: Vector3
@export var delivery_position: Vector3
## How far below the surface the package rests at the pickup point.
@export var package_depth: float = 6.0
## Full strangeness state applied on waking: prop_id -> variant tier.
@export var wake_swaps: Dictionary = {}
## Extra swaps fired the moment the player returns home (witnessed absence).
@export var return_home_swaps: Dictionary = {}
