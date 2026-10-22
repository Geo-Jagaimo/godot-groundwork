# Groundwork for Godot

Godot エディタ内の地図で範囲を選ぶだけで、**実世界の地形・コリジョン・航空写真を、
Godot 標準ノードだけで構成された歩けるシーン**として生成するアドオンです。
GDScript のみで実装しており、GDExtension・GDAL・他のアドオンは不要です。

![Groundwork for Godot で取り込んだ富士山頂](docs/preview.png)

<sub>富士山頂 3 km × 3 km。出典：国土地理院「地理院タイル（標高タイル DEM10B、全国最新写真（シームレス））」を加工して作成</sub>

> Groundwork for Godot は非公式のコミュニティプロジェクトであり、Godot Foundation とは無関係です。

## クイックスタート

1. `addons/groundwork/` をプロジェクトにコピーし、*プロジェクト → プロジェクト設定 → プラグイン*
   で **Groundwork for Godot** を有効にします。右側に **Geo** ドックが表示されます。
2. 地名（または `緯度, 経度`）で検索し、地図上で **Shift+ドラッグ** して範囲を選択します。
   標高プロバイダ（その範囲で使えれば航空写真も）を選びます。
3. **Import** を押し、**Open Scene**（または **Add to Current Scene**）で開きます。

**Godot 4.4 以降**が必要です。

## 生成物

```
res://geo/<name>/
├── <name>.tscn            GwSceneRoot (Node3D) → Terrain → Chunk_XXX_YYY (MeshInstance3D)
│                                                   └── StaticBody3D → CollisionShape3D (HeightMapShape3D)
├── georef.tres            GwGeoReference: 原点・スケール・帰属表示
├── heightfield.res        GwHeightfield: 標高グリッド全体
├── import_request.tres    同じ範囲・設定で再取り込みするための全パラメータ
├── ATTRIBUTION.md         帰属表示
└── terrain/               chunk_XXX_YYY.mesh / .png / _collision.res
```

- チャンク（既定 128 セル）は境界頂点を共有するため継ぎ目が出ません。
- メッシュとコリジョンは同じ高さ配列から作るので一致します。
- PNG テクスチャはエディタのインポートパイプラインに乗ります（VRAM 圧縮・mipmap）。
- シーンには帰属表示ラベル（`CanvasLayer`）が入ります。消す場合は別の場所（クレジット等）に表示してください。

## 座標系

範囲中心を原点とした Web メルカトルを近似メートルに換算した座標です。
**+X = 東、+Y = 上（標高 m）、−Z = 北**。北緯 35° で ±5 km なら誤差は約 0.05 % で、
ゲーム用途では無視できます。20 km 超・緯度 60° 超ではドックが警告を出します。

```gdscript
var world := $Shibuya as GwSceneRoot
var pos := world.geo_to_local(35.6595, 139.7005)     # y は地形の標高
var lat_lon := world.local_to_geo($Player.position)  # PackedFloat64Array [緯度, 経度]
var h := world.sample_elevation(Vector2(pos.x, pos.z))
```

## プロバイダ

| プロバイダ | 種別 | 範囲 | 最高解像度 | 備考 |
|---|---|---|---|---|
| Terrain Tiles（AWS, Terrarium） | 標高 | 全球 | z15（北緯35°で約3.9 m） | SRTM・3DEP・EU-DEM 等の合成 |
| 地理院 DEM5A | 標高 | 日本（一部） | z15（5 m） | 欠損は周囲から補間 |
| 地理院 DEM10B | 標高 | 日本 | z14（10 m） | |
| 地理院 全国最新写真（シームレス） | 航空写真 | 日本 | z18 | |
| OpenStreetMap・地理院 淡色地図 | 背景地図 | — | — | ドック表示専用。生成物には使いません |

全球の航空写真プリセットは、ゲームへの組み込み可否を規約で確認できたものだけを同梱する方針のため、
まだ含めていません。独自のプロバイダは `GwTileProvider` リソース（URL テンプレート
`https://…/{z}/{x}/{y}.png`、ズーム範囲、帰属表示）を `res://groundwork_providers/` に置けば
ドックに表示されます。API キーは URL に `{key}` と書き、*エディタ設定 → groundwork/api_keys/<プロバイダ id>*
に設定します（プロジェクトのファイルには書き込まれません）。

## 帰属表示の義務

どのプロバイダも、データを表示する場所での出典表示を求めています。取り込みごとに
`ATTRIBUTION.md` と `GwGeoReference.attribution` に正確な文言を書き出し、画面上のラベルも追加します。
ラベルを外す場合はゲームのクレジット等に表示してください。商用利用の前に各規約（`ATTRIBUTION.md` にリンクあり）を確認してください。

## スクリプトから使う

ドックはコア API の薄い UI です。同じ処理を自作のツールスクリプトからも呼べます。

```gdscript
var req := GwImportRequest.new()
req.bbox = GwGeoBBox.from_sw_ne(35.65, 139.69, 35.68, 139.72)
req.import_name = "shibuya"
req.output_dir = "res://geo/"
req.elevation_provider = GwProviderRegistry.find("terrarium_aws")
req.imagery_provider = GwProviderRegistry.find("gsi_seamlessphoto")
req.target_resolution_m = 10.0

var builder := GwWorldBuilder.new()
builder.progress.connect(func(stage, done, total): print(stage, " ", done, "/", total))
var result: GwImportResult = await builder.build(req)
if result.ok:
	print(result.scene_path, result.warnings)
else:
	push_error(result.error_message)
```

`GwWorldBuilder.build_nodes(req)` はファイルを書かずにメモリ上のシーンを返します。

## 設定

| 置き場所 | キー | |
|---|---|---|
| エディタ設定 | `groundwork/network/concurrency` | 同時ダウンロード数（既定 6） |
| エディタ設定 | `groundwork/geocoder/enabled` | Nominatim による地名検索 |
| エディタ設定 | `groundwork/api_keys/<id>` | プロバイダごとの API キー |
| プロジェクト設定 | `groundwork/defaults/*` | 既定のプロバイダ・解像度・出力先 |
| プロジェクト設定 | `groundwork/log_level` | コンソールのログレベル。直近の取り込みの全ログは `user://groundwork_last_import.log` |

取得したタイルは `user://groundwork_cache/`（プロジェクト単位）にキャッシュされ、ドックからサイズ確認・消去ができます。

## ロードマップ

- **v0.2**: OpenStreetMap の建物（押し出し）と道路、コリジョン
- **v0.3 以降**: 距離 LOD、水域・土地利用、GeoTIFF / GeoJSON 読み込み、エクスポートアダプタ（Terrain3D・glTF）、実行時ロード

## 開発

リポジトリのルートが Godot プロジェクトです（`demo/` に一人称コントローラあり。`demo` という名前で取り込んでから実行してください）。

```bash
./tools/install_gdunit4.sh
godot --headless --path . --import
godot --headless --path . -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode -a res://addons/groundwork/tests/unit
```

ユニットテストはオフライン（合成タイル）で動きます。ネットワークがあれば、ドック経由で実際に取り込むエディタ統合テストも実行できます。

```bash
godot --headless --editor --path . -- --groundwork-selftest
```

Lint / format は [gdtoolkit](https://github.com/Scony/godot-gdscript-toolkit) 4.x を使います：
`gdlint addons/groundwork demo tools`、`gdformat --check addons/groundwork demo tools`。

## ライセンス

コード: [LICENSE](LICENSE) を参照。生成物に含まれる地理データは各プロバイダのライセンスに従います（取り込みごとの `ATTRIBUTION.md` を参照）。
