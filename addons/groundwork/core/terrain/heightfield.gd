@tool
class_name GwHeightfield
extends Resource
## A regular grid of elevations covering the imported area.
##
## Sample (c, r) sits at local position
## [code](origin.x + c * cell_size, height, origin.y + r * cell_size)[/code];
## rows run north to south (+Z). NAN marks NoData until [method fill_nodata].

@export var width := 0
@export var height := 0
@export var cell_size := 1.0
## Local XZ of sample (0, 0).
@export var origin := Vector2.ZERO
@export var data := PackedFloat32Array()
@export var min_height := 0.0
@export var max_height := 0.0


static func create(
	p_width: int, p_height: int, p_cell_size: float, p_origin: Vector2
) -> GwHeightfield:
	var hf := GwHeightfield.new()
	hf.width = p_width
	hf.height = p_height
	hf.cell_size = p_cell_size
	hf.origin = p_origin
	hf.data.resize(p_width * p_height)
	return hf


func get_height(c: int, r: int) -> float:
	return data[clampi(r, 0, height - 1) * width + clampi(c, 0, width - 1)]


func set_height(c: int, r: int, value: float) -> void:
	data[r * width + c] = value


## Local XZ position of sample (c, r).
func sample_position(c: int, r: int) -> Vector2:
	return origin + Vector2(c, r) * cell_size


## Size in local units from the first to the last sample.
func get_extent() -> Vector2:
	return Vector2(width - 1, height - 1) * cell_size


## Elevation at a local XZ position, interpolated on the same triangles as the
## terrain mesh. Positions outside the grid are clamped to its edge.
func sample(local_xz: Vector2) -> float:
	if width < 2 or height < 2:
		return data[0] if not data.is_empty() else NAN
	var fx := clampf((local_xz.x - origin.x) / cell_size, 0.0, width - 1.0)
	var fz := clampf((local_xz.y - origin.y) / cell_size, 0.0, height - 1.0)
	var c := mini(floori(fx), width - 2)
	var r := mini(floori(fz), height - 2)
	var u := fx - c
	var v := fz - r
	var i := r * width + c
	var h00 := data[i]
	var h10 := data[i + 1]
	var h01 := data[i + width]
	var h11 := data[i + width + 1]
	# Matches the mesh split along the (c+1, r)-(c, r+1) diagonal.
	if u + v <= 1.0:
		return h00 + (h10 - h00) * u + (h01 - h00) * v
	return h11 + (h01 - h11) * (1.0 - u) + (h10 - h11) * (1.0 - v)


## Surface normal at sample (c, r) by central differences (one-sided at edges).
func normal_at(c: int, r: int) -> Vector3:
	var cl := maxi(c - 1, 0)
	var cr := mini(c + 1, width - 1)
	var ru := maxi(r - 1, 0)
	var rd := mini(r + 1, height - 1)
	var dx := (get_height(cr, r) - get_height(cl, r)) / (maxi(cr - cl, 1) * cell_size)
	var dz := (get_height(c, rd) - get_height(c, ru)) / (maxi(rd - ru, 1) * cell_size)
	return Vector3(-dx, 1.0, -dz).normalized()


func count_nodata() -> int:
	var n := 0
	for h in data:
		if is_nan(h):
			n += 1
	return n


func compute_min_max() -> void:
	var lo := INF
	var hi := -INF
	for h in data:
		if not is_nan(h):
			lo = minf(lo, h)
			hi = maxf(hi, h)
	min_height = lo if lo != INF else 0.0
	max_height = hi if hi != -INF else 0.0


## Fills NoData by repeatedly averaging valid 4-neighbours, up to
## [param max_iterations] passes; anything left is set to the minimum valid
## height. Returns the number of samples that needed the fallback, or -1 if the
## grid has no valid data at all.
func fill_nodata(max_iterations: int = 32) -> int:
	var pending := PackedInt32Array()
	for i in data.size():
		if is_nan(data[i]):
			pending.append(i)
	if pending.is_empty():
		return 0
	if pending.size() == data.size():
		return -1
	for _iter in max_iterations:
		if pending.is_empty():
			break
		var next := PackedInt32Array()
		var filled_idx := PackedInt32Array()
		var filled_val := PackedFloat32Array()
		for i in pending:
			var c := i % width
			var sum := 0.0
			var n := 0
			if c > 0 and not is_nan(data[i - 1]):
				sum += data[i - 1]
				n += 1
			if c < width - 1 and not is_nan(data[i + 1]):
				sum += data[i + 1]
				n += 1
			if i >= width and not is_nan(data[i - width]):
				sum += data[i - width]
				n += 1
			if i + width < data.size() and not is_nan(data[i + width]):
				sum += data[i + width]
				n += 1
			if n > 0:
				filled_idx.append(i)
				filled_val.append(sum / n)
			else:
				next.append(i)
		for k in filled_idx.size():
			data[filled_idx[k]] = filled_val[k]
		pending = next
	if pending.is_empty():
		return 0
	compute_min_max()
	for i in pending:
		data[i] = min_height
	return pending.size()


## Every [param step]-th sample in both directions. Origin is unchanged.
func decimated(step: int) -> GwHeightfield:
	if step <= 1:
		return self
	@warning_ignore("integer_division")
	var w := (width - 1) / step + 1
	@warning_ignore("integer_division")
	var h := (height - 1) / step + 1
	var out := GwHeightfield.create(w, h, cell_size * step, origin)
	for r in h:
		var src_row := r * step * width
		for c in w:
			out.data[r * w + c] = data[src_row + c * step]
	out.min_height = min_height
	out.max_height = max_height
	return out
