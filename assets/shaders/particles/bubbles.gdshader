shader_type particles;
// Bubbles rising to the surface (see bubble_emitter.gd): they start where the emitter is, get
// pushed along with it, wobble on the way up (bigger ones rise faster and wobble more), swell as
// the pressure drops and vanish when they reach the surface.

uniform float spawn_radius = 0.15;
uniform vec3 inherit_velocity;           // Emitter velocity, set every frame.
uniform float inherit_amount = 0.4;
uniform float rise_speed = 1.1;          // m/s for a mid-sized bubble.
uniform float wobble = 0.35;
uniform float size_min = 0.015;
uniform float size_max = 0.07;
uniform float surface_y = 0.0;           // Water surface above the emitter, set every frame.

float hash(uint n) {
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 789221u) + 1376312589u;
	return float(n & 0x7fffffffu) / float(0x7fffffff);
}

void start() {
	uint seed = NUMBER * 11u + RANDOM_SEED;
	vec3 r = vec3(hash(seed), hash(seed + 1u), hash(seed + 2u)) * 2.0 - 1.0;
	if (RESTART_POSITION) {
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = EMISSION_TRANSFORM[3].xyz + r * spawn_radius;
	}
	if (RESTART_VELOCITY) {
		VELOCITY = inherit_velocity * inherit_amount + r * 0.4;
	}
	CUSTOM.x = pow(hash(seed + 3u), 2.5); // Mostly small bubbles, a few big ones.
	CUSTOM.y = hash(seed + 4u) * 6.2832;
	CUSTOM.z = TRANSFORM[3].y; // Start depth, for the swelling.
}

void process() {
	float big = CUSTOM.x;
	float speed = rise_speed * mix(0.6, 1.6, big);
	float t = TIME * mix(5.0, 2.5, big) + CUSTOM.y;
	vec3 target = vec3(sin(t), 0.0, cos(t * 1.3)) * wobble * mix(0.5, 1.5, big) + vec3(0.0, speed, 0.0);
	VELOCITY = mix(VELOCITY, target, 1.0 - exp(-3.0 * DELTA));
	vec3 p = TRANSFORM[3].xyz;
	if (p.y > surface_y) ACTIVE = false;
	float swell = 1.0 + clamp((p.y - CUSTOM.z) * 0.02, 0.0, 0.5);
	float s = mix(size_min, size_max, big) * swell;
	TRANSFORM[0].xyz = vec3(s, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, s, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, s);
}
