# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
