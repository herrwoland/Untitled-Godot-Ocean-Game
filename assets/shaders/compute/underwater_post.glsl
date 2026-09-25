#[versions]

shafts = "#define MODE_SHAFTS";
composite = "";

#[compute]

#version 450

#VERSION_DEFINES
// Underwater screen effect (runs after transparents, see underwater_effect.gd).
// Per pixel: how far does this ray travel through water before it leaves through the surface
// or hits something? That length carries the absorption, in-scattering, shafts, wobble, blur
// and vignette. Asking instead where the ray STARTS paints the sky with water colour whenever
// the lens is near the surface, because the near plane is a few centimeters tall. The waterline where a wave
// crosses the lens is torn up with froth and bubbles.
// Two versions: `shafts` ray marches light shafts at half resolution (noisy, cheap), and
// `composite` blurs them away while applying everything else at full resolution.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#ifdef MODE_SHAFTS
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D shaft_image;
#else
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D color_image;
layout(set = 0, binding = 2) uniform sampler2D source_tex; // Copy of the color buffer.
layout(set = 0, binding = 6) uniform sampler2D shaft_tex;  // Output of the shafts pass.
#endif
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 3) uniform sampler2DArray displacements;
layout(set = 0, binding = 4, std140) uniform Params {
	mat4 inv_projection;
	mat4 cam_to_world;
	vec4 map_scales[4];   // xy uv scale, z displacement scale
	vec4 fog_color;       // rgb in-scattered colour, a = light loss per meter of depth
	vec4 absorption;      // rgb extinction per meter, a = number of cascades
	vec4 effect;          // x time, y distortion, z blur (px), w waterline width (px)
	vec4 effect2;         // x vignette, y water level (world y), z silhouette range (m), w waterline foam
	vec4 sun_dir;         // xyz direction towards the sun (world), w = shaft strength
	vec4 sun_color;       // rgb light colour * energy, w = max shaft march distance (m)
	vec4 shafts;          // x focus map uv scale, y march steps, z forward scattering g, w contrast
	vec4 shaft_tint;      // rgb tint, a = max brightness
	vec4 shafts2;         // x threshold, y waterline churn, z wave blocker count, w lens submersion (m)
	vec4 shape_count;     // x = number of water shapes
	vec4 shape_a[16];
	vec4 shape_b[16];
	vec4 shadow_origin;   // Sun shadow map, see water_shadow.glsli.
	vec4 shadow_right;
	vec4 shadow_up;
	vec4 shadow_fwd;
	vec4 fog_gradient;    // x brightness looking straight down, y looking straight up
	vec4 blocker_a[8];    // Wave blockers, see wave_blocker.gd: (pos.x, pos.z, frame cos, frame sin)
	vec4 blocker_b[8];    // (half x / radius, half z / capsule half length, fade width, flags)
} p;

#include "water_shapes.glsli"

#ifdef MODE_SHAFTS
layout(set = 0, binding = 5) uniform sampler2D focus_tex; // Light focus map, see caustics.glsl.
layout(set = 0, binding = 7) uniform sampler2D shadow_tex; // Sun shadow map, see water_shadow.glsli.
#include "water_shadow.glsli"
#endif

layout(push_constant, std430) uniform PushConstant {
	vec2 size;       // Full resolution.
	vec2 shaft_size; // Half resolution light shaft buffer.
} pc;

vec3 view_pos(vec2 uv, float depth) {
	// No y flip here: inv_projection comes from get_view_projection(), which already carries
	// it. Flipping again turns every direction taken from here upside down.
	vec4 v = p.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return v.xyz / v.w;
}

