shader_type canvas_item;
/**
 * Low-res post-process, ported from Obol's post_processing_combined.gdshader (scenes/low_res):
 * radial chromatic aberration, pixel snapping, a 4x4 ordered dither added equally to all three
 * channels, colour quantization and an optional 16-colour palette. Obol runs it on a
 * SubViewportContainer's texture; here it reads the screen from a fullscreen ColorRect
 * (RetroPost/PostRect in main.tscn, toggled by the PS1 setting).
 */

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;

// --- Look ---
uniform bool shader_enabled = true;
uniform bool use_palette = false;
uniform sampler2D palette;
uniform bool dithering = false;
uniform int dithering_size : hint_range(1, 16) = 2;
uniform int resolution_scale : hint_range(1, 64) = 2;
uniform int quantization_level : hint_range(2, 32) = 16;

// --- Chromatic aberration ---
uniform float aberration_intensity : hint_range(0.0, 50.0, 0.1) = 1.0;
uniform float aberration_threshold : hint_range(0.0, 2.0, 0.1) = 1.0;

int dithering_pattern(ivec2 fragcoord) {
	const int pattern[] = {
		-4, +0, -3, +1,
		+2, -2, +3, -1,
		-3, +1, -4, +0,
		+3, -1, +2, -2
	};
	int x = fragcoord.x % 4;
	int y = fragcoord.y % 4;
	return pattern[y * 4 + x] * dithering_size;
}

float color_distance(vec3 a, vec3 b) {
	vec3 diff = a - b;
	return dot(diff, diff);
}

vec3 quantize_color(vec3 color, int levels) {
	if (levels <= 1) return vec3(0.0);
	float step_size = 1.0 / float(levels - 1);
	return round(color / step_size) * step_size;
}

float vector_angle(vec2 v) {
	if (abs(v.x) < 0.0001 && abs(v.y) < 0.0001) return 0.0;
	return atan(v.y, v.x);
}

vec2 rotate_vector(vec2 v, float cos_theta, float sin_theta) {
	return vec2(
		v.x * cos_theta - v.y * sin_theta,
		v.x * sin_theta + v.y * cos_theta
	);
}

// Samples the screen with pixelation snapping applied.
vec4 sample_pixelated(sampler2D tex, vec2 uv) {
	vec2 tex_size = vec2(textureSize(tex, 0));
	ivec2 texel_coord = ivec2(floor(uv * tex_size / float(resolution_scale)));
	return texelFetch(tex, texel_coord * resolution_scale, 0);
}

void fragment() {
	vec4 final_color;

	if (!shader_enabled) {
		final_color = texture(screen_texture, SCREEN_UV);
	} else {
		vec2 tex_size = vec2(textureSize(screen_texture, 0));
		if (tex_size.x <= 0.0 || tex_size.y <= 0.0) {
			final_color = vec4(0.0);
		} else {
			// Aberration displacement, growing towards the edges.
			vec2 center = vec2(0.5);
			vec2 dir = SCREEN_UV - center;
			float angle = vector_angle(dir);
			float dist = 2.0 * length(dir);
			float effect = exp(aberration_intensity * (dist - aberration_threshold));

			vec2 r_displacement = rotate_vector(effect * aberration_intensity * vec2(-1.0, 0.0), cos(angle), sin(angle));
			vec2 b_displacement = rotate_vector(effect * aberration_intensity * vec2(1.0, 0.0), cos(angle), sin(angle));

			vec2 pixel_size = 1.0 / tex_size;

			// Each channel sampled with pixelation + its aberration offset.
			float r = sample_pixelated(screen_texture, SCREEN_UV + r_displacement * pixel_size).r;
			float g = sample_pixelated(screen_texture, SCREEN_UV).g;
			float b = sample_pixelated(screen_texture, SCREEN_UV + b_displacement * pixel_size).b;
			float a = sample_pixelated(screen_texture, SCREEN_UV).a;

			vec3 color = vec3(r, g, b);

			// Dithering: the same offset on all three channels.
			ivec2 texel_coord = ivec2(floor(SCREEN_UV * tex_size / float(resolution_scale)));
			if (dithering) {
				int dither = dithering_pattern(texel_coord);
				color += vec3(float(dither) / 255.0);
			}
			color = clamp(color, 0.0, 1.0);
			color = quantize_color(color, quantization_level);

			// Palette matching.
			if (use_palette) {
				int palette_size = 16;
				float closest_distance = 9999.0;
				vec4 closest_color = vec4(0.0);
				for (int i = 0; i < palette_size; i++) {
					float u = float(i) / float(palette_size - 1);
					vec3 palette_color = texture(palette, vec2(u, 0.0)).rgb;
					float d = color_distance(color, palette_color);
					if (d < closest_distance) {
						closest_distance = d;
						closest_color = vec4(palette_color, 1.0);
					}
				}
				final_color = closest_color;
			} else {
				final_color = vec4(color, 1.0);
			}
		}
	}

	COLOR = final_color;
}
