shader_type particles;
// Marine snow: specks that hang in the water around the camera (see water.gd). They drift and
// slowly sink in world space; any that leave the box around the camera wrap to its other side,
// so the density stays constant however fast the camera moves.

uniform vec3 center;                     // Camera position, set every frame.
uniform vec3 box_size = vec3(24.0, 16.0, 24.0);
uniform float drift_speed = 0.12;        // m/s of lazy swirling.
uniform float sink_speed = 0.04;         // m/s downwards.
uniform float size = 0.07;              // Speck size (m).

float hash(uint n) {
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 789221u) + 1376312589u;
	return float(n & 0x7fffffffu) / float(0x7fffffff);
}

void start() {
	uint seed = NUMBER * 7u + RANDOM_SEED;
	if (RESTART_POSITION) {
		vec3 r = vec3(hash(seed), hash(seed + 1u), hash(seed + 2u));
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = center + (r - 0.5) * box_size;
	}
	CUSTOM.x = hash(seed + 3u); // Size / brightness variation.
	CUSTOM.y = hash(seed + 4u); // Drift phase.
}

void process() {
	vec3 p = TRANSFORM[3].xyz;
	float t = TIME * 0.35 + CUSTOM.y * 6.2832;
	vec3 swirl = vec3(sin(t + p.y * 0.4), 0.3 * sin(t * 1.3 + p.x * 0.3), cos(t * 0.8 + p.z * 0.4));
	p += (swirl * drift_speed + vec3(0.0, -sink_speed, 0.0)) * DELTA;
	p = center + mod(p - center + box_size * 0.5, box_size) - box_size * 0.5;
	float s = size * mix(0.5, 1.6, CUSTOM.x * CUSTOM.x);
	TRANSFORM = mat4(vec4(s, 0.0, 0.0, 0.0), vec4(0.0, s, 0.0, 0.0), vec4(0.0, 0.0, s, 0.0), vec4(p, 1.0));
	COLOR = vec4(vec3(mix(0.5, 1.0, CUSTOM.x)), 1.0);
}
