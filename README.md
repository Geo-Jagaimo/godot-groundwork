# Godot-Groundwork

Pick an area on a map inside the Godot editor and get a **walkable scene of the real
world** — terrain mesh with distance LOD, collision, aerial imagery and OpenStreetMap
buildings, roads and water — built only from standard Godot nodes. Export it to glTF, or
load places while your game runs. Pure GDScript: no GDExtension, no GDAL, no other addons.

![Mt. Fuji summit imported with Godot-Groundwork](docs/preview.png)

<sub>Mt. Fuji summit, 3 km × 3 km. 出典：国土地理院「地理院タイル（標高タイル DEM10B、全国最新写真（シームレス））」を加工して作成</sub>

![Shibuya with OpenStreetMap buildings and roads](docs/preview_osm.png)

<sub>Shibuya station area. Buildings and roads © OpenStreetMap contributors (ODbL). 出典：国土地理院「地理院タイル（標高タイル DEM5A、全国最新写真（シームレス））」を加工して作成</sub>

## Quick start

1. Copy `addons/groundwork/` into your project and enable **Godot-Groundwork** in
   *Project → Project Settings → Plugins*. A **Geo** dock appears on the right.
2. Search for a place (or type `lat, lon`), then **Shift+drag** on the map to select an
   area. Choose an elevation provider (and imagery, if available for the area), and tick
   **Buildings** / **Roads** / **Water** for OpenStreetMap data.
3. Press **Import**, then **Open Scene** — or **Add to Current Scene** and drop a
   character on it.

Requires **Godot 4.4 or later**.

## What you get

```
res://geo/<name>/
├── <name>.tscn            GwSceneRoot (Node3D)
│                            ├── Terrain → Chunk_XXX_YYY (MeshInstance3D)
│                            │             ├── Lod1, Lod2 (coarser MeshInstance3D, by distance)
│                            │             └── StaticBody3D → CollisionShape3D (HeightMapShape3D)
│                            ├── Buildings → Chunk_XXX_YYY (MeshInstance3D) → … (ConcavePolygonShape3D)
│                            ├── Water (MeshInstance3D)
│                            └── Roads → Residential, Primary, … (MeshInstance3D per road class)
├── georef.tres            GwGeoReference: origin, scale, attribution
├── heightfield.res        GwHeightfield: the full elevation grid
├── import_request.tres    every setting, to re-import the same area
├── ATTRIBUTION.md         who to credit
├── terrain/               chunk_XXX_YYY.mesh / _lod1.mesh / .png / _collision.res
├── buildings/             chunk_XXX_YYY.mesh / _collision.res, building_material.tres
├── roads/                 <class>.mesh, <class>_material.tres
└── water/                 water.mesh, water_material.tres
```

- Chunks (128 cells by default) share their border vertices, so there are no seams.
- **Distance LOD**: each chunk also gets coarser meshes (half and quarter detail by
  default) shown by `visibility_range`; skirts along chunk borders hide the cracks
  between levels. Collision always uses full detail.
- Mesh and collision come from the same heights and match exactly.
- PNG textures go through the editor's import pipeline (VRAM compressed, mipmaps).
- A small attribution label (`CanvasLayer`) is added to the scene; keep it, or credit
  the data elsewhere (see below).

## Coordinates

Web Mercator around the centre of the area, scaled to approximate metres:
**+X = east, +Y = up (metres), −Z = north**. Scale error is about 0.05 % at ±5 km
(35°N), so it is fine for games; the dock warns above 20 km or 60° latitude.

```gdscript
var world := $Shibuya as GwSceneRoot
var pos := world.geo_to_local(35.6595, 139.7005)   # y = terrain height
var lat_lon := world.local_to_geo($Player.position)  # PackedFloat64Array [lat, lon]
var h := world.sample_elevation(Vector2(pos.x, pos.z))
```

## OpenStreetMap buildings, roads and water

