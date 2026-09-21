#[compute]
#version 450
// Copies the scene color buffer into a sampleable texture (the color buffer itself can't
// be used as a copy source).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst_image;

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(px, imageSize(src_image)))) return;
	imageStore(dst_image, px, imageLoad(src_image, px));
}