// Calm zones (ShoreCalm and the like) flatten the waves, so the surface here is not the one
// the FFT alone would give. Without this the effect tests against a sea that is not being
// drawn, and everything keyed to the waterline goes wrong near a shore.
// Must mirror wave_blocker_eval() in water.gdshader and blocker_mask() in water.gd.
float wave_blocker_mask(vec2 pos) {
	float mask = 1.0;
	int count = int(p.shafts2.z + 0.5);
	for (int i = 0; i < count; i++) {
		vec4 a = p.blocker_a[i];
		vec4 b = p.blocker_b[i];
		vec2 rel = pos - a.xy;
		int flags = int(b.w + 0.5);
		vec2 lp = vec2(a.z*rel.x + a.w*rel.y, -a.w*rel.x + a.z*rel.y);
		float d;
		if ((flags & 1) == 1) { // box footprint, rotated by yaw
			vec2 q = abs(lp) - b.xy;
			d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
		} else if ((flags & 4) == 4) { // capsule seen from above
			d = length(vec2(max(abs(lp.x) - b.y, 0.0), lp.y)) - b.x;
		} else { // circle
			d = length(rel) - b.x;
		}
		mask = min(mask, smoothstep(0.0, max(b.z, 0.001), d));
	}
	return mask;
}

vec3 displacement(vec2 xz) {
	vec3 d = vec3(0.0);
	int n = int(p.absorption.a);
	for (int i = 0; i < n; i++) {
		vec4 s = p.map_scales[i];
		d += textureLod(displacements, vec3(xz * s.xy, float(i)), 0.0).xyz * s.z;
	}
	return d;
}

// The FFT displaces horizontally too (choppy waves), so find which rest position lands on
// `xz` with a couple of fixed-point iterations before reading the height.
float wave_height(vec2 xz) {
	vec2 shape = water_shapes(xz);
	float calm = wave_blocker_mask(xz);
	vec2 rest = xz;
	vec3 d = vec3(0.0);
	for (int i = 0; i < 3; i++) {
		d = displacement(rest) * (1.0 - shape.y) * calm;
		rest = xz - d.xz;
	}
	return p.effect2.y + d.y + shape.x;
}

#ifndef MODE_SHAFTS
float hash12(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
	           mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}

vec3 blurred(vec2 uv, float radius_px) {
	vec2 r = radius_px / pc.size;
	vec3 c = textureLod(source_tex, uv, 0.0).rgb * 0.4;
	c += textureLod(source_tex, uv + vec2( r.x,  r.y), 0.0).rgb * 0.15;
	c += textureLod(source_tex, uv + vec2(-r.x,  r.y), 0.0).rgb * 0.15;
	c += textureLod(source_tex, uv + vec2( r.x, -r.y), 0.0).rgb * 0.15;
	c += textureLod(source_tex, uv + vec2(-r.x, -r.y), 0.0).rgb * 0.15;
	return c;
}

// 3x3 tent of bilinear taps over the half-res shaft buffer: hides the ray march dither.
vec3 shafts_filtered(vec2 uv) {
	vec2 r = 1.5 / pc.shaft_size;
	vec3 c = vec3(0.0);
	float total = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float w = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
			c += textureLod(shaft_tex, uv + vec2(x, y) * r, 0.0).rgb * w;
			total += w;
		}
	}
	return c / total;
}
#endif

#ifdef MODE_SHAFTS
const float WATER_IOR = 1.333;
const float PI = 3.14159265;

// Henyey-Greenstein phase function: g > 0 scatters light forward, so shafts glow brightest
// when looking towards the sun.
float phase_hg(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5));
}

