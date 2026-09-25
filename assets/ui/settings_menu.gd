extends CanvasLayer
## Settings menu, in three tabs: Gameplay (mouse sensitivity, FOV, ship engine power),
## Video (fullscreen, v-sync, frame rate limit, render scale, wave resolution, ocean mesh
## quality, PS1 filter, water effects, rain on lens) and Audio (master volume).
## Audio is split across Master, SFX and Music buses. Values persist to user://settings.cfg.

signal closed

const SETTINGS_PATH := "user://settings.cfg"
const WAVE_RESOLUTIONS: Array[int] = [256, 512, 1024]
## Resolutions that break the ocean. Still listed, greyed out, so it is plain they exist and
## are not simply missing -- and so turning one back on later is a one-line change.
const WAVE_RESOLUTIONS_DISABLED: Array[int] = [256]
const DEFAULT_WAVE_RESOLUTION := 512
const MESH_QUALITY_NAMES: Array[String] = ["Low", "High", "High 8K"]
const EFFECTS_QUALITY_NAMES: Array[String] = ["Low", "Medium", "High"]
## Frame rate caps offered, 0 = uncapped. Engine.max_fps takes these directly.
const FPS_LIMITS: Array[int] = [0, 30, 60, 75, 120, 144, 165, 240]

var water: Node
var player: Node
var ship: Node
var retro_post: CanvasLayer

@onready var fullscreen_check: CheckButton = %FullscreenCheck
@onready var vsync_check: CheckButton = %VsyncCheck
@onready var fps_limit_option: OptionButton = %FpsLimitOption
@onready var render_scale_slider: HSlider = %RenderScaleSlider
@onready var wave_res_option: OptionButton = %WaveResOption
@onready var mesh_quality_option: OptionButton = %MeshQualityOption
@onready var ps1_check: CheckButton = %Ps1Check
@onready var water_fx_option: OptionButton = %WaterFxOption
@onready var lens_drops_check: CheckButton = %LensDropsCheck
@onready var volume_slider: HSlider = %VolumeSlider
@onready var sfx_slider: HSlider = %SfxSlider
@onready var music_slider: HSlider = %MusicSlider
@onready var sensitivity_slider: HSlider = %SensitivitySlider
@onready var fov_slider: HSlider = %FovSlider
@onready var engine_power_slider: HSlider = %EnginePowerSlider
@onready var back_button: Button = %BackButton

func _ready() -> void:
	for i in WAVE_RESOLUTIONS.size():
		var res: int = WAVE_RESOLUTIONS[i]
		wave_res_option.add_item("%dx%d" % [res, res])
		if res in WAVE_RESOLUTIONS_DISABLED:
			wave_res_option.set_item_disabled(i, true)
			wave_res_option.set_item_text(i, "%dx%d (broken)" % [res, res])
	for quality_name in MESH_QUALITY_NAMES:
		mesh_quality_option.add_item(quality_name)
	for quality_name in EFFECTS_QUALITY_NAMES:
		water_fx_option.add_item(quality_name)
	for limit in FPS_LIMITS:
		fps_limit_option.add_item("Unlimited" if limit == 0 else str(limit))

	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	vsync_check.toggled.connect(_on_vsync_toggled)
	fps_limit_option.item_selected.connect(_on_fps_limit_selected)
	render_scale_slider.value_changed.connect(_on_render_scale_changed)
	wave_res_option.item_selected.connect(_on_wave_res_selected)
	mesh_quality_option.item_selected.connect(_on_mesh_quality_selected)
	ps1_check.toggled.connect(_on_ps1_toggled)
	water_fx_option.item_selected.connect(_on_water_fx_selected)
	lens_drops_check.toggled.connect(_on_lens_drops_toggled)
	volume_slider.value_changed.connect(_on_volume_changed)
	sfx_slider.value_changed.connect(_on_sfx_changed)
	music_slider.value_changed.connect(_on_music_changed)
	sensitivity_slider.value_changed.connect(_on_sensitivity_changed)
	fov_slider.value_changed.connect(_on_fov_changed)
	engine_power_slider.value_changed.connect(_on_engine_power_changed)
	back_button.pressed.connect(_on_back_pressed)

