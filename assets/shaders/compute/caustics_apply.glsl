#[compute]
#version 450
// Projects caustics onto everything opaque below the water surface (see caustics_effect.gd).
// Runs before the transparent pass, so the water surface refracts the lit result from above
// and the underwater effect sees it from below.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 3) uniform sampler2DArray displacements;
layout(set = 0, binding = 4, std140) uniform Params {
	mat4 inv_projection;
	mat4 cam_to_world;
	vec4 map_scales[4];   // xy uv scale, z displacement scale
	vec4 sun_dir;         // xyz direction towards the sun (world), w = caustic strength
	vec4 sun_color;       // rgb light colour * energy, w = focus depth (m)
	vec4 absorption;      // rgb extinction per meter, a = number of cascades
	vec4 misc;            // x water level, y caustic cascade, z dispersion, w unused
	vec4 tint;            // rgb tint, a = max brightness
	vec4 shape;           // x contrast, y darkening, z pattern scale, w fade depth (m)
	vec4 shape_count;     // x = number of water shapes
	vec4 shape_a[16];
	vec4 shape_b[16];
	vec4 shadow_origin;   // Sun shadow map, see water_shadow.glsli.
	vec4 shadow_right;
	vec4 shadow_up;
	vec4 shadow_fwd;
} p;

#include "water_shapes.glsli"
layout(set = 0, binding = 6) uniform sampler2D shadow_tex; // Sun shadow map, see water_shadow.glsli.
#include "water_shadow.glsli"
layout(set = 0, binding = 5) uniform sampler2D focus_tex; // Focus map, see caustics.glsl.

layout(push_constant, std430) uniform PushConstant {
	vec2 size;
	vec2 pad;
} pc;

const float WATER_IOR = 1.333;

vec3 world_pos(ivec2 px) {
	px = clamp(px, ivec2(0), ivec2(pc.size) - 1);
	float depth = texelFetch(depth_tex, px, 0).r;
	vec2 uv = (vec2(px) + 0.5) / pc.size;
	vec4 v = p.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return (p.cam_to_world * vec4(v.xyz / v.w, 1.0)).xyz;
}

// Same wave lookup as underwater_post.glsl: invert the choppy horizontal displacement.
float wave_height(vec2 xz) {
	int n = int(p.absorption.a);
	vec2 shape = water_shapes(xz);
	vec2 rest = xz;
	vec3 d = vec3(0.0);
	for (int iter = 0; iter < 3; iter++) {
		d = vec3(0.0);
		for (int i = 0; i < n; i++) {
			vec4 s = p.map_scales[i];
			d += textureLod(displacements, vec3(rest * s.xy, float(i)), 0.0).xyz * s.z;
		}
		d *= 1.0 - shape.y;
		rest = xz - d.xz;
	}
	return p.misc.x + d.y + shape.x;
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(px, ivec2(pc.size)))) return;
	if (texelFetch(depth_tex, px, 0).r <= 0.0) return; // Sky.

	vec3 pos = world_pos(px);
	float depth = wave_height(pos.xz) - pos.y;
	if (depth <= 0.0) return; // Above the water.

	vec3 to_light = -refract(-p.sun_dir.xyz, vec3(0.0, 1.0, 0.0), 1.0 / WATER_IOR);
	if (to_light.y <= 0.01) return;

	// Surface normal from neighbouring depths, facing the camera.
	vec3 n = normalize(cross(world_pos(px + ivec2(0, 1)) - pos, world_pos(px + ivec2(1, 0)) - pos));
	if (dot(n, p.cam_to_world[3].xyz - pos) < 0.0) n = -n;
	float n_dot_l = max(dot(n, to_light), 0.0);
	if (n_dot_l <= 0.0) return;

	// Follow the refracted sunbeam back up to the surface and read how focused it is there.
	// Each colour bends slightly differently, which splits the caustic edges into a rainbow.
	float path = depth / to_light.y;
	vec2 surface_xz = pos.xz + to_light.xz * path;
	vec2 uv_scale = p.map_scales[int(p.misc.y)].xy * p.shape.z;
	vec2 uv = surface_xz * uv_scale;
	vec2 spread = to_light.xz * path * p.misc.z * uv_scale;
	vec3 focus = vec3(textureLod(focus_tex, uv - spread, 0.0).r,
	                  textureLod(focus_tex, uv, 0.0).r,
	                  textureLod(focus_tex, uv + spread, 0.0).r);

	// Sharpest around the focus depth; blurs away (loses contrast) deeper down.
	float focus_depth = max(p.sun_color.w, 0.1);
	float sharpness = smoothstep(0.0, 0.5 * focus_depth, depth) * exp(-max(depth - focus_depth, 0.0) / max(p.shape.w, 0.1));

	// Focused light (> 1) forms the lines; the gaps (< 1) optionally darken.
	vec3 variation = focus - 1.0;
	vec3 pattern = pow(max(variation, 0.0), vec3(p.shape.x)) + min(variation, 0.0) * p.shape.y;
	vec3 light = p.sun_color.rgb * p.tint.rgb * p.sun_dir.w * n_dot_l * exp(-p.absorption.rgb * path) * sharpness * pattern;
	light = min(light, vec3(p.tint.a));
	light *= sun_visibility(vec3(surface_xz.x, p.misc.x, surface_xz.y));

	vec4 color = imageLoad(color_image, px);
	imageStore(color_image, px, vec4(max(color.rgb * (1.0 + light), vec3(0.0)), color.a));
}