// Marches the view ray through the water. Every sample looks straight up the refracted sun
// direction to the surface and asks the focus map how much light the waves focus onto it.
// The pattern is constant along that direction, which is what draws the streaks.
vec3 light_shafts(vec3 origin, vec3 dir, float max_dist, float jitter) {
	vec3 to_light = -refract(-p.sun_dir.xyz, vec3(0.0, 1.0, 0.0), 1.0 / WATER_IOR);
	if (to_light.y <= 0.01 || p.sun_dir.w <= 0.0) return vec3(0.0);
	int steps = max(int(p.shafts.y), 1);
	float dt = min(max_dist, p.sun_color.w) / float(steps);
	vec3 sum = vec3(0.0);
	for (int i = 0; i < steps; i++) {
		float t = (float(i) + jitter) * dt;
		vec3 pos = origin + dir * t;
		float depth = p.effect2.y - pos.y; // Approximate the surface as flat at water level.
		if (depth <= 0.0) continue;
		vec2 surface_xz = pos.xz + to_light.xz * (depth / to_light.y);
		float focus = textureLod(focus_tex, surface_xz * p.shafts.x, 0.0).r;
		// Only the focused part stands out; the average light is already in the fog colour.
		float bright = pow(max(focus - p.shafts2.x, 0.0), p.shafts.w);
		// Nothing gets focused where something above the water blocks the sun.
		bright *= sun_visibility(vec3(surface_xz.x, p.effect2.y, surface_xz.y));
		sum += bright * exp(-p.absorption.rgb * (t + depth / to_light.y));
	}
	vec3 light = sum * dt * phase_hg(dot(dir, to_light), p.shafts.z) * p.sun_color.rgb * p.shaft_tint.rgb * p.sun_dir.w;
	return min(light, vec3(p.shaft_tint.a));
}
#endif

