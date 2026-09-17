shader_type canvas_item;
// The halos of one ring of core arcs, on one quad. Glyph.halo_arc lays
// twelve ever wider, ever fainter strokes under an arc; stacked, strokes
// of one color composite to alpha 1 - prod(1 - a_i), which is computed
// here per pixel instead of being drawn: the same light, without issuing
// a hundred strokes a frame. The layer table is Glyph._build_halo's.

const int LAYERS = 12;
const float REACH = 38.0;
const float FLOOR = 0.15;
// The soft edge Godot gives an antialiased stroke, in design units:
// along its sides and at its butt ends. Fitted to the drawn strokes with
// tools/frame_check.tscn.
const float FEATHER = 0.7;
const float END_FEATHER = 1.25;

uniform float radius = 210.0;
uniform float stroke = 3.0;
uniform float gap = 0.1221730;
uniform int count = 4;
uniform float values[16];
uniform vec4 tints[16] : source_color;

varying vec2 at;


void vertex() {
	at = VERTEX;
}


void fragment() {
	float r = length(at);
	float d = abs(r - radius);
	float slice = TAU / float(count);
	float angle = mod(atan(at.y, at.x) + PI * 0.5, TAU);
	int i = min(int(angle / slice), count - 1);
	float v = clamp(values[i], 0.0, 1.0);
	float start = gap * 0.5;
	float end = start + max((slice - gap) * v, 0.012);
	float local = angle - float(i) * slice;
	// Butt ends: how far inside the arc's span, along the ring.
	float inside = min(local - start, end - local) * r;
	float ends = clamp(1.0 + inside / END_FEATHER, 0.0, 1.0);
	float heat = max(v, FLOOR);
	float through = 1.0;
	for (int k = 0; k < LAYERS; k++) {
		float t = float(k) / float(LAYERS - 1);
		float half_width = (stroke + 2.0 + REACH * pow(t, 1.5)) * 0.5;
		float alpha = 0.11 * (1.0 - t) * (1.0 - t) + 0.006;
		float cover = clamp(1.0 - (d - half_width) / FEATHER, 0.0, 1.0);
		through *= 1.0 - alpha * heat * cover * ends;
	}
	COLOR = vec4(tints[i].rgb, (1.0 - through) * COLOR.a);
}
