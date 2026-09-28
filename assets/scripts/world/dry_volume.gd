@tool
class_name DryVolume extends MeshInstance3D
## Keeps the sea out of a closed space, eg. the inside of a hull: no water surface is drawn inside
## this mesh, the camera is never "underwater" in it and the player can't swim in it. Put it on a
## closed mesh the exact shape of the space (hide it, it's never drawn). It follows the node's full
## transform, so it rolls and pitches with the boat. water.gd gathers them every frame (up to 4).
## On load the mesh is baked into a top-down map of where the space starts and ends at each spot,
## which is exact for anything without overhangs (a hull, a well shaft).

## Size of the baked map. Must be the same for every DryVolume (water.gd packs them together).
const RESOLUTION := 128
const EMPTY := 1e5 # Bottom above top: nothing dry here.

## Switch it off without removing it.
@export var enabled := true

## (bottom, top) height of the space per spot, in the mesh's local space. RGF, RESOLUTION².
var map : Image
## Area the map covers in local space: (x, z, size x, size z).
var bounds := Vector4.ZERO
## Goes up each bake, so water.gd knows to re-upload the map.
var bake_version := 0

func _ready() -> void:
	add_to_group(&'dry_volume')
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bake()

## Rebuilds the map from the mesh. Call again if the mesh changes.
func bake() -> void:
	map = Image.create_empty(RESOLUTION, RESOLUTION, false, Image.FORMAT_RGF)
	map.fill(Color(EMPTY, -EMPTY, 0.0))
	bake_version += 1
	if not mesh: return
	var aabb := mesh.get_aabb()
	# A texel of margin so the edges bake cleanly.
	var texel := Vector2(aabb.size.x, aabb.size.z) / float(RESOLUTION - 2)
	bounds = Vector4(aabb.position.x - texel.x, aabb.position.z - texel.y, texel.x * RESOLUTION, texel.y * RESOLUTION)
	var lo := PackedFloat32Array()
	var hi := PackedFloat32Array()
	lo.resize(RESOLUTION * RESOLUTION)
	hi.resize(RESOLUTION * RESOLUTION)
	lo.fill(EMPTY)
	hi.fill(-EMPTY)
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var index : PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var count := index.size() if not index.is_empty() else verts.size()
		for t in range(0, count - 2, 3):
			var a := verts[index[t] if not index.is_empty() else t]
			var b := verts[index[t + 1] if not index.is_empty() else t + 1]
			var c := verts[index[t + 2] if not index.is_empty() else t + 2]
			_rasterize(a, b, c, lo, hi)
	for i in lo.size():
		if lo[i] <= hi[i]:
			map.set_pixel(i % RESOLUTION, i / RESOLUTION, Color(lo[i], hi[i], 0.0))

## Widens the (bottom, top) span of every texel whose centre lies under the triangle, seen from
## above, to include the triangle's height there. Walls seen edge-on add nothing, which is fine:
## the floor and ceiling around them already cover every spot.
func _rasterize(a : Vector3, b : Vector3, c : Vector3, lo : PackedFloat32Array, hi : PackedFloat32Array) -> void:
	var pa := _to_map(a)
	var pb := _to_map(b)
	var pc := _to_map(c)
	var area := (pb - pa).cross(pc - pa)
	if absf(area) < 1e-9: return
	var x0 := maxi(floori(minf(pa.x, minf(pb.x, pc.x))), 0)
	var x1 := mini(ceili(maxf(pa.x, maxf(pb.x, pc.x))), RESOLUTION - 1)
	var y0 := maxi(floori(minf(pa.y, minf(pb.y, pc.y))), 0)
	var y1 := mini(ceili(maxf(pa.y, maxf(pb.y, pc.y))), RESOLUTION - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var p := Vector2(x + 0.5, y + 0.5)
			var w0 := (pc - pb).cross(p - pb) / area
			var w1 := (pa - pc).cross(p - pc) / area
			var w2 := 1.0 - w0 - w1
			if w0 < -1e-4 or w1 < -1e-4 or w2 < -1e-4: continue
			var h := a.y * w0 + b.y * w1 + c.y * w2
			var i := y * RESOLUTION + x
			lo[i] = minf(lo[i], h)
			hi[i] = maxf(hi[i], h)

func _to_map(v : Vector3) -> Vector2:
	return Vector2((v.x - bounds.x) / bounds.z, (v.z - bounds.y) / bounds.w) * RESOLUTION

## Is this world position inside the dry space?
func contains(world_pos : Vector3) -> bool:
	if not enabled or not map or bounds.z <= 0.0: return false
	var p := global_transform.affine_inverse() * world_pos
	var uv := Vector2((p.x - bounds.x) / bounds.z, (p.z - bounds.y) / bounds.w)
	if uv.x < 0.0 or uv.y < 0.0 or uv.x >= 1.0 or uv.y >= 1.0: return false
	var span := map.get_pixel(int(uv.x * RESOLUTION), int(uv.y * RESOLUTION))
	return p.y > span.r and p.y < span.g

## World-to-local transform rows for the shaders (each: basis row, origin term).
func pack_rows() -> Array[Vector4]:
	var inv := global_transform.affine_inverse()
	var rows : Array[Vector4] = []
	for r in 3:
		rows.append(Vector4(inv.basis.x[r], inv.basis.y[r], inv.basis.z[r], inv.origin[r]))
	return rows