#ifdef MODE_SHAFTS
void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(px, ivec2(pc.shaft_size)))) return;
	vec2 uv = (vec2(px) + 0.5) / pc.shaft_size;

	vec3 near_view = view_pos(uv, 1.0);
	vec3 near_world = (p.cam_to_world * vec4(near_view, 1.0)).xyz;
	vec3 shafts = vec3(0.0);
	if (p.shafts2.w > 0.0) { // Only while the lens itself is under.
		float depth = textureLod(depth_tex, uv, 0.0).r;
		float dist = depth <= 0.0 ? 1e4 : length(view_pos(uv, depth)); // depth 0 = far plane (sky).
		vec3 ray_dir = normalize(mat3(p.cam_to_world) * near_view);
		float jitter = fract(52.9829189 * fract(dot(vec2(px), vec2(0.06711056, 0.00583715))));
		shafts = light_shafts(p.cam_to_world[3].xyz, ray_dir, dist, jitter);
	}
	imageStore(shaft_image, px, vec4(shafts, 1.0));
}
#else
void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(px, ivec2(pc.size)))) return;
	vec2 uv = (vec2(px) + 0.5) / pc.size;

	// Where this pixel's ray starts (near plane, reverse-z => depth 1.0), in world space.
	vec3 near_view = view_pos(uv, 1.0);
	vec3 near_world = (p.cam_to_world * vec4(near_view, 1.0)).xyz;
	float submersion = wave_height(near_world.xz) - near_world.y; // > 0 means underwater.

	vec3 scene = textureLod(source_tex, uv, 0.0).rgb;
	// Waterline width is given in pixels; convert to meters on the (tiny) near plane.
	float pixel_meters = length(view_pos(uv + vec2(0.0, 1.0) / pc.size, 1.0) - near_view);
	float thickness = max(p.effect.w * pixel_meters, 1e-6);
	// Is the lens in the water at all? Everything the water does to the picture follows from
	// the path below, which falls to nothing by itself as we surface; this only fades the
	// things that come from the lens being wet rather than from the water in front of it.
	float lens = p.shafts2.w;
	float wet = smoothstep(0.0, 0.08, lens);
	// Froth reaches further than the line itself, and further still while you are going under.
	// Pixel scale like the line: across the whole screen the near plane spans only a couple
	// of centimeters of world height, so a band measured in meters would swallow the view.
	float churn = p.shafts2.y;
	float foam = p.effect2.w;
	float band = thickness * (1.5 + 4.0 * churn);
	float reach = max(3.0 * thickness, foam > 0.0 ? band * 2.0 : 0.0);
	if (wet <= 0.0 && submersion < -reach) return; // Lens dry and away from the waterline.

	vec3 result = scene;
	if (wet > 0.0) {
		float t = p.effect.x;
		vec2 wobble = vec2(sin(uv.y * 23.0 + t * 1.7) + sin(uv.y * 41.0 - t * 2.3) * 0.5,
		                   cos(uv.x * 19.0 + t * 1.3) + cos(uv.x * 37.0 + t * 2.9) * 0.5);
		vec2 suv = clamp(uv + wobble * p.effect.y, vec2(0.0), vec2(1.0));

		vec3 view_dir = normalize(mat3(p.cam_to_world) * view_pos(suv, 1.0));
		float depth = textureLod(depth_tex, suv, 0.0).r;
		float hit = depth <= 0.0 ? 1e4 : length(view_pos(suv, depth)); // depth 0 = sky.
		// A ray only carries water for as long as it is in the water. Looking up it leaves
		// through the surface overhead, so the sky stays the sky even with the lens under;
		// level or downward it never leaves, and we see the full murk. Applied to every
		// pixel alike, so there is no seam between what the surface covers and what it does not.
		float exit_dist = view_dir.y > 1e-4 ? lens / view_dir.y : 1e4;
		float dist = min(hit, max(exit_dist, 0.0));

		vec3 under = blurred(suv, p.effect.z);
		// Light fades with depth. The scattered light you see along a view comes from the water
		// it passes through (out to about the silhouette range), so looking up you see shallower,
		// brighter water - a faint glow overhead even when deep - and looking down, only black.
		float seen_depth = max(lens - view_dir.y * min(dist, p.effect2.z), 0.0);
		vec3 fog = p.fog_color.rgb * exp(-p.fog_color.a * seen_depth);
		fog *= mix(p.fog_gradient.x, p.fog_gradient.y, view_dir.y * 0.5 + 0.5);
		// Detail and colour are absorbed quickly (absorption), but the light scattered into the
		// view builds up over a much longer range (silhouette range). So a distant creature is
		// lost as a lit object yet still blocks the glow behind it: a dark shape in the murk.
		vec3 transmittance = exp(-p.absorption.rgb * dist);
		float scattered = 1.0 - exp(-dist / max(p.effect2.z, 1.0));
		under = under * transmittance + fog * scattered;

		under += shafts_filtered(suv);

		vec2 v = uv - 0.5;
		under *= 1.0 - p.effect2.x * dot(v, v) * 2.0;
		result = mix(scene, under, wet);
	}

	// Meniscus: the thin dark lip right at the interface, where the surface is edge-on.
	float line = 1.0 - smoothstep(0.0, thickness * 2.0, abs(submersion));
	result *= 1.0 - 0.5 * line;

	// Froth. A sea like this never gives you a clean waterline: it tears along the chop,
	// foams white, and drags a cloud of air down with you as you go under.
	if (foam > 0.0) {
		float t = p.effect.x;
		float ragged = (vnoise(vec2(uv.x * 26.0, t * 0.9)) - 0.5) * 2.0
		             + (vnoise(vec2(uv.x * 71.0, t * 1.7)) - 0.5);
		float froth = 1.0 - smoothstep(0.0, band, abs(submersion - ragged * band * 0.35));
		froth *= 0.1 + 0.9 * vnoise(vec2(uv.x * 150.0, uv.y * 150.0 - t * 3.0));
		// Foam is only ever as bright as the light falling on it, so it greys out at night.
		// The air dragged under is real geometry, not screen noise: see PlungeBubbles on
		// the player, which emits by how hard you hit the water.
		float lum = dot(result, vec3(0.299, 0.587, 0.114));
		vec3 lit = min(p.sun_color.rgb, vec3(1.0));
		result = mix(result, lit * clamp(lum * 1.6 + 0.25, 0.15, 1.0),
				clamp(froth * 0.7, 0.0, 0.8) * foam);
	}

	imageStore(color_image, px, vec4(result, 1.0));
}
#endif
