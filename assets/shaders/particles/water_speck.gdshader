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
/** Snap the dot/ring shape to this many pixels across (0 = smooth). */
uniform float pixel_grid = 0.0;
/** Optional sprite (alpha-tested, nearest filtering) replacing the built-in shape. */
uniform bool use_sprite = false;
uniform sampler2D sprite : source_color, filter_nearest;
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
/** Strength of UnderwaterGlow nodes on the specks. Much stronger than the glow's own halo on
 *  purpose: a speck scatters far more light than the same patch of clear water. */
uniform float glow_scatter : hint_range(0.0, 400.0, 0.1) = 100.0;
/** A speck lit by an UnderwaterGlow is a pinpoint of light: however far and small, it's drawn at
 *  least this many pixels across (dimmed to match), so it glints instead of vanishing between
 *  pixels. Unlit specks keep their real size. */
uniform float glint_min_pixels : hint_range(0.0, 6.0, 0.1) = 2.5;
group_uniforms;

// UnderwaterGlow nodes, set every frame by script (water.gd's apply_glows_to()). They aren't
// Godot lights, so light() never sees them: they are added here instead.
uniform int glow_count = 0;
uniform vec4 glow_a[16]; // (position, core size)
uniform vec4 glow_b[16]; // (colour * strength, reach)
uniform float glow_strength = 1.0; // The Water node's underwater_glow_strength.
uniform float viewport_height = 720.0; // Pixels, for glint_min_pixels.

varying float depth_light;
varying vec3 glow_light; // UnderwaterGlow light on this speck, worked out once per speck.

// Henyey-Greenstein phase, normalised so 1 = the same brightness as isotropic scattering.
float scatter_phase(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5);
}

// Light the UnderwaterGlow nodes shine on a speck: falls off with the square of the distance
// (softened inside the glow's core), dimmed by the murk on the way (same `reach` as the halo in
// the water), and much brighter when the speck is backlit, between us and the light.
vec3 glow_on_speck(vec3 pos, vec3 to_camera) {
	vec3 sum = vec3(0.0);
	for (int i = 0; i < glow_count; i++) {
		vec4 a = glow_a[i];
		vec4 b = glow_b[i];
		vec3 to_light = a.xyz - pos;
		float r2 = dot(to_light, to_light);
		float r = sqrt(r2);
		float size = max(a.w, 0.01);
		float falloff = size * size / (r2 + size * size);
		float murk = exp(-3.0 / max(b.w, 1.0) * max(r - size, 0.0));
		float phase = min(scatter_phase(dot(to_light / max(r, 1e-4), -to_camera), forward_scatter), 4.0);
		sum += b.rgb * falloff * murk * phase;
	}
	return sum;
}

float bayer4(vec2 p) {
	ivec2 i = ivec2(mod(p, 4.0));
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[i.y * 4 + i.x]) + 0.5) / 16.0;
}

void vertex() {
	vec3 pos = MODEL_MATRIX[3].xyz;
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	depth_light = exp(-depth_darkening * max(water_level - pos.y, 0.0));
	glow_light = vec3(0.0);
	float grow = 1.0;
	if (glow_count > 0) {
		vec3 to_camera = CAMERA_POSITION_WORLD - pos;
		float dist = max(length(to_camera), 0.01);
		glow_light = glow_on_speck(pos, to_camera / dist) * glow_scatter * glow_strength;
		// Lit specks glint: keep them at least glint_min_pixels across, dimmed by how much they
		// grew (by the width, not the area: a pinpoint that bright still catches the eye).
		float pixels = scale.y * abs(PROJECTION_MATRIX[1][1]) * viewport_height * 0.5 / dist;
		// Only specks lit well past the surrounding water glint: grown, a faintly lit one would just
		// be a bigger dark dot.
		float lit = smoothstep(0.5, 2.0, dot(glow_light, vec3(0.3333)));
		grow = mix(1.0, clamp(glint_min_pixels / max(pixels, 1e-3), 1.0, 3.0), lit);
		glow_light /= grow;
	}
	// Camera-facing billboard, keeping the particle's scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(scale.x * grow, 0, 0, 0), vec4(0, scale.y * grow, 0, 0), vec4(0, 0, scale.z * grow, 0), vec4(0, 0, 0, 1));
}

void fragment() {
	vec2 uv = pixel_grid > 0.5 ? (floor(UV * pixel_grid) + 0.5) / pixel_grid : UV;
	float r = length(uv - 0.5) * 2.0;
	float fade = 1.0 - smoothstep(fade_distance * 0.6, fade_distance, length(VERTEX));
	if (fade < bayer4(FRAGCOORD.xy)) discard;
	vec3 c = color * COLOR.rgb;
	if (use_sprite) {
		vec4 tex = texture(sprite, UV);
		if (tex.a < 0.5) discard;
		c *= tex.rgb;
	} else if (!square && r > 1.0) {
		discard;
	} else if (ring > 0.5) {
		// Bubble: bright rim, faint body, a highlight up and to the left.
		float rim = smoothstep(0.55, 0.85, r);
		float highlight = 1.0 - smoothstep(0.0, 0.3, length(uv - vec2(0.35, 0.3)));
		if (rim < 0.5 && highlight < 0.5 && bayer4(FRAGCOORD.xy + 1.0) > 0.25) discard;
		c *= 0.6 + 0.8 * max(rim, highlight);
	}
	ALBEDO = c;
	NORMAL = vec3(0.0, 0.0, 1.0); // Faces the camera; scattering ignores it anyway.
	EMISSION = c * (ambient_glow * depth_light + glow_light);
}

void light() {
	// LIGHT points to the light, VIEW to the camera: cos = 1 when the light is behind the speck.
	float phase = min(scatter_phase(dot(LIGHT, -VIEW), forward_scatter), 4.0); // Capped: no blow-out staring into a lamp.
	float strength = LIGHT_IS_DIRECTIONAL ? sun_scatter * depth_light : local_scatter;
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * phase * strength / PI;
}
