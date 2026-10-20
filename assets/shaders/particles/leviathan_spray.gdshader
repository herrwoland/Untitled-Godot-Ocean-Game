shader_type particles;
// Water thrown by the leviathan (see leviathan_splash.gd). Every particle is placed by
// emit_particle() with its own size and life, so one emitter holds a 5 m splash and a 120 m
// sheet alike; auto-emitted ones are switched off at once.
//   CUSTOM.x = rotation (radians, read by billboarded puffs), CUSTOM.y = size (m),
//   CUSTOM.z = life (s), CUSTOM.w = age (s).

/** 0 sheet: a curtain standing on the water that rises like the water in it (up to `size` at
 *  sqrt(2 size / g)) and falls back the same way; 1 puff: a lump of water flying free; 2 drop:
 *  a streak along its flight; 3 mist: hangs, spreads and drifts. */
uniform int kind = 1;
uniform float gravity = 9.8;
/** Air holding it back, per second. Big lumps of water barely feel it, fine spray does. */
uniform float drag = 0.3;
uniform vec3 wind = vec3(0.0);
/** How much it spreads over its life (puffs and mist: x size at the end). */
uniform float grow = 2.0;

void start() {
	if (RESTART_POSITION) {
		ACTIVE = false; // only particles placed by the script exist
	}
	CUSTOM.w = 0.0;
}

void process() {
	CUSTOM.w += DELTA;
	float life = max(CUSTOM.z, 0.05);
	float t = CUSTOM.w / life;
	if (t >= 1.0) {
		ACTIVE = false;
	}
	float size = CUSTOM.y;
	float alpha;
	if (kind == 0) {
		// The sheet's top flies like the water in it: up to `size` and back down, h = size (2p - p^2)
		// over p = 0..2. The script makes its life 2 rise times plus a short linger of foam.
		float rise = sqrt(2.0 * size / max(gravity, 0.1));
		float p = min(CUSTOM.w / rise, 2.0);
		float h = size * max(2.0 * p - p * p, 0.06);
		float w = size * 0.84 * (0.75 + 0.35 * p); // spreads as it falls (texture is 296 x 354)
		VELOCITY = vec3(0.0);
		TRANSFORM[0] = vec4(w, 0.0, 0.0, 0.0);
		TRANSFORM[1] = vec4(0.0, h, 0.0, 0.0);
		TRANSFORM[2] = vec4(0.0, 0.0, w, 0.0);
		alpha = smoothstep(0.0, 0.06, t) * (1.0 - smoothstep(0.6, 1.0, t));
	} else {
		VELOCITY += (vec3(0.0, -gravity, 0.0) + wind) * DELTA;
		VELOCITY *= exp(-drag * DELTA);
		float s = size * mix(1.0, grow, t);
		if (kind == 2) {
			// A streak: its Y along the way it flies (the quad turns round that axis to face us).
			vec3 along = length(VELOCITY) > 0.01 ? normalize(VELOCITY) : vec3(0.0, 1.0, 0.0);
			vec3 side = normalize(abs(along.y) < 0.99 ? cross(along, vec3(0.0, 1.0, 0.0)) : vec3(1.0, 0.0, 0.0));
			TRANSFORM[0] = vec4(side * s, 0.0);
			TRANSFORM[1] = vec4(along * s, 0.0);
			TRANSFORM[2] = vec4(cross(side, along) * s, 0.0);
		} else {
			TRANSFORM[0] = vec4(s, 0.0, 0.0, 0.0);
			TRANSFORM[1] = vec4(0.0, s, 0.0, 0.0);
			TRANSFORM[2] = vec4(0.0, 0.0, s, 0.0);
		}
		if (kind == 3) {
			alpha = smoothstep(0.0, 0.2, t) * (1.0 - smoothstep(0.4, 1.0, t)) * 0.35;
		} else {
			alpha = smoothstep(0.0, 0.04, t) * (1.0 - smoothstep(0.45, 1.0, t));
		}
	}
	COLOR.a = alpha;
}
