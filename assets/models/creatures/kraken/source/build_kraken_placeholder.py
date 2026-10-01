# Builds the PLACEHOLDER kraken (mesh + rig) and exports it for Godot.
# Run headless:  blender.exe --background --factory-startup --python build_kraken_placeholder.py
#
# Rig convention kraken.gd expects (keep it when making the real model):
#   body                  root bone at the arm crown, the whole creature hangs off it
#   mantle                child of body, the sac behind the eyes (breathes)
#   arm_<a>_<k>           a = 0..7 around the crown, k = 0.. from root to tip,
#                         each bone's +Y running down the arm toward the tip.
#                         Any number of bones per arm; all arms the same count.
#                         Bones shorten toward the tip (long stiff base, short
#                         curling tip): kraken_arm.gd bends short bones more.
# Blender +Y (mantle tip) becomes Godot -Z, so the creature swims toward -Z.
import bpy, bmesh, math, os, random
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
GLB = os.path.normpath(os.path.join(HERE, "..", "kraken_placeholder.glb"))
BLEND = os.path.join(HERE, "kraken_placeholder.blend")

ARMS = 8
BONES_PER_ARM = 20
TIP_BONE_RATIO = 0.2 # tip bone length / root bone length (geometric taper: ~5.2 m down to ~1 m)
ARM_LENGTH = 52.0 # m, crown to tip; plus ~14 m of head/mantle = ~66 m overall
ARM_ROOT_RADIUS = 1.35
ARM_TIP_RADIUS = 0.12
CROWN_RADIUS = 2.3 # ring the arms grow from (sunk into the head)
WEB_LENGTH = 9.0 # m of webbing between neighbouring arms
SIDES = 8 # PS1-cheap tubes
ARM_RINGS = 96 # rings along each arm, evenly spaced (~0.54 m)

random.seed(7)
bpy.ops.wm.read_factory_settings(use_empty=True)

def material(name, rgb, rough=0.8):
	m = bpy.data.materials.new(name)
	m.use_nodes = True
	bsdf = m.node_tree.nodes["Principled BSDF"]
	bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
	bsdf.inputs["Roughness"].default_value = rough
	m.diffuse_color = (*rgb, 1.0) # viewport / workbench colour
	return m

skin = material("kraken_skin", (0.42, 0.12, 0.05))
sucker = material("kraken_sucker", (0.78, 0.62, 0.55))
eye = material("kraken_eye", (0.85, 0.65, 0.2), 0.3)
pupil = material("kraken_pupil", (0.02, 0.015, 0.01), 0.3)

mesh = bpy.data.meshes.new("kraken")
obj = bpy.data.objects.new("kraken", mesh)
bpy.context.collection.objects.link(obj)
for m in (skin, sucker, eye, pupil):
	mesh.materials.append(m)
bm = bmesh.new()
deform = bm.verts.layers.deform.verify()
groups = {} # bone name -> vertex group index

def group(name):
	if name not in groups:
		groups[name] = len(groups)
		obj.vertex_groups.new(name=name)
	return groups[name]

def weigh(v, weights):
	for name, w in weights:
		if w > 0.0:
			v[deform][group(name)] = w

# ---- head + mantle: a lathe along +Y, slightly flattened, bumpy -------------
profile = [ # (y, radius)
	(-0.6, 3.2), (0.4, 3.8), (1.6, 3.7), (2.6, 3.5), (3.6, 3.2), (4.4, 3.4),
	(5.6, 4.3), (7.0, 4.9), (8.6, 5.1), (10.2, 4.8), (11.6, 4.0), (12.8, 2.9),
	(13.7, 1.6), (14.2, 0.0),
]
LATHE = 16
rings = []
for y, r in profile:
	ring = []
	for i in range(LATHE):
		a = math.tau * i / LATHE
		jitter = 1.0 + random.uniform(-0.05, 0.05) if 0.0 < r else 1.0
		# a little flatter top-to-bottom, and the mantle sags down as it goes back
		sag = -0.35 * max(0.0, y - 5.0)
		p = Vector((math.cos(a) * r * jitter, y, math.sin(a) * r * 0.85 * jitter + sag))
		v = bm.verts.new(p)
		m = min(max((y - 3.5) / 2.5, 0.0), 1.0)
		weigh(v, [("body", 1.0 - m), ("mantle", m)])
		ring.append(v)
	rings.append(ring)
