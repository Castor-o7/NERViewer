extends Node
## "Palette" autoload: every color, tempo and glow level lives here and nowhere else.
##
## Two palettes over the same geometry. NERV is the reference set as shot;
## Yggdrasil is the same screens rendered as sacred technology. Phase 0
## decides between them by looking at idle.png in each.

signal changed

const THEMES := {
	"nerv": {
		"ground": Color("#07050A"),
		"frame": Color("#C8321E"),
		"light": Color("#D8D2C8"),
		"core": Color("#F2C230"),
		"cool": Color("#3A5BD9"),
		"alarm": Color("#FF3A1A"),
		"magi": Color("#E07A2C"),
		"breath_period": 12.0,
	},
	"yggdrasil": {
		"ground": Color("#05070D"),
		"frame": Color("#6F7FA8"),
		"light": Color("#DCE6FF"),
		"core": Color("#F2D48A"),
		"cool": Color("#9EF0C8"),
		"alarm": Color("#FF7A1A"),
		"magi": Color("#D9B27C"),
		"breath_period": 10.0,
	},
	# Kingdom Hearts: the command menu and Ansem's computer. Deep navy
	# ground, the menu's blue for hairlines, crown gold at the core, a
	# cyan-white glow, and the heart's red-pink kept for alarms only.
	"kingdom_hearts": {
		"ground": Color("#060A1C"),
		"frame": Color("#4E7EE6"),
		"light": Color("#E8F3FF"),
		"core": Color("#F2C94C"),
		"cool": Color("#6FD3FF"),
		"alarm": Color("#E8365A"),
		"magi": Color("#FFD166"),
		"breath_period": 10.0,
	},
	# Tears of the Kingdom: Zonai technology. Shrine slate, the teal-green
	# of Ultrahand and lightroots, Zonai stone gold at the core and in
	# the counters, and Gloom's magenta-red for alarms.
	"tears_of_the_kingdom": {
		"ground": Color("#0A1412"),
		"frame": Color("#3F9A82"),
		"light": Color("#DDFBF2"),
		"core": Color("#E5B85C"),
		"cool": Color("#62E5C6"),
		"alarm": Color("#C93A5E"),
		"magi": Color("#E8A552"),
		"breath_period": 11.0,
	},
	# Gilliam, Outlaw Star: cassette-futurist wireframes. Amber hairlines
	# on warm black, bright amber at the core, a teal wire accent.
	"gilliam": {
		"ground": Color("#0C0904"),
		"frame": Color("#B8742A"),
		"light": Color("#F5E3C0"),
		"core": Color("#FFB347"),
		"cool": Color("#7FB8A8"),
		"alarm": Color("#FF4D2E"),
		"magi": Color("#FFA53A"),
		"breath_period": 12.0,
	},
	# Terra, Final Fantasy VI, Trance form: the Esper glow. Deep violet
	# ground, orchid hairlines, magenta-pink at the core, a lilac accent,
	# and the hot pink of her fury for alarms.
	"terra_trance": {
		"ground": Color("#0C0616"),
		"frame": Color("#9A5FE0"),
		"light": Color("#F6E9FF"),
		"core": Color("#F26BD6"),
		"cool": Color("#BF9BFF"),
		"alarm": Color("#FF3B7A"),
		"magi": Color("#E9A6FF"),
		"breath_period": 10.0,
	},
	# Swordfish, Cowboy Bebop: phosphor on glass. Green CRT hairlines, CRT
	# amber at the core, the cockpit's blue for the cool accent.
	"swordfish": {
		"ground": Color("#05080A"),
		"frame": Color("#2FA36B"),
		"light": Color("#C9FFD9"),
		"core": Color("#F4E58A"),
		"cool": Color("#8FE3FF"),
		"alarm": Color("#FF6A3D"),
		"magi": Color("#FFC13B"),
		"breath_period": 12.0,
	},
}

var theme_name := "yggdrasil"

## Smoked glass behind each panel in desktop mode: 0 is bare desktop.
## Cycled by the G key. Windowed mode ignores it; the ground is opaque.
const BACKING_LEVELS := [0.0, 0.35, 0.7]
var backing_alpha := 0.0


## Drawn halos. The HDR glow pass writes color but no alpha, so over a
## transparent window its bloom vanishes; in desktop mode every emitting
## element also draws a soft echo of itself with real alpha.
var halo := false


## Thermal tier from the latest sample. At serious and critical the frame
## color itself reddens: the whole piece changes mood, not one glyph.
var thermal := 0


func color(key: String) -> Color:
	var c: Color = THEMES[theme_name][key]
	if key == "frame" and thermal >= 2:
		c = c.lerp(THEMES[theme_name]["alarm"], 0.5 if thermal == 2 else 0.9)
	return c


func breath_period() -> float:
	return THEMES[theme_name]["breath_period"]


## The one slow breath, 0..1 and back, shared by everything that breathes.
func breath() -> float:
	var period := breath_period()
	var phase := fmod(Time.get_ticks_msec() / 1000.0, period) / period
	return 0.5 - 0.5 * cos(TAU * phase)


func set_theme(name: String) -> void:
	if not THEMES.has(name) or name == theme_name:
		return
	theme_name = name
	changed.emit()


## Step to the next palette in THEMES order; the P key.
func next() -> void:
	var names := THEMES.keys()
	set_theme(names[(names.find(theme_name) + 1) % names.size()])


func toggle() -> void:
	next()


## An emitted color: pushed above 1.0 so the glow pass picks it up.
## `heat` 0 is a hairline that barely glows; 1 is the brightest thing on screen.
static func emit(c: Color, heat: float) -> Color:
	var k := 1.0 + 2.5 * clampf(heat, 0.0, 1.0)
	return Color(c.r * k, c.g * k, c.b * k, c.a)


static func dim(c: Color, alpha: float) -> Color:
	return Color(c.r, c.g, c.b, alpha)

