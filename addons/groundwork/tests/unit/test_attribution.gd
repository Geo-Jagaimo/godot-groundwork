extends GdUnitTestSuite


func test_attribution() -> void:
	var a := GwAttribution.new()
	var p := GwTileProvider.new()
	p.id = "attribution test"
	p.display_name = "Test"
	p.attribution = "© Test"
	p.attribution_short = "short"
	a.add_provider(p)
	a.add_provider(p)
	a.add_provider(null)
	assert_str(a.to_short_text()).is_equal("short")
	assert_str(a.to_text()).contains("© Test")
	assert_str(a.to_markdown("x", null)).contains("## Test")
