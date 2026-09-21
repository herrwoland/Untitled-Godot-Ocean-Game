shader_type spatial;
// Draws marine snow specks and bubbles as small hard-edged billboard dots. They are opaque (with
// discard) on purpose: they write depth, so the underwater effect fogs each one by its real
// distance and the caustics play over them. Transparent sprites would be fogged as if far away.
//
// Lit by scene lights with a scattering model instead of surface shading: a speck is brighter
// when it sits between the camera and a light (forward scattering, the "sparkle in the beam").
// Directional lights (sun/moon) only reach them through the water and dim with depth; local
// lights (lamps, lures) work at any depth. Sky ambient is ignored: `ambient_glow` stands in for
// the light scattered around by the water itself, which also dims with depth.
render_mode cull_disabled, shadows_disabled, ambient_light_disabled, specular_disabled;

uniform vec3 color : source_color = vec3(0.55, 0.62, 0.58);
/** 0 = solid dot (marine snow), 1 = hollow ring with a highlight (bubble). */
uniform float ring = 0.0;
/** Square specks instead of round ones (PS1 look). */
uniform bool square = false;
/** Specks further than this fade out (dithered) (m). */
uniform float fade_distance = 14.0;
/** Mean water level (world y) and light lost per meter of depth, matching the underwater
 *  effect's depth darkening, so specks and bubbles dim as you sink. Set by script. */
uniform float water_level = 0.0;
uniform float depth_darkening = 0.04;

group_uniforms lighting;
/** Brightness with no light shining on it (scattered water light), dims with depth. */
uniform float ambient_glow : hint_range(0.0, 2.0, 0.01) = 0.45;
/** Strength of the sun/moon on the specks (dims with depth). */
uniform float sun_scatter : hint_range(0.0, 4.0, 0.01) = 0.8;
/** Strength of local lights (lamps, lures) on the specks. */
uniform float local_scatter : hint_range(0.0, 12.0, 0.01) = 5.0;
/** How much more a speck glows when it's between the camera and the light (0 = even). */
uniform float forward_scatter : hint_range(0.0, 0.95, 0.01) = 0.6;
group_uniforms;

varying float depth_light;

float bayer4(vec2 p) {
	ivec2 i = ivec2(mod(p, 4.0));
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[i.y * 4 + i.x]) + 0.5) / 16.0;
}

void vertex() {
	// Camera-facing billboard, keeping the particle's scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0, 0, 0), vec4(0, length(MODEL_MATRIX[1].xyz), 0, 0), vec4(0, 0, length(MODEL_MATRIX[2].xyz), 0), vec4(0, 0, 0, 1));
	depth_light = exp(-depth_darkening * max(water_level - MODEL_MATRIX[3].y, 0.0));
}

void fragment() {
	float r = length(UV - 0.5) * 2.0;
	if (!square && r > 1.0) discard;
	float fade = 1.0 - smoothstep(fade_distance * 0.6, fade_distance, length(VERTEX));
	if (fade < bayer4(FRAGCOORD.xy)) discard;
	vec3 c = color * COLOR.rgb;
	if (ring > 0.5) {
		// Bubble: bright rim, faint body, a highlight up and to the left.
		float rim = smoothstep(0.55, 0.85, r);
		float highlight = 1.0 - smoothstep(0.0, 0.3, length(UV - vec2(0.35, 0.3)));
		if (rim < 0.5 && highlight < 0.5 && bayer4(FRAGCOORD.xy + 1.0) > 0.25) discard;
		c *= 0.6 + 0.8 * max(rim, highlight);
	}
	ALBEDO = c;
	NORMAL = vec3(0.0, 0.0, 1.0); // Faces the camera; scattering ignores it anyway.
	EMISSION = c * ambient_glow * depth_light;
}

// Henyey-Greenstein phase, normalised so 1 = the same brightness as isotropic scattering.
float scatter_phase(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5);
}

void light() {
	// LIGHT points to the light, VIEW to the camera: cos = 1 when the light is behind the speck.
	float phase = min(scatter_phase(dot(LIGHT, -VIEW), forward_scatter), 4.0); // Capped: no blow-out staring into a lamp.
	float strength = LIGHT_IS_DIRECTIONAL ? sun_scatter * depth_light : local_scatter;
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * phase * strength / PI;
}