Buildings, roads and water come from one [Overpass API](https://wiki.openstreetmap.org/wiki/Overpass_API)
query per import (areas up to 25 km²), cached for 7 days in `user://groundwork_cache/overpass/`.

- **Buildings** are extruded with flat roofs. Height comes from `height`, else
  `building:levels` × 3 m, else 6 m (both adjustable). Walls start 0.5 m below the lowest
  ground point so they never float on slopes. Courtyards (inner rings of multipolygons)
  are cut out, with walls facing into them. Buildings are merged per terrain chunk and
  get `ConcavePolygonShape3D` collision.
- **Roads** are ribbons draped over the terrain, with widths per `highway=*` type
  (`GwImportRequest.road_widths` overrides them) and one mesh and material per class.
  They have no collision of their own; you walk on the terrain beneath.
- **Water**: lakes, ponds, reservoirs and river areas (with islands cut out) are draped
  just above the terrain, which already sits at the water level in most elevation data;
  rivers, streams and canals are drawn as ribbons. No collision.
- Materials are saved as `building_material.tres`, `<class>_material.tres` and
  `water_material.tres`; edit them freely — a re-import keeps your edited materials.
- Current limits: flat roofs only; tunnels and underground ways are skipped; bridges
  follow the terrain; crossings simply overlap.

The public Overpass servers are run by volunteers and are often busy. The dock tries
overpass-api.de and then a mirror, and a failed download only skips buildings and roads.
For heavy or commercial use, point a `GwTileProvider` (kind *Vector*) at your own or a
paid Overpass server and save it in `res://groundwork_providers/`.

## Providers

| Provider | Kind | Coverage | Best resolution | Notes |
|---|---|---|---|---|
| Terrain Tiles (AWS, Terrarium) | elevation | global | z15 (~3.9 m at 35°N) | Mixed sources (SRTM, 3DEP, EU-DEM, …) |
| Mapterhorn | elevation | global | z16, 512 px (~1 m at 35°N) | Open data; resolution depends on the region ([sources](https://mapterhorn.com/attribution)) |
| GSI DEM1A | elevation | Japan, partial | z17 (1 m) | Lidar areas only |
| GSI DEM5A | elevation | Japan, partial | z15 (5 m) | |
| GSI DEM10B | elevation | Japan | z14 (10 m) | |
| GSI seamless aerial photo | imagery | Japan | z18 | |
| OpenStreetMap, GSI pale map | basemap | — | — | Dock background only, never baked into imports |
| Overpass API (overpass-api.de, private.coffee mirror) | buildings, roads, water | global | — | OpenStreetMap data, ODbL |

Where a provider has no tile at the chosen zoom (outside its high-resolution areas, or
partial coverage), the tile is cut from the closest lower zoom level instead; anything
still missing is interpolated. Providers with 512 px tiles (`GwTileProvider.tile_size`)
are used at full resolution.

A global imagery preset is not included yet: we only ship sources whose terms clearly
allow embedding in games. You can add your own provider by saving a `GwTileProvider`
resource (URL template `https://…/{z}/{x}/{y}.png`, zoom range, attribution) in
`res://groundwork_providers/`. For keys, use `{key}` in the URL and set
*Editor Settings → groundwork/api_keys/<provider id>* — keys never go into project files.

## Attribution is required

Every provider requires credit wherever its data is shown. Each import writes the exact
text to `ATTRIBUTION.md` and `GwGeoReference.attribution`, and adds an on-screen label.
If you remove the label, put the attribution in your game's credits. Check each
provider's terms (linked in `ATTRIBUTION.md`) before commercial use.

Buildings and roads are a *Produced Work* of OpenStreetMap data: credit
"© OpenStreetMap contributors" and say the data is available under the
[ODbL](https://www.openstreetmap.org/copyright), for example on a splash screen or in the
credits.

## Scripting

The dock is a thin UI over the core API, which also works from your own tool scripts:

```gdscript
var req := GwImportRequest.new()
req.bbox = GwGeoBBox.from_sw_ne(35.65, 139.69, 35.68, 139.72)
req.import_name = "shibuya"
req.output_dir = "res://geo/"
req.elevation_provider = GwProviderRegistry.find("terrarium_aws")
req.imagery_provider = GwProviderRegistry.find("gsi_seamlessphoto")
req.target_resolution_m = 10.0
req.include_buildings = true
req.include_roads = true

var builder := GwWorldBuilder.new()
builder.progress.connect(func(stage, done, total): print(stage, " ", done, "/", total))
var result: GwImportResult = await builder.build(req)
if result.ok:
	print(result.scene_path, result.warnings)
else:
	push_error(result.error_message)
```

`GwWorldBuilder.build_nodes(req)` returns the scene in memory without writing files.

### Export to glTF

The dock's **Export glTF…** button (after an import), or from code:

```gdscript
var scene := (load("res://geo/shibuya/shibuya.tscn") as PackedScene).instantiate()
GwGltfExporter.export_scene(scene, "user://shibuya.glb")
scene.free()
```

Terrain (full detail), buildings, roads and water are exported with embedded textures;
collision, coarser LOD levels and the attribution label are left out. Keep crediting the
data providers wherever the exported file is used.

### Loading places at runtime

`GwTerrainLoader` builds a scene while the game runs, without writing files (tiles are
cached in `user://`). See `demo/runtime.tscn`.

```gdscript
var loader := GwTerrainLoader.new()
loader.request = GwTerrainLoader.request_around(35.3606, 138.7274, 2000.0, "mapterhorn")
add_child(loader)
var result: GwImportResult = await loader.build()
if result.ok:
	var h := loader.scene_root.sample_elevation(Vector2.ZERO)
```

Show the data attribution (`loader.scene_root.get_attribution()`) in your game.

## Settings

| Where | Key | |
|---|---|---|
| Editor Settings | `groundwork/network/concurrency` | parallel downloads (default 6) |
| Editor Settings | `groundwork/geocoder/enabled` | place search via Nominatim |
| Editor Settings | `groundwork/api_keys/<id>` | per-provider API keys |
| Project Settings | `groundwork/defaults/*` | default providers, resolution, output folder |
| Project Settings | `groundwork/log_level` | console log level; the full log of the last import is in `user://groundwork_last_import.log` |

Downloaded tiles are cached in `user://groundwork_cache/` (per project); the dock shows
its size and can clear it.

## Roadmap

- **Next**: pitched roofs, land use, GeoTIFF / GeoJSON import, more export adapters
  (Terrain3D, HTerrain), coordinates in other projections (UTM, Japan plane rectangular).

## Development

The repository root is a Godot project. `demo/main.tscn` walks around an area imported
as `demo`; `demo/runtime.tscn` downloads a place while the game runs.

```bash
./tools/install_gdunit4.sh
godot --headless --path . --import
godot --headless --path . -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode -a res://addons/groundwork/tests/unit
```

Unit tests are offline (synthetic tiles). With network access you can also run the editor
integration test, which drives the dock through a real import:

```bash
godot --headless --editor --path . -- --groundwork-selftest
```

Lint and format with [gdtoolkit](https://github.com/Scony/godot-gdscript-toolkit) 4.x:
`gdlint addons/groundwork demo tools` and `gdformat --check addons/groundwork demo tools`.

## License

Code: see [LICENSE](LICENSE). Geographic data in generated output is licensed by its
providers (see each import's `ATTRIBUTION.md`).
