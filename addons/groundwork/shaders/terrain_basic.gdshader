// Example terrain shader (not used by default): imagery with slope-based rock
// tinting. To try it, replace a chunk's surface material with a ShaderMaterial
// using this shader and copy the albedo texture, UV scale and offset from the
// generated StandardMaterial3D.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform vec4 rock_color : source_color = vec4(0.46, 0.43, 0.40, 1.0);
// Steepness as 1 - normal.y: 0.15 is about 32 degrees, 0.35 about 49 degrees.
uniform float slope_start : hint_range(0.0, 1.0) = 0.15;
uniform float slope_end : hint_range(0.0, 1.0) = 0.35;
uniform float rock_amount : hint_range(0.0, 1.0) = 0.6;

varying float steepness;

void vertex() {
	// Chunk meshes are in the scene root's space, so the model-space normal is
	// the world normal as long as the scene root is not rotated.
	steepness = 1.0 - NORMAL.y;
}

void fragment() {
	vec3 albedo = texture(albedo_texture, UV * uv_scale + uv_offset).rgb;
	float t = smoothstep(slope_start, slope_end, steepness) * rock_amount;
	ALBEDO = mix(albedo, rock_color.rgb, t);
	ROUGHNESS = 1.0;
}
