extends CanvasLayer
## Settings menu covering the categories a medium-scale 3D game usually exposes:
## display (fullscreen/vsync), graphics (render scale, wave resolution, ocean mesh
## quality, water effects preset, rain on lens), audio (master volume), controls (mouse
## sensitivity, FOV) and gameplay (ship engine power). Values persist to user://settings.cfg.

signal closed

const SETTINGS_PATH := "user://settings.cfg"
const WAVE_RESOLUTIONS: Array[int] = [256, 512, 1024] # 128 breaks the ocean, so it's not offered.
const MESH_QUALITY_NAMES: Array[String] = ["Low", "High", "High 8K"]
const EFFECTS_QUALITY_NAMES: Array[String] = ["Low", "Medium", "High"]

var water: Node
var player: Node
var ship: Node
var retro_post: CanvasLayer

@onready var fullscreen_check: CheckButton = %FullscreenCheck
@onready var vsync_check: CheckButton = %VsyncCheck
@onready var render_scale_slider: HSlider = %RenderScaleSlider
@onready var wave_res_option: OptionButton = %WaveResOption
@onready var mesh_quality_option: OptionButton = %MeshQualityOption
@onready var ps1_check: CheckButton = %Ps1Check
@onready var water_fx_option: OptionButton = %WaterFxOption
@onready var lens_drops_check: CheckButton = %LensDropsCheck
@onready var volume_slider: HSlider = %VolumeSlider
@onready var sensitivity_slider: HSlider = %SensitivitySlider
@onready var fov_slider: HSlider = %FovSlider
@onready var engine_power_slider: HSlider = %EnginePowerSlider
@onready var back_button: Button = %BackButton

func _ready() -> void:
	for res in WAVE_RESOLUTIONS:
		wave_res_option.add_item("%dx%d" % [res, res])
	for quality_name in MESH_QUALITY_NAMES:
		mesh_quality_option.add_item(quality_name)
	for quality_name in EFFECTS_QUALITY_NAMES:
		water_fx_option.add_item(quality_name)

	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	vsync_check.toggled.connect(_on_vsync_toggled)
	render_scale_slider.value_changed.connect(_on_render_scale_changed)
	wave_res_option.item_selected.connect(_on_wave_res_selected)
	mesh_quality_option.item_selected.connect(_on_mesh_quality_selected)
	ps1_check.toggled.connect(_on_ps1_toggled)
	water_fx_option.item_selected.connect(_on_water_fx_selected)
	lens_drops_check.toggled.connect(_on_lens_drops_toggled)
	volume_slider.value_changed.connect(_on_volume_changed)
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

func open() -> void:
	_sync_controls_to_current_values()
	visible = true

func _sync_controls_to_current_values() -> void:
	fullscreen_check.set_pressed_no_signal(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN)
	vsync_check.set_pressed_no_signal(DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED)
	render_scale_slider.set_value_no_signal(get_viewport().scaling_3d_scale)
	wave_res_option.select(WAVE_RESOLUTIONS.find(water.map_size))
	mesh_quality_option.select(water.mesh_quality)
	ps1_check.set_pressed_no_signal(retro_post.visible)
	water_fx_option.select(_effects_quality)
	var rain := _rain()
	lens_drops_check.set_pressed_no_signal(rain.lens_drops_enabled if rain else true)
	volume_slider.set_value_no_signal(db_to_linear(AudioServer.get_bus_volume_db(0)))
	sensitivity_slider.set_value_no_signal(player.mouse_sensitivity * 1000.0)
	fov_slider.set_value_no_signal(player.camera.fov)
	engine_power_slider.set_value_no_signal(ship.engine_power)

func _on_fullscreen_toggled(on: bool) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)
	_save_settings()

func _on_vsync_toggled(on: bool) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED)
	_save_settings()

func _on_render_scale_changed(value: float) -> void:
	get_viewport().scaling_3d_scale = value
	_save_settings()

func _on_wave_res_selected(index: int) -> void:
	water.map_size = WAVE_RESOLUTIONS[index]
	_save_settings()

func _on_mesh_quality_selected(index: int) -> void:
	water.mesh_quality = index
	_save_settings()

func _on_ps1_toggled(on: bool) -> void:
	retro_post.visible = on
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
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(value, 0.001)))
	AudioServer.set_bus_mute(0, value <= 0.001)
	_save_settings()

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
	config.set_value("graphics", "render_scale", render_scale_slider.value)
	config.set_value("graphics", "wave_resolution", WAVE_RESOLUTIONS[maxi(wave_res_option.selected, 0)])
	config.set_value("graphics", "mesh_quality", maxi(mesh_quality_option.selected, 0))
	config.set_value("graphics", "ps1_mode", ps1_check.button_pressed)
	config.set_value("graphics", "water_effects", _effects_quality)
	config.set_value("graphics", "lens_drops", lens_drops_check.button_pressed)
	config.set_value("audio", "master_volume", volume_slider.value)
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
	get_viewport().scaling_3d_scale = config.get_value("graphics", "render_scale", 1.0)
	var wave_res: int = config.get_value("graphics", "wave_resolution", 512)
	water.map_size = wave_res if wave_res in WAVE_RESOLUTIONS else 256 # eg. an old saved 128
	water.mesh_quality = config.get_value("graphics", "mesh_quality", 0)
	retro_post.visible = config.get_value("graphics", "ps1_mode", true)
	_apply_effects_quality(config.get_value("graphics", "water_effects", 2))
	var rain := _rain()
	if rain: rain.lens_drops_enabled = config.get_value("graphics", "lens_drops", true)
	var volume: float = config.get_value("audio", "master_volume", 1.0)
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume, 0.001)))
	AudioServer.set_bus_mute(0, volume <= 0.001)
	player.mouse_sensitivity = config.get_value("controls", "mouse_sensitivity", 2.5) / 1000.0
	player.camera.fov = config.get_value("controls", "fov", 75.0)
	ship.set_engine_power(config.get_value("gameplay", "engine_power", 400000.0))
