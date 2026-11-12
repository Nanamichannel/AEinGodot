shader_type canvas_item;
//
// mask_tex.gdshader —— 用一张遮罩纹理裁剪图层（GPU 版，适合复杂/动态蒙版）
// 蒙版由 SubViewport + Polygon2D 每帧画好，这里只采样一次。
//

uniform sampler2D mask_tex : filter_linear, repeat_disable;
uniform bool invert = false;

void fragment() {
	vec4 m = texture(mask_tex, SCREEN_UV);
	float a = m.a;
	if (invert) a = 1.0 - a;
	if (a < 0.004) {
		discard;
	}
	vec4 c = texture(TEXTURE, UV) * COLOR;
	c.a *= a;
	COLOR = c;
}
