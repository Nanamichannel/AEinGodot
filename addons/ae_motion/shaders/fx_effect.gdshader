shader_type canvas_item;
render_mode blend_mix;

// fx_effect.gdshader —— 一个材质覆盖 AE 里最常见的三类"运算"：
//   外发光（glow）、湍流置换（displace）、调色（tint）
// 全部用 0~1 的浮点开关，方便在检查器里拖。
//
// 注意：发光是采样自身 alpha 做环形扩散，贴图周围要留透明边，否则会被裁掉。
// 注意：TEXTURE 只能在 fragment() 里直接用，不能传进自定义函数。

uniform float glow_amount : hint_range(0.0, 4.0) = 0.0;
uniform vec4 glow_color : source_color = vec4(1.0, 0.85, 0.4, 1.0);
uniform float glow_radius : hint_range(0.0, 0.05) = 0.012;

uniform float displace_amount : hint_range(0.0, 0.2) = 0.0;
uniform sampler2D noise_tex : repeat_enable, filter_linear, hint_default_transparent;
uniform float displace_speed : hint_range(0.0, 2.0) = 0.2;
uniform vec2 displace_scale = vec2(3.0, 3.0);

uniform float tint_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec4 tint_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float saturation : hint_range(0.0, 2.0) = 1.0;

void fragment() {
	vec2 uv = UV;

	// 1) 湍流置换：噪声的两个通道当 XY 偏移
	if (displace_amount > 0.0001) {
		vec2 ns = uv * displace_scale + vec2(TIME * displace_speed, 0.0);
		vec2 flow = texture(noise_tex, ns).rg - vec2(0.5);
		uv += flow * displace_amount;
	}

	vec4 src = texture(TEXTURE, uv);

	// 2) 调色
	if (tint_amount > 0.0001) {
		vec3 rgb = mix(src.rgb, tint_color.rgb, tint_amount);
		float lum = dot(rgb, vec3(0.299, 0.587, 0.114));
		rgb = mix(vec3(lum), rgb, saturation);
		src.rgb = rgb;
	}

	// 3) 外发光：采样周围一圈 alpha，取最大值当光晕
	if (glow_amount > 0.0001) {
		float a = 0.0;
		a = max(a, texture(TEXTURE, uv + vec2(glow_radius, 0.0)).a);
		a = max(a, texture(TEXTURE, uv + vec2(-glow_radius, 0.0)).a);
		a = max(a, texture(TEXTURE, uv + vec2(0.0, glow_radius)).a);
		a = max(a, texture(TEXTURE, uv + vec2(0.0, -glow_radius)).a);
		a = max(a, texture(TEXTURE, uv + vec2(glow_radius, glow_radius) * 0.7).a);
		a = max(a, texture(TEXTURE, uv + vec2(-glow_radius, glow_radius) * 0.7).a);
		a = max(a, texture(TEXTURE, uv + vec2(glow_radius, -glow_radius) * 0.7).a);
		a = max(a, texture(TEXTURE, uv + vec2(-glow_radius, -glow_radius) * 0.7).a);

		float halo = clamp(a * glow_amount - src.a * 0.5, 0.0, 1.0);
		src.rgb += glow_color.rgb * halo;
		src.a = max(src.a, halo * glow_color.a);
	}

	COLOR = src * COLOR;
}
