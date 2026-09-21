shader_type canvas_item;
/**
 * PS1-style post-process: pixelates the screen to a low target resolution,
 * quantizes colors (posterize, ~15-bit look at 32 levels) and applies ordered
 * Bayer dithering to fake the missing color depth, like PS1-era hardware did.
 * Lives on a fullscreen ColorRect in a CanvasLayer below the UI.
 */

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;
/** Rows of big pixels (roughly: it snaps so each big pixel is a whole number of screen pixels,
 *  otherwise pixels come out uneven, alternately 1 and 2 screen pixels wide). Columns follow the
 *  window so pixels stay square. The 3D scene renders at exactly this grid (settings_menu.gd). */
uniform float target_rows = 240.0;
/** Off = keep the full resolution, only reduce colours and dither. */
uniform bool pixelate = true;
uniform int color_levels : hint_range(2, 64) = 32;
uniform float dither_strength : hint_range(0.0, 2.0) = 1.0;

const mat4 BAYER = mat4(
	vec4( 0.0,  8.0,  2.0, 10.0),
	vec4(12.0,  4.0, 14.0,  6.0),
	vec4( 3.0, 11.0,  1.0,  9.0),
	vec4(15.0,  7.0, 13.0,  5.0));

void fragment() {
	vec2 screen_size = 1.0 / SCREEN_PIXEL_SIZE;
	// Whole screen pixels per big pixel.
	float cell = pixelate ? max(round(screen_size.y / target_rows), 1.0) : 1.0;
	vec2 screen_px = SCREEN_UV * screen_size;
	ivec2 pix = ivec2(floor(screen_px / cell));
	// Sample the centre of the big pixel: exactly one texel of the 3D image rendered at this grid.
	vec2 pixel_uv = (vec2(pix) + 0.5) * cell / screen_size;
	vec3 color = texture(screen_texture, pixel_uv).rgb;

	// Ordered dithering: per low-res pixel threshold offset, scaled to one quantization step.
	float threshold = (BAYER[pix.x % 4][pix.y % 4] + 0.5) / 16.0 - 0.5;
	float levels = float(color_levels - 1);
	color += threshold * dither_strength / levels;

	// Posterize.
	color = clamp(floor(color * levels + 0.5) / levels, 0.0, 1.0);
	COLOR = vec4(color, 1.0);
}
