#[versions]

shafts = "#define MODE_SHAFTS";
composite = "";

#[compute]

#version 450

#VERSION_DEFINES
// Underwater screen effect (runs after transparents, see underwater_effect.gd).
// Per pixel: is the camera's near plane below the FFT wave surface here? If so, apply
// distance absorption/in-scattering, light shafts, wobble, blur and vignette. A meniscus
// line marks the waterline where a wave crosses the lens.
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
	vec4 effect2;         // x vignette, y water level (world y), zw unused
	vec4 sun_dir;         // xyz direction towards the sun (world), w = shaft strength
	vec4 sun_color;       // rgb light colour * energy, w = max shaft march distance (m)
	vec4 shafts;          // x focus map uv scale, y march steps, z forward scattering g, w contrast
	vec4 shaft_tint;      // rgb tint, a = max brightness
	vec4 shafts2;         // x threshold, yzw unused
} p;

#ifdef MODE_SHAFTS
layout(set = 0, binding = 5) uniform sampler2D focus_tex; // Light focus map, see caustics.glsl.
#endif

layout(push_constant, std430) uniform PushConstant {
	vec2 size;       // Full resolution.
	vec2 shaft_size; // Half resolution light shaft buffer.
} pc;

vec3 view_pos(vec2 uv, float depth) {
	vec4 v = p.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return v.xyz / v.w;
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
	vec2 rest = xz;
	vec3 d = vec3(0.0);
	for (int i = 0; i < 3; i++) {
		d = displacement(rest);
		rest = xz - d.xz;
	}
	return p.effect2.y + d.y;
}

#ifndef MODE_SHAFTS
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
	if (wave_height(near_world.xz) > near_world.y) { // Only underwater pixels need shafts.
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
	float coverage = smoothstep(-thickness, thickness, submersion);
	if (coverage <= 0.0 && submersion < -3.0 * thickness) return; // Dry and away from the waterline.

	vec3 result = scene;
	if (coverage > 0.0) {
		float t = p.effect.x;
		vec2 wobble = vec2(sin(uv.y * 23.0 + t * 1.7) + sin(uv.y * 41.0 - t * 2.3) * 0.5,
		                   cos(uv.x * 19.0 + t * 1.3) + cos(uv.x * 37.0 + t * 2.9) * 0.5);
		vec2 suv = clamp(uv + wobble * p.effect.y, vec2(0.0), vec2(1.0));

		float depth = textureLod(depth_tex, suv, 0.0).r;
		float dist = depth <= 0.0 ? 1e4 : length(view_pos(suv, depth)); // depth 0 = far plane (sky).

		vec3 under = blurred(suv, p.effect.z);
		// Light fades with depth, so the water column gets darker the deeper the camera sinks.
		vec3 fog = p.fog_color.rgb * exp(-p.fog_color.a * max(submersion, 0.0));
		vec3 transmittance = exp(-p.absorption.rgb * dist);
		under = under * transmittance + fog * (1.0 - transmittance);

		under += shafts_filtered(suv);

		vec2 v = uv - 0.5;
		under *= 1.0 - p.effect2.x * dot(v, v) * 2.0;
		result = mix(scene, under, coverage);
	}

	// Meniscus: a thin dark band where the surface cuts across the lens.
	float line = 1.0 - smoothstep(0.0, thickness * 2.0, abs(submersion));
	result *= 1.0 - 0.65 * line;

	imageStore(color_image, px, vec4(result, 1.0));
}
#endif