for j in range(len(rings) - 1):
	for i in range(LATHE):
		a, b = rings[j][i], rings[j][(i + 1) % LATHE]
		c, d = rings[j + 1][(i + 1) % LATHE], rings[j + 1][i]
		if c == d or c.co == d.co:
			f = bm.faces.new((a, b, c))
		else:
			f = bm.faces.new((a, b, c, d))
		f.material_index = 0
cap = bm.faces.new(list(reversed(rings[0])))
cap.material_index = 1 # the mouth side is pale

# ---- eyes: low-poly bulbs on the head sides, with a slit pupil ---------------
for side in (-1, 1):
	center = Vector((side * 3.25, 2.4, 1.55))
	res = bmesh.ops.create_uvsphere(bm, u_segments=8, v_segments=6, radius=0.95)
	for v in res["verts"]:
		v.co = v.co + center
		weigh(v, [("body", 1.0)])
	for f in {f for v in res["verts"] for f in v.link_faces}:
		n = (f.calc_center_median() - center).normalized()
		outward = n.x * side > 0.55 and abs(n.z) < 0.35
		f.material_index = 3 if outward else 2

# ---- arms ---------------------------------------------------------------------
ratio = TIP_BONE_RATIO ** (1.0 / (BONES_PER_ARM - 1))
first = ARM_LENGTH * (1.0 - ratio) / (1.0 - ratio ** BONES_PER_ARM)
bone_lengths = [first * ratio ** k for k in range(BONES_PER_ARM)]
bone_starts = [sum(bone_lengths[:k]) for k in range(BONES_PER_ARM)]
bone_centers = [bone_starts[k] + bone_lengths[k] * 0.5 for k in range(BONES_PER_ARM)]

def arm_weights(a, s):
	"""Blend between the two bones whose centers s lies between."""
	if s <= bone_centers[0]:
		return [("arm_%d_0" % a, 1.0)]
	if s >= bone_centers[-1]:
		return [("arm_%d_%d" % (a, BONES_PER_ARM - 1), 1.0)]
	k = max(i for i in range(BONES_PER_ARM) if bone_centers[i] <= s)
	w1 = (s - bone_centers[k]) / (bone_centers[k + 1] - bone_centers[k])
	return [("arm_%d_%d" % (a, k), 1.0 - w1), ("arm_%d_%d" % (a, k + 1), w1)]

roots = []
for a in range(ARMS):
	ang = math.tau * (a + 0.5) / ARMS
	# ring around the crown in the XZ plane; arms run toward -Y
	out = Vector((math.cos(ang), 0.0, math.sin(ang) * 0.85))
	roots.append((out, Vector((0.0, 0.6, 0.0)) + out * CROWN_RADIUS))