## Called by main once the world nodes exist. Loads saved settings and applies them.
func setup(water_node: Node, player_node: Node, ship_node: Node, retro_post_node: CanvasLayer) -> void:
	water = water_node
	player = player_node
	ship = ship_node
	retro_post = retro_post_node
	_load_settings()
	_apply_render_scale() # Also on a first run with no settings file.

func open() -> void:
	_sync_controls_to_current_values()
	visible = true

func _sync_controls_to_current_values() -> void:
	fullscreen_check.set_pressed_no_signal(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN)
	vsync_check.set_pressed_no_signal(DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED)
	fps_limit_option.select(maxi(FPS_LIMITS.find(Engine.max_fps), 0))
	render_scale_slider.set_value_no_signal(_render_scale)
	wave_res_option.select(WAVE_RESOLUTIONS.find(water.map_size))
	mesh_quality_option.select(water.mesh_quality)
	ps1_check.set_pressed_no_signal(retro_post.visible)
	water_fx_option.select(_effects_quality)
	var rain := _rain()
	lens_drops_check.set_pressed_no_signal(rain.lens_drops_enabled if rain else true)
	volume_slider.set_value_no_signal(db_to_linear(AudioServer.get_bus_volume_db(0)))
	sfx_slider.set_value_no_signal(_bus_volume(&'SFX'))
	music_slider.set_value_no_signal(_bus_volume(&'Music'))
	sensitivity_slider.set_value_no_signal(player.mouse_sensitivity * 1000.0)
	fov_slider.set_value_no_signal(player.camera.fov)
	engine_power_slider.set_value_no_signal(ship.engine_power)

func _on_fullscreen_toggled(on: bool) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)
	_save_settings()

func _on_vsync_toggled(on: bool) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED)
	_save_settings()

func _on_fps_limit_selected(index: int) -> void:
	Engine.max_fps = FPS_LIMITS[index]
	_save_settings()

var _render_scale := 1.0

## The 3D scene renders at the PS1 filter's resolution while PS1 mode is on (anything more is
## thrown away by the pixelation), full resolution otherwise. The Render Scale slider scales on
## top of that. The UI is unaffected: it keeps the viewport's own resolution.
func _apply_render_scale() -> void:
	var scale := _render_scale
	if retro_post and retro_post.visible:
		var post := retro_post.get_node_or_null(^'PostRect') as CanvasItem
		var rows = post.material.get_shader_parameter(&'target_rows') if post and post.material else null
		var pixelate = post.material.get_shader_parameter(&'pixelate') if post and post.material else false
		var height := get_viewport().get_visible_rect().size.y
		if pixelate == true and rows is float and height > 0.0:
			# Same whole-pixel cell as ps1_post.gdshader, so each 3D pixel is exactly one big pixel.
			scale *= 1.0 / maxf(round(height / rows), 1.0)
	get_viewport().scaling_3d_scale = scale

func _on_render_scale_changed(value: float) -> void:
	_render_scale = value
	_apply_render_scale()
	_save_settings()

func _on_wave_res_selected(index: int) -> void:
	water.map_size = WAVE_RESOLUTIONS[index]
	_save_settings()

func _on_mesh_quality_selected(index: int) -> void:
	water.mesh_quality = index
	_save_settings()

func _on_ps1_toggled(on: bool) -> void:
	retro_post.visible = on
	_apply_render_scale()
	_save_settings()

var _effects_quality := 2

func _rain() -> Node:
	return get_tree().get_first_node_in_group(&'rain')

func _apply_effects_quality(level: int) -> void:
	_effects_quality = level
	water.set_effects_quality(level)
	var rain := _rain()
	if rain: rain.set_effects_quality(level)

func _on_water_fx_selected(index: int) -> void:
	_apply_effects_quality(index)
	_save_settings()

func _on_lens_drops_toggled(on: bool) -> void:
	var rain := _rain()
	if rain: rain.lens_drops_enabled = on
	_save_settings()

func _on_volume_changed(value: float) -> void:
	_set_bus_volume(0, value)
	_save_settings()

