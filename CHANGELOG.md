# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-10-22

First public release, with everything listed below: real-world terrain with distance
LOD, collision and aerial imagery, OpenStreetMap buildings, roads and water, glTF export
and runtime loading. Versions 0.1.0 to 0.3.0 were development milestones and were not
released on their own.

### Added

- Imports download at most 5,000 tiles (with a warning above 2,000), to spare the
  shared tile servers.
- `GwWorldBuilder.user_agent` and `GwTerrainLoader.user_agent`. By default the loader
  names the game (project name and version) in the User-Agent of its downloads.

## [0.3.0] - unreleased

Distance LOD, courtyards, water, glTF export and runtime loading.

### Added

- **Distance LOD**: coarser meshes per terrain chunk (half and quarter detail by default)
  switched by `visibility_range`, with skirts that hide cracks between levels.
  Configurable with `lod_levels` / `lod_distance` and in the dock.
- **Courtyards**: inner rings of multipolygon buildings are cut out of the roof, with
  walls facing into them (bridge edges + ear clipping, `GwPolygonUtil`).
- **Water** from OpenStreetMap: lakes, ponds, reservoirs and river areas (islands cut
  out) draped over the terrain, and rivers / streams / canals as ribbons.
- **glTF export** (`GwGltfExporter`, and an "Export glTF…" button in the dock): terrain,
  buildings, roads and water with embedded textures.
- **Runtime loading**: `GwTerrainLoader` builds a scene while the game runs, without
  writing files; `demo/runtime.tscn` shows it.
- **Providers**: Mapterhorn (global open elevation data, 512 px Terrarium WebP tiles) and
  GSI DEM1A (1 m, Japan, lidar areas).
- Elevation providers with 512 px tiles are used at full resolution
  (`GwTileProvider.tile_size`).
- Missing elevation tiles are cut from the closest lower zoom level (up to four levels)
  before falling back to interpolation.

## [0.2.0] - unreleased

OpenStreetMap buildings and roads.

### Added

- **Buildings**: OSM footprints (ways and multipolygon outer rings) extruded with flat
  roofs; height from `height`, `building:levels` × level height, or a default. Merged per
  terrain chunk with `ConcavePolygonShape3D` collision.
- **Roads**: `highway=*` centrelines resampled every 5 m and draped over the terrain as
  ribbons, with a width table per type and one mesh and material per road class.
- **Overpass client**: one query per import, 7-day disk cache, fallback from
  overpass-api.de to the private.coffee mirror, 30 s back-off after rate limiting.
  Download failures only skip buildings and roads.
- Geo dock: Buildings / Roads options, Overpass server and default building height;
  25 km² area limit for OSM data.
- Materials for buildings and road classes saved as `.tres` and kept on re-import.
- OpenStreetMap / ODbL attribution in `ATTRIBUTION.md` and the scene label.

### Fixed

- Tile ranges lost a row or column when an edge lay just inside a tile boundary.
- Decimated meshes stopped short of the east / south edge.
- NoData far from valid data is filled with the lowest height inside the area, not
  of the surrounding margin tiles.
- `georef.tres` and the dock's saved selection keep coordinates at full precision.
- Elevation tiles that are not 256 px (e.g. 512 px) are resampled instead of
  becoming NoData.
- Without any imagery the terrain falls back to elevation colours instead of grey.
- Re-imports keep the user's texture import settings and only remove files the
  new import no longer uses.
- Non-image responses (e.g. captive portals) are no longer cached as tiles; a 429
  pauses all requests and honours `Retry-After`; DNS failures are not retried.
- Overlapping place searches respect Nominatim's one request per second.
- The dock keeps the import result visible, keeps imports running when it is
  moved, refuses to add a scene to itself, and fixes selection edits on tiny or
  chorded drags. Failed basemap tiles are retried and visible tiles stay cached.
- Cancel is disabled while files are written; a builder can be reused after a
  cancel; in-memory builds fill in the attribution; texture import and
  `ATTRIBUTION.md` failures are reported.

## [0.1.0] - unreleased

First version: real-world terrain from tile services, generated in the editor.

### Added

- **Geo dock** with a slippy map (OpenStreetMap / GSI pale basemaps), place search
  (Nominatim, or `lat,lon` / `z/x/y`), Shift+drag area selection with resize handles,
  live estimate (tiles, triangles, download size) and validation warnings.
- **Terrain generation**: elevation tiles → heightfield → chunked `ArrayMesh` with
  shared border vertices and global normals, plus `HeightMapShape3D` collision per chunk.
- **Aerial imagery** composited into one texture per chunk; without imagery, an
  elevation colour gradient.
- **Output under `res://`**: `.tscn` built from standard nodes, binary meshes and
  collision shapes, `GwHeightfield`, `GwGeoReference`, `import_request.tres` and
  `ATTRIBUTION.md`. Textures go through the editor import pipeline (VRAM compressed,
  mipmaps); outside the editor they are saved as `PortableCompressedTexture2D`.
- **Georeferencing**: `GwGeoReference.to_local` / `to_geo` and
  `GwSceneRoot.geo_to_local` / `local_to_geo` / `sample_elevation`.
- **Providers**: AWS Terrain Tiles (Terrarium, global), GSI DEM5A / DEM10B and GSI
  seamless aerial photo (Japan). Custom providers in `res://groundwork_providers/`.
- Attribution label in generated scenes and an `ATTRIBUTION.md` per import.
- Script API: `GwWorldBuilder.build()` and `build_nodes()` (in-memory, no files).
- Disk tile cache in `user://groundwork_cache/` with per-provider TTL.
- Demo project with a first-person controller.
- gdUnit4 test suite (offline, synthetic tiles) and CI.

[Unreleased]: https://github.com/Geo-Jagaimo/godot-groundwork/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Geo-Jagaimo/godot-groundwork/releases/tag/v1.0.0