all_rings = [] # per arm: its vertex rings
all_names = [] # per arm: the bone weights of each ring
n_rings = ARM_RINGS + 1
for a, (out, root) in enumerate(roots):
	arm_rings = []
	arm_names = []
	for j in range(n_rings):
		s = ARM_LENGTH * j / (n_rings - 1)
		t = s / ARM_LENGTH
		r = ARM_ROOT_RADIUS + (ARM_TIP_RADIUS - ARM_ROOT_RADIUS) * (t ** 0.8)
		axis = root + Vector((0.0, -s, 0.0))
		names = arm_weights(a, s)
		if s < 1.5: # root blends into the body so the crown does not tear
			b = 1.0 - s / 1.5
			names = [(n, w * (1.0 - b)) for n, w in names] + [("body", b)]
		ring = []
		side = Vector((0.0, -1.0, 0.0)).cross(out).normalized()
		for i in range(SIDES):
			ph = math.tau * i / SIDES
			d = out * math.cos(ph) + side * math.sin(ph)
			v = bm.verts.new(axis + d * r)
			weigh(v, names)
			ring.append(v)
		arm_rings.append(ring)
		arm_names.append(names)
	all_rings.append(arm_rings)
	all_names.append(arm_names)
	for j in range(n_rings - 1):
		for i in range(SIDES):
			f = bm.faces.new((arm_rings[j][i], arm_rings[j][(i + 1) % SIDES],
				arm_rings[j + 1][(i + 1) % SIDES], arm_rings[j + 1][i]))
			# the side facing the arm crown's center carries the suckers: a pale
			# dotted strip (every other ring), the rest is skin
			inward = i in (SIDES // 2 - 1, SIDES // 2)
			f.material_index = 1 if inward and j % 2 == 0 else 0
	bm.faces.new(list(reversed(arm_rings[-1])))

# ---- web: a skin membrane between neighbouring arms, near the crown ----------
# Its middle row is weighted half to each arm, so it stretches when they spread.
web_rows = int(round(WEB_LENGTH / ARM_LENGTH * (n_rings - 1)))
for a in range(ARMS):
	b = (a + 1) % ARMS
	ra, rb = all_rings[a], all_rings[b]
	# the vertex of each arm that faces the other one
	ia = min(range(SIDES), key=lambda i: (ra[0][i].co - roots[b][1]).length)
	ib = min(range(SIDES), key=lambda i: (rb[0][i].co - roots[a][1]).length)
	mids = []
	for j in range(web_rows + 1):
		va, vb = ra[j][ia], rb[j][ib]
		depth = 1.0 - j / web_rows # the free edge curves in: shallower toward its end
		m = bm.verts.new(va.co.lerp(vb.co, 0.5) + Vector((0.0, 0.8 * depth, 0.0)))
		weigh(m, [(n, w * 0.5) for n, w in all_names[a][j]] + [(n, w * 0.5) for n, w in all_names[b][j]])
		mids.append(m)
	for j in range(web_rows):
		bm.faces.new((ra[j][ia], ra[j + 1][ia], mids[j + 1], mids[j])).material_index = 0
		bm.faces.new((mids[j], mids[j + 1], rb[j + 1][ib], rb[j][ib])).material_index = 0

bm.normal_update()
bm.to_mesh(mesh)
bm.free()
for p in mesh.polygons:
	p.use_smooth = True

# ---- armature -----------------------------------------------------------------
arm_data = bpy.data.armatures.new("kraken_rig")
rig = bpy.data.objects.new("kraken_rig", arm_data)
bpy.context.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode='EDIT')
body = arm_data.edit_bones.new("body")
body.head, body.tail = Vector((0, 0, 0)), Vector((0, 3.5, 0))
mantle = arm_data.edit_bones.new("mantle")
mantle.head, mantle.tail = Vector((0, 3.5, 0)), Vector((0, 13.5, 0))
mantle.parent = body
for a, (out, root) in enumerate(roots):
	parent = body
	for k in range(BONES_PER_ARM):
		b = arm_data.edit_bones.new("arm_%d_%d" % (a, k))
		b.head = root + Vector((0, -bone_starts[k], 0))
		b.tail = root + Vector((0, -(bone_starts[k] + bone_lengths[k]), 0))
		b.parent = parent
		b.use_connect = k > 0
		parent = b
bpy.ops.object.mode_set(mode='OBJECT')

obj.parent = rig
mod = obj.modifiers.new("rig", 'ARMATURE')
mod.object = rig

bpy.ops.wm.save_as_mainfile(filepath=BLEND)
bpy.ops.export_scene.gltf(filepath=GLB, export_format='GLB', export_animations=False,
	export_skins=True, export_yup=True, export_apply=False)
print("KRAKEN_DONE", GLB, len(mesh.vertices), "verts")
