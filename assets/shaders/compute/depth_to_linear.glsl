#[compute]
#version 450
// Converts the sun shadow camera's depth buffer into linear distance (m) along its view
// direction, for water_shadow.glsli.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict writeonly image2D linear_depth;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;

layout(push_constant, std430) uniform PushConstant {
	mat4 inv_projection;
} pc;

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(linear_depth);
	if (any(greaterThanEqual(px, size))) return;
	vec2 uv = (vec2(px) + 0.5) / vec2(size);
	float depth = textureLod(depth_tex, uv, 0.0).r;
	vec4 v = pc.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	imageStore(linear_depth, px, vec4(-v.z / v.w, 0.0, 0.0, 0.0));
}
