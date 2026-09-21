shader_type particles;
// Rain drops falling around the camera (see rain.gd). Each drop ends on the real FFT wave surface
// (or on solid geometry via the heightfield collider) and may throw a splash there.

global uniform sampler2DArray displacements;
global uniform uint num_cascades;

uniform vec3 center;                     // Camera position, set every frame.
uniform float radius = 40.0;             // Drops fall in a disc this wide around the camera (m).
uniform float column_height = 30.0;      // ...from this far above the camera/water.
uniform float water_level = 0.0;
uniform vec4 map_scales[4];              // Wave cascades, copied from the water node.
uniform vec2 wind = vec2(0.0);           // Horizontal wind velocity (m/s).
uniform float fall_speed = 12.0;         // m/s.
uniform float streak_length = 0.9;       // m, at fall_speed.
uniform float streak_width = 0.012;      // m.
uniform float splash_radius = 22.0;      // Only drops this close to the camera splash.
uniform float splash_chance = 0.5;

float hash(uint n) {
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 789221u) + 1376312589u;
	return float(n & 0x7fffffffu) / float(0x7fffffff);
}

float wave_height(vec2 xz) {
	float h = 0.0;
	for (uint i = 0u; i < min(num_cascades, 4u); i++) {
		vec4 s = map_scales[i];
		h += textureLod(displacements, vec3(xz * s.xy, float(i)), 0.0).y * s.z;
	}
	return water_level + h;
}

void start() {
	uint seed = NUMBER * 13u + RANDOM_SEED;
	if (RESTART_POSITION) {
		float angle = hash(seed) * 6.2832;
		float dist = sqrt(hash(seed + 1u)) * radius;
		float bottom = min(center.y, water_level) - 1.0;
		float top = max(center.y, water_level) + column_height;
		vec3 p = vec3(center.x + cos(angle) * dist, mix(bottom, top, hash(seed + 2u)), center.z + sin(angle) * dist);
		// Start upwind, so the column the camera sees is full despite the slant.
		p.xz -= wind * ((p.y - water_level) / fall_speed) * 0.5;
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = p;
	}
	if (RESTART_VELOCITY) {
		float speed = fall_speed * mix(0.85, 1.15, hash(seed + 3u));
		VELOCITY = vec3(wind.x, -speed, wind.y) * mix(0.9, 1.1, hash(seed + 4u));
	}
	CUSTOM.x = hash(seed + 5u); // Splash roll.
}

void process() {
	vec3 p = TRANSFORM[3].xyz;
	bool hit_water = p.y < wave_height(p.xz);
	if (hit_water || COLLIDED) {
		if (CUSTOM.x < splash_chance && distance(p.xz, center.xz) < splash_radius) {
			mat4 splash = mat4(1.0);
			splash[3].xyz = hit_water ? vec3(p.x, wave_height(p.xz), p.z) : p;
			emit_subparticle(splash, vec3(0.0), vec4(1.0), vec4(hit_water ? 1.0 : 0.0), FLAG_EMIT_POSITION);
		}
		ACTIVE = false;
	}
	// Streak along the fall direction: basis Y = direction * length, X/Z = width.
	vec3 dir = normalize(VELOCITY);
	vec3 side = normalize(cross(dir, abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 other = cross(side, dir);
	float len = streak_length * length(VELOCITY) / fall_speed;
	// Drops brushing past the lens would fill the screen with one giant streak: hide them.
	float near = smoothstep(1.2, 2.5, distance(p, center));
	len *= near;
	TRANSFORM[0].xyz = side * streak_width * near;
	TRANSFORM[1].xyz = dir * len;
	TRANSFORM[2].xyz = other * streak_width * near;
}
