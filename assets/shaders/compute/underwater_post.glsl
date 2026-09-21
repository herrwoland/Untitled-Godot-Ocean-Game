#[compute]
#version 450
// Underwater screen effect (runs after transparents, see underwater_effect.gd).
// Per pixel: is the camera's near plane below the FFT wave surface here? If so, apply
// distance absorption/in-scattering, wobble, blur and vignette. A meniscus line marks the
// waterline where a wave crosses the lens.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler2D source_tex; // Copy of the color buffer.
layout(set = 0, binding = 3) uniform sampler2DArray displacements;
layout(set = 0, binding = 4, std140) uniform Params {
	mat4 inv_projection;
	mat4 cam_to_world;
	vec4 map_scales[4];   // xy uv scale, z displacement scale
	vec4 fog_color;       // rgb in-scattered colour, a = light loss per meter of depth
	vec4 absorption;      // rgb extinction per meter, a = number of cascades
	vec4 effect;          // x time, y distortion, z blur (px), w waterline width (px)
	vec4 effect2;         // x vignette, y water level (world y), zw unused
} p;

layout(push_constant, std430) uniform PushConstant {
	vec2 size;
	vec2 pad;
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

vec3 blurred(vec2 uv, float radius_px) {
	vec2 r = radius_px / pc.size;
	vec3 c = textureLod(source_tex, uv, 0.0).rgb * 0.4;
	c += textureLod(source_tex, uv + vec2( r.x,  r.y), 0.0).rgb * 0.15;
	c += textureLod(source_tex, uv + vec2(-r.x,  r.y), 0.0).rgb * 0.15;
	c += textureLod(source_tex, uv + vec2( r.x, -r.y), 0.0).rgb * 0.15;
	c += textureLod(source_tex, uv + vec2(-r.x, -r.y), 0.0).rgb * 0.15;
	return c;
}

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

		vec2 v = uv - 0.5;
		under *= 1.0 - p.effect2.x * dot(v, v) * 2.0;
		result = mix(scene, under, coverage);
	}

	// Meniscus: a thin dark band where the surface cuts across the lens.
	float line = 1.0 - smoothstep(0.0, thickness * 2.0, abs(submersion));
	result *= 1.0 - 0.65 * line;

	imageStore(color_image, px, vec4(result, 1.0));
}