func _on_sfx_changed(value: float) -> void:
	_set_bus_volume(AudioServer.get_bus_index(&'SFX'), value)
	_save_settings()

func _on_music_changed(value: float) -> void:
	_set_bus_volume(AudioServer.get_bus_index(&'Music'), value)
	_save_settings()

## Sets a bus to a 0..1 level, muting it outright at the bottom of the slider so it goes
## properly silent instead of merely very quiet.
func _set_bus_volume(bus: int, value: float) -> void:
	if bus < 0: return
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(value, 0.001)))
	AudioServer.set_bus_mute(bus, value <= 0.001)

func _bus_volume(bus_name: StringName) -> float:
	var bus := AudioServer.get_bus_index(bus_name)
	return db_to_linear(AudioServer.get_bus_volume_db(bus)) if bus >= 0 else 1.0

func _on_sensitivity_changed(value: float) -> void:
	player.mouse_sensitivity = value / 1000.0
	_save_settings()

func _on_fov_changed(value: float) -> void:
	player.camera.fov = value
	_save_settings()

func _on_engine_power_changed(value: float) -> void:
	ship.set_engine_power(value)
	_save_settings()

func _on_back_pressed() -> void:
	visible = false
	closed.emit()

func _save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("display", "fullscreen", fullscreen_check.button_pressed)
	config.set_value("display", "vsync", vsync_check.button_pressed)
	config.set_value("display", "fps_limit", Engine.max_fps)
	config.set_value("graphics", "render_scale", _render_scale)
	config.set_value("graphics", "wave_resolution", WAVE_RESOLUTIONS[maxi(wave_res_option.selected, 0)])
	config.set_value("graphics", "mesh_quality", maxi(mesh_quality_option.selected, 0))
	config.set_value("graphics", "ps1_mode", ps1_check.button_pressed)
	config.set_value("graphics", "water_effects", _effects_quality)
	config.set_value("graphics", "lens_drops", lens_drops_check.button_pressed)
	config.set_value("audio", "master_volume", volume_slider.value)
	config.set_value("audio", "sfx_volume", sfx_slider.value)
	config.set_value("audio", "music_volume", music_slider.value)
	config.set_value("controls", "mouse_sensitivity", sensitivity_slider.value)
	config.set_value("controls", "fov", fov_slider.value)
	config.set_value("gameplay", "engine_power", engine_power_slider.value)
	config.save(SETTINGS_PATH)

func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return # first run: keep project defaults

	if config.get_value("display", "fullscreen", false):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	if not config.get_value("display", "vsync", false):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var fps_limit: int = config.get_value("display", "fps_limit", 0)
	Engine.max_fps = fps_limit if fps_limit in FPS_LIMITS else 0
	_render_scale = config.get_value("graphics", "render_scale", 1.0)
	var wave_res: int = config.get_value("graphics", "wave_resolution", 512)
	# eg. an old saved 128, or a resolution we have since had to disable.
	water.map_size = wave_res if wave_res in WAVE_RESOLUTIONS and not wave_res in WAVE_RESOLUTIONS_DISABLED else DEFAULT_WAVE_RESOLUTION
	water.mesh_quality = config.get_value("graphics", "mesh_quality", 0)
	retro_post.visible = config.get_value("graphics", "ps1_mode", true)
	_apply_effects_quality(config.get_value("graphics", "water_effects", 2))
	var rain := _rain()
	if rain: rain.lens_drops_enabled = config.get_value("graphics", "lens_drops", true)
	_set_bus_volume(0, config.get_value("audio", "master_volume", 1.0))
	_set_bus_volume(AudioServer.get_bus_index(&'SFX'), config.get_value("audio", "sfx_volume", 1.0))
	_set_bus_volume(AudioServer.get_bus_index(&'Music'), config.get_value("audio", "music_volume", 1.0))
	player.mouse_sensitivity = config.get_value("controls", "mouse_sensitivity", 2.5) / 1000.0
	player.camera.fov = config.get_value("controls", "fov", 75.0)
	ship.set_engine_power(config.get_value("gameplay", "engine_power", 400000.0))
