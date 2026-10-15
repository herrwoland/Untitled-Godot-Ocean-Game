shader_type canvas_item;
// The moment of going under (see submerge_lens.gd). Just before, the dark, out-of-focus water
// right in front of the lens rises up the screen from the bottom. Then the exposure is near to
// black and comes back, like a camera set for daylight suddenly under the sea (this also hides any frame where
// the waves glitch as the camera crosses them). And air is left on the lens:
// A bead of air on glass underwater reflects totally at its edge, so it shines silver with the
// light from the surface above; its middle shrinks and blurs the view behind it. They wobble,
// then let go one by one and slide up off the lens. Drawn before the PS1 post-process, so they
// get the same pixelation and dither.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
/** Seconds since the camera went under (large while above water). */
uniform float age = 10.0;
/** How far the water in front of the lens has risen up the screen (0..1, 1 = covered). */
uniform float wipe : hint_range(0.0, 1.0) = 0.0;
/** How much its edge swells up and down across the screen (fraction of screen height). */
uniform float wipe_wave = 0.07;
/** How soft (out of focus) its edge is (fraction of screen height). */
uniform float wipe_softness = 0.06;
/** Brightness of the sky caught along its top, like the lit back of a swell. */
uniform float wipe_sheen = 0.4;
/** Seconds since the beads were left on the lens. */
uniform float bead_age = 10.0;
/** Seconds until the last bead has let go. */
uniform float duration = 0.6;
/** How dark it goes the moment the camera is under (0 = not at all, 1 = black). */
uniform float exposure_dip : hint_range(0.0, 1.0) = 0.97;
/** Seconds it stays that dark before the exposure starts coming back. */
uniform float exposure_hold = 0.1;
/** Seconds until the exposure is back to normal. */
uniform float exposure_time = 0.5;
/** Changes every dive, so no two look the same. */
uniform float seed = 0.0;
uniform int count : hint_range(0, 12) = 9;
/** Radius of a typical bead (fraction of screen height). */
uniform float bead_size = 0.009;
/** How much a bead shrinks the view behind it. */
uniform float refraction = 0.6;
/** Brightness of the silver edge and highlight. */
uniform float brightness = 0.9;
uniform vec3 tint : source_color = vec3(0.75, 0.85, 0.9);
/** Out-of-focus blur inside a bead (mip levels). */
uniform float blur = 2.0;
/** How fast they slide up off the lens (screen heights per second). */
uniform float rise = 0.25;
/** How much their outline trembles. */
uniform float wobble = 1.0;

vec4 hash42(vec2 p) {
	vec4 p4 = fract(vec4(p.xyxy) * vec4(0.1031, 0.1030, 0.0973, 0.1099));
	p4 += dot(p4, p4.wzxy + 33.33);
	return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}

void fragment() {
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 p = SCREEN_UV * vec2(aspect, 1.0); // In screen heights, so beads stay round.
	vec2 bend = vec2(0.0);
	float cover = 0.0;
	float glow = 0.0;
	for (int i = 0; i < (bead_age < duration ? count : 0); i++) {
		vec4 h = hash42(vec2(float(i) * 7.13 + seed, seed * 1.37 + 3.1));
		vec4 g = hash42(h.zw * 91.7 + float(i));
		// Most sit along the top of the lens, some cut off by its edge; now and then a big one lower down.
		bool big = g.x < 0.2;
		vec2 start = vec2(h.x * aspect, big ? mix(0.35, 0.85, h.y) : pow(h.y, 1.5) * 0.55 - 0.08);
		float radius = bead_size * (big ? mix(1.6, 2.4, h.z) : mix(0.45, 1.1, h.z * h.z));
		// They let go one by one, the last of them at `duration`.
		float end = duration * mix(0.35, 1.0, h.w);
		float life = clamp(bead_age / end, 0.0, 1.0);
		float fade = smoothstep(0.0, 0.03, bead_age) * (1.0 - smoothstep(0.55, 1.0, life));
		if (fade <= 0.0) continue;
		// Air rises: they slide up, wander sideways, and speed up as they let go.
		vec2 vel = vec2((g.y - 0.5) * 0.3, -mix(0.4, 1.0, g.z) * (big ? 0.5 : 1.0)) * rise;
		vec2 c = start + vel * (bead_age + bead_age * bead_age * 1.5);
		radius *= mix(0.75, 1.0, fade);
		vec2 d = p - c;
		float dist = length(d);
		if (dist > radius * 1.4) continue;
		float a = atan(d.y, d.x);
		float t = bead_age * 9.0 + g.w * 6.28;
		float r = dist / (radius * (1.0 + wobble * (0.035 * sin(2.0 * a + t) + 0.025 * sin(4.0 * a - t * 1.3 + 1.7))));
		float mask = (1.0 - smoothstep(0.55, 1.05, r)) * fade; // Soft: they're out of focus.
		// The silver ring, brightest on the side facing the surface above, and a highlight.
		float ring = smoothstep(0.6, 0.88, r) * (1.0 - smoothstep(0.88, 1.08, r));
		float lit = 0.35 + 0.65 * clamp(-d.y / max(dist, 1e-5) * 0.5 + 0.5, 0.0, 1.0);
		vec2 hs = d / radius + vec2(0.3, 0.4);
		float spec = exp(-dot(hs, hs) * 30.0);
		glow += (ring * lit * 0.6 + spec * 0.35) * fade;
		bend += d * max(1.0 - r * r, 0.0) * refraction * mask;
		cover = max(cover, mask);
	}
	vec3 col = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	if (cover > 0.001) {
		// Sampling further out from each bead's centre: the view through it looks smaller.
		vec3 through = textureLod(screen_texture, SCREEN_UV + bend / vec2(aspect, 1.0), blur * cover).rgb;
		col = mix(col, through, cover);
	}
	// Dark, then lifting, then easing back. The beads' silver stays bright: blown highlights.
	float exposure = mix(1.0 - exposure_dip, 1.0, smoothstep(exposure_hold, max(exposure_time, exposure_hold + 0.001), age));
	col *= exposure;
	if (wipe > 0.0) {
		// The swell in front of the lens: a soft hump rising from the bottom, its edge rolling
		// across the screen. At wipe = 1 even the lowest dip of the edge is past the top.
		float x = SCREEN_UV.x * aspect;
		float wave = sin(x * 2.3 + TIME * 1.7 + seed) * 0.6 + sin(x * 5.1 - TIME * 2.6 + seed * 2.0) * 0.4;
		float margin = wipe_wave + wipe_softness;
		float edge = wipe * (1.0 + 2.0 * margin) - margin + wave * wipe_wave;
		float below = edge - (1.0 - SCREEN_UV.y); // How far under the edge this pixel is.
		float inside = smoothstep(-wipe_softness, wipe_softness, below);
		// Dark water, with the blurred sky just above the edge caught along its top.
		vec3 sky = textureLod(screen_texture, vec2(SCREEN_UV.x, clamp(1.0 - edge - wipe_softness * 2.0, 0.0, 1.0)), 4.0).rgb;
		vec3 water = col * (1.0 - exposure_dip) + sky * wipe_sheen * exp(-max(below, 0.0) / 0.12);
		col = mix(col, water, inside);
	}
	COLOR = vec4(col + tint * glow * brightness, 1.0);
}
