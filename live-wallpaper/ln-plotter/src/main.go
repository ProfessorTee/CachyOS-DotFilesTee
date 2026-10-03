// lnart – rendert mathematische Flächen z = f(x, y) mit fogleman/ln als
// Linienzeichnung (inkl. Hidden-Line-Removal) und packt Zeichnungen für den
// "LN Plotter" Wallpaper.
//
//	lnart render [-f "formel"] [-style grid] [-seed 42] [-o bild.svg]
//	lnart pack a.svg b.svg ... > drawings.js
//	lnart list
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"math/rand"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/expr-lang/expr"
	"github.com/expr-lang/expr/vm"
	"github.com/fogleman/ln/ln"
)

// ---------- Formeln ----------
// Variablen: x, y (−1…1 skaliert mit "zoom"), r, phi, a, b, c (zufällig 0.5…2), pi, e
var builtins = []string{
	"sin(a*3*r - phi*b) / (1 + r)",
	"cos(a*4*x) * sin(b*4*y)",
	"exp(-a*4*r*r) * cos(b*10*r)",
	"sin(a*5*r) / (a*5*r + 0.3)",
	"x*x*a - y*y*b",
	"sin(a*3*x + cos(b*3*y)) * cos(c*2*y)",
	"sin(a*2*x*y*4) * exp(-r*r)",
	"exp(-a*6*((x-0.4)^2+y^2)) - exp(-b*6*((x+0.4)^2+(y-0.3)^2)) + 0.6*exp(-c*8*(x^2+(y+0.5)^2))",
	"cos(a*6*r) * exp(-b*1.5*r)",
	"sin(a*6*x) * sin(b*6*y) * exp(-r*r)",
	"atan(a*3*x*y*4)",
	"sin(a*5*sqrt(abs(x*y*4)) + b)",
	"cos(a*3*x)*cos(b*3*y)*cos(c*3*(x+y))",
	"(x^3*a - 3*x*y*y*b)",
	"sin(a*8*x + b*3*sin(c*4*y))",
	"-1 / (a*8*r*r + 1)",
	"sin(phi*round(a*3+1) + r*b*4) * r",
	"abs(sin(a*4*x)) + abs(cos(b*4*y))",
}

type Env struct {
	X, Y, R, Phi, A, B, C float64
}

func compile(src string) (*vm.Program, error) {
	// ^ als Potenz zulassen (expr kennt ** und ^)
	return expr.Compile(src,
		expr.Env(map[string]any{
			"x": 0.0, "y": 0.0, "r": 0.0, "phi": 0.0, "a": 0.0, "b": 0.0, "c": 0.0,
			"pi": math.Pi, "e": math.E,
			"sin": math.Sin, "cos": math.Cos, "tan": math.Tan, "atan": math.Atan, "atan2": math.Atan2,
			"asin": math.Asin, "acos": math.Acos, "sinh": math.Sinh, "cosh": math.Cosh, "tanh": math.Tanh,
			"exp": math.Exp, "log": math.Log, "sqrt": math.Sqrt, "pow": math.Pow, "mod": math.Mod,
			"sign": func(v float64) float64 {
				if v < 0 {
					return -1
				} else if v > 0 {
					return 1
				}
				return 0
			},
		}),
		expr.AsFloat64(),
	)
}

// ---------- Höhenfeld ----------
type Field struct {
	N    int
	Z    []float64
	Size float64 // Halbe Kantenlänge in Weltkoordinaten
	Box  ln.Box
}

func buildField(prog *vm.Program, a, b, c, zoom, size, height float64, n int) (*Field, error) {
	f := &Field{N: n, Z: make([]float64, n*n), Size: size}
	env := map[string]any{"pi": math.Pi, "e": math.E}
	// Funktionen aus dem Compile-Env übernehmen
	for k, v := range map[string]any{
		"sin": math.Sin, "cos": math.Cos, "tan": math.Tan, "atan": math.Atan, "atan2": math.Atan2,
		"asin": math.Asin, "acos": math.Acos, "sinh": math.Sinh, "cosh": math.Cosh, "tanh": math.Tanh,
		"exp": math.Exp, "log": math.Log, "sqrt": math.Sqrt, "pow": math.Pow, "mod": math.Mod,
		"sign": func(v float64) float64 {
			if v < 0 {
				return -1
			} else if v > 0 {
				return 1
			}
			return 0
		},
	} {
		env[k] = v
	}
	env["a"], env["b"], env["c"] = a, b, c
	var machine vm.VM
	zmin, zmax := math.Inf(1), math.Inf(-1)
	for j := 0; j < n; j++ {
		for i := 0; i < n; i++ {
			x := (float64(i)/float64(n-1)*2 - 1) * zoom
			y := (float64(j)/float64(n-1)*2 - 1) * zoom
			env["x"], env["y"] = x, y
			env["r"], env["phi"] = math.Hypot(x, y), math.Atan2(y, x)
			out, err := machine.Run(prog, env)
			if err != nil {
				return nil, err
			}
			z := out.(float64)
			if math.IsNaN(z) || math.IsInf(z, 0) {
				z = 0
			}
			f.Z[j*n+i] = z
		}
	}
	// robuste Normierung (Ausreißer kappen: 1.–99. Perzentil)
	sorted := append([]float64(nil), f.Z...)
	sortFloats(sorted)
	zmin, zmax = sorted[len(sorted)/100], sorted[len(sorted)*99/100]
	if zmax-zmin < 1e-9 {
		zmax = zmin + 1
	}
	for i, z := range f.Z {
		z = (z - zmin) / (zmax - zmin) // 0…1
		z = math.Max(-0.05, math.Min(1.05, z))
		f.Z[i] = (z - 0.5) * height
	}
	f.Box = ln.Box{Min: ln.Vector{X: -size, Y: -size, Z: -height * 0.6}, Max: ln.Vector{X: size, Y: size, Z: height * 0.6}}
	return f, nil
}

func sortFloats(a []float64) { // kleiner Quicksort-Ersatz ohne extra Import
	if len(a) < 2 {
		return
	}
	p := a[len(a)/2]
	l, r := 0, len(a)-1
	for l <= r {
		for a[l] < p {
			l++
		}
		for a[r] > p {
			r--
		}
		if l <= r {
			a[l], a[r] = a[r], a[l]
			l++
			r--
		}
	}
	sortFloats(a[:r+1])
	sortFloats(a[l:])
}

// bilineare Höhe an Weltkoordinate (x, y)
func (f *Field) H(x, y float64) float64 {
	n := f.N
	u := (x/f.Size + 1) / 2 * float64(n-1)
	v := (y/f.Size + 1) / 2 * float64(n-1)
	u = math.Max(0, math.Min(float64(n-1)-1e-9, u))
	v = math.Max(0, math.Min(float64(n-1)-1e-9, v))
	i, j := int(u), int(v)
	fu, fv := u-float64(i), v-float64(j)
	z00, z10 := f.Z[j*n+i], f.Z[j*n+i+1]
	z01, z11 := f.Z[(j+1)*n+i], f.Z[(j+1)*n+i+1]
	return (z00*(1-fu)+z10*fu)*(1-fv) + (z01*(1-fu)+z11*fu)*fv
}

// ---------- ln-Shape ----------
type Surface struct {
	F     *Field
	Style string
	Lines int
	Rng   *rand.Rand
}

func (s *Surface) Compile()             {}
func (s *Surface) BoundingBox() ln.Box  { return s.F.Box }
func (s *Surface) below(v ln.Vector) bool { return v.Z < s.F.H(v.X, v.Y) }
func (s *Surface) Contains(v ln.Vector, eps float64) bool {
	return s.F.Box.Contains(v) && s.below(v)
}

// Strahl gegen Fläche (Volumen darunter): Box-Clipping + Marching + Bisektion
func (s *Surface) Intersect(ray ln.Ray) ln.Hit {
	b := s.F.Box
	t0, t1 := 0.0, math.Inf(1)
	for k := 0; k < 3; k++ {
		var o, d, lo, hi float64
		switch k {
		case 0:
			o, d, lo, hi = ray.Origin.X, ray.Direction.X, b.Min.X, b.Max.X
		case 1:
			o, d, lo, hi = ray.Origin.Y, ray.Direction.Y, b.Min.Y, b.Max.Y
		default:
			o, d, lo, hi = ray.Origin.Z, ray.Direction.Z, b.Min.Z, b.Max.Z
		}
		if math.Abs(d) < 1e-12 {
			if o < lo || o > hi {
				return ln.NoHit
			}
			continue
		}
		ta, tb := (lo-o)/d, (hi-o)/d
		if ta > tb {
			ta, tb = tb, ta
		}
		t0, t1 = math.Max(t0, ta), math.Min(t1, tb)
		if t0 > t1 {
			return ln.NoHit
		}
	}
	step := s.F.Size * 2 / float64(s.F.N) * 0.75
	eps := s.F.Size * 4e-3 // Selbsttreffer am Startpunkt vermeiden
	t := math.Max(t0, eps)
	// Startpunkt liegt auf der Fläche: bei flachem Austrittswinkel ist der Strahl
	// anfangs noch "unter" der Fläche → diese Strecke ist kein echter Verdecker.
	if t0 < eps {
		limit := t + s.F.Size*0.06
		for t < limit && t <= t1 && s.below(ray.Position(t)) {
			t += step * 0.25
		}
	}
	prev := s.below(ray.Position(t))
	for ; t <= t1; t += step {
		cur := s.below(ray.Position(t))
		if cur != prev {
			lo, hi := t-step, t
			for i := 0; i < 20; i++ {
				m := (lo + hi) / 2
				if s.below(ray.Position(m)) == prev {
					lo = m
				} else {
					hi = m
				}
			}
			return ln.Hit{Shape: s, T: hi}
		}
	}
	return ln.NoHit
}

func (s *Surface) pt(x, y float64) ln.Vector { return ln.Vector{X: x, Y: y, Z: s.F.H(x, y)} }

func (s *Surface) Paths() ln.Paths {
	S := s.F.Size
	n := s.Lines
	fine := S / 300
	var paths ln.Paths
	line := func(fx func(t float64) (float64, float64), t0, t1 float64) {
		var p ln.Path
		for t := t0; t <= t1+1e-9; t += fine {
			x, y := fx(t)
			if x < -S || x > S || y < -S || y > S {
				if len(p) > 1 {
					paths = append(paths, p)
				}
				p = nil
				continue
			}
			p = append(p, s.pt(x, y))
		}
		if len(p) > 1 {
			paths = append(paths, p)
		}
	}
	xl := func() {
		for i := 0; i <= n; i++ {
			y := -S + 2*S*float64(i)/float64(n)
			line(func(t float64) (float64, float64) { return t, y }, -S, S)
		}
	}
	yl := func() {
		for i := 0; i <= n; i++ {
			x := -S + 2*S*float64(i)/float64(n)
			line(func(t float64) (float64, float64) { return x, t }, -S, S)
		}
	}
	switch s.Style {
	case "x":
		xl()
	case "y":
		yl()
	case "diag":
		for i := -n; i <= n; i++ {
			o := 2 * S * float64(i) / float64(n)
			line(func(t float64) (float64, float64) { return t, t + o }, -S, S)
		}
	case "radial":
		for k := 0; k < n*3; k++ {
			ang := 2 * math.Pi * float64(k) / float64(n*3)
			line(func(t float64) (float64, float64) { return t * math.Cos(ang), t * math.Sin(ang) }, 0, S*1.42)
		}
	case "rings":
		for k := 1; k <= n; k++ {
			rad := S * 1.42 * float64(k) / float64(n)
			line(func(t float64) (float64, float64) { return rad * math.Cos(t/rad), rad * math.Sin(t/rad) }, 0, 2*math.Pi*rad)
		}
	case "spiral":
		turns := float64(n) / 1.5
		var p ln.Path
		for t := 0.0; t <= 1; t += fine / (S * turns * 6) {
			rad := S * 1.42 * t
			x, y := rad*math.Cos(t*turns*2*math.Pi), rad*math.Sin(t*turns*2*math.Pi)
			if x < -S || x > S || y < -S || y > S {
				if len(p) > 1 {
					paths = append(paths, p)
				}
				p = nil
				continue
			}
			p = append(p, s.pt(x, y))
		}
		if len(p) > 1 {
			paths = append(paths, p)
		}
	case "contour":
		paths = append(paths, s.contours(n*2)...)
		// Rahmen-Silhouette dazu
		for _, y := range []float64{-S, S} {
			yy := y
			line(func(t float64) (float64, float64) { return t, yy }, -S, S)
		}
		for _, x := range []float64{-S, S} {
			xx := x
			line(func(t float64) (float64, float64) { return xx, t }, -S, S)
		}
	default: // grid
		xl()
		yl()
	}
	return paths
}

// Höhenlinien per Marching Squares (Segmente – vpype linemerge fügt sie zusammen)
func (s *Surface) contours(levels int) ln.Paths {
	f := s.F
	n := 160
	S := f.Size
	h := make([]float64, (n+1)*(n+1))
	for j := 0; j <= n; j++ {
		for i := 0; i <= n; i++ {
			h[j*(n+1)+i] = f.H(-S+2*S*float64(i)/float64(n), -S+2*S*float64(j)/float64(n))
		}
	}
	zmin, zmax := math.Inf(1), math.Inf(-1)
	for _, z := range h {
		zmin, zmax = math.Min(zmin, z), math.Max(zmax, z)
	}
	var out ln.Paths
	for l := 1; l < levels; l++ {
		iso := zmin + (zmax-zmin)*float64(l)/float64(levels)
		for j := 0; j < n; j++ {
			for i := 0; i < n; i++ {
				x0 := -S + 2*S*float64(i)/float64(n)
				y0 := -S + 2*S*float64(j)/float64(n)
				d := 2 * S / float64(n)
				c := [4]float64{h[j*(n+1)+i], h[j*(n+1)+i+1], h[(j+1)*(n+1)+i+1], h[(j+1)*(n+1)+i]}
				px := [4]float64{x0, x0 + d, x0 + d, x0}
				py := [4]float64{y0, y0, y0 + d, y0 + d}
				var pts []ln.Vector
				for e := 0; e < 4; e++ {
					a, b := c[e], c[(e+1)%4]
					if (a < iso) != (b < iso) {
						t := (iso - a) / (b - a)
						x := px[e] + (px[(e+1)%4]-px[e])*t
						y := py[e] + (py[(e+1)%4]-py[e])*t
						pts = append(pts, ln.Vector{X: x, Y: y, Z: iso})
					}
				}
				if len(pts) == 2 {
					out = append(out, ln.Path{pts[0], pts[1]})
				} else if len(pts) == 4 {
					out = append(out, ln.Path{pts[0], pts[1]}, ln.Path{pts[2], pts[3]})
				}
			}
		}
	}
	return out
}

// ---------- Rendern ----------
type Meta struct {
	Formel string  `json:"formel"`
	A      float64 `json:"a"`
	B      float64 `json:"b"`
	C      float64 `json:"c"`
	Style  string  `json:"style"`
	Seed   int64   `json:"seed"`
}

func render(args []string) {
	fs := flag.NewFlagSet("render", flag.ExitOnError)
	formel := fs.String("f", "", "Formel z = f(x, y); leer = zufällig aus eingebauten bzw. -formeln-Datei")
	file := fs.String("formeln", "", "Datei mit Formeln (eine pro Zeile, # = Kommentar)")
	style := fs.String("style", "", "grid|x|y|diag|radial|rings|spiral|contour (leer = zufällig)")
	seed := fs.Int64("seed", 0, "Zufallsseed (0 = Zeit)")
	out := fs.String("o", "lnart.svg", "Ausgabe-SVG")
	W := fs.Float64("w", 1920, "Breite")
	H := fs.Float64("h", 1080, "Höhe")
	lines := fs.Int("lines", 0, "Linienanzahl (0 = passend zum Stil)")
	res := fs.Int("res", 400, "Auflösung des Höhenfelds")
	quiet := fs.Bool("q", false, "keine Ausgabe")
	fs.Parse(args)

	if *seed == 0 {
		*seed = time.Now().UnixNano()
	}
	rng := rand.New(rand.NewSource(*seed))
	pool := builtins
	if *file != "" {
		if p := readFormulas(*file); len(p) > 0 {
			pool = p
		}
	}
	src := *formel
	if src == "" {
		src = pool[rng.Intn(len(pool))]
	}
	prog, err := compile(src)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Formel-Fehler:", err)
		os.Exit(1)
	}
	styles := []string{"grid", "x", "x", "y", "diag", "radial", "rings", "spiral", "contour", "contour"}
	if *style == "" {
		*style = styles[rng.Intn(len(styles))]
	}
	if *lines == 0 {
		*lines = map[string]int{"grid": 46, "x": 90, "y": 90, "diag": 70, "radial": 40, "rings": 60, "spiral": 70, "contour": 22}[*style]
		if *lines == 0 {
			*lines = 60
		}
	}
	a, b, c := 0.5+rng.Float64()*1.5, 0.5+rng.Float64()*1.5, 0.5+rng.Float64()*1.5
	size := 2.0
	height := 0.9 + rng.Float64()*0.9
	field, err := buildField(prog, a, b, c, 1.0, size, height, *res)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Formel-Fehler:", err)
		os.Exit(1)
	}
	surf := &Surface{F: field, Style: *style, Lines: *lines, Rng: rng}
	scene := ln.Scene{}
	scene.Add(surf)

	// Kamera: zufälliger Azimut, Elevation 22–50°
	az := rng.Float64() * 2 * math.Pi
	el := (22 + rng.Float64()*28) * math.Pi / 180
	dist := 7.0 + rng.Float64()*1.5
	eye := ln.Vector{X: dist * math.Cos(el) * math.Cos(az), Y: dist * math.Cos(el) * math.Sin(az), Z: dist * math.Sin(el)}
	center := ln.Vector{X: 0, Y: 0, Z: -0.15}
	up := ln.Vector{X: 0, Y: 0, Z: 1}
	fovy := 38.0

	start := time.Now()
	paths := renderParallel(&scene, eye, center, up, *W, *H, fovy, 0.004)
	// SVG-Koordinaten: y nach unten
	if err := writeSVG(*out, paths, *W, *H, Meta{src, a, b, c, *style, *seed}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if !*quiet {
		fmt.Printf("%s  [%s, a=%.2f b=%.2f c=%.2f]  %d Pfade, %.1fs\n", src, *style, a, b, c, len(paths), time.Since(start).Seconds())
	}
}

func readFormulas(path string) []string {
	fh, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer fh.Close()
	var out []string
	sc := bufio.NewScanner(fh)
	for sc.Scan() {
		l := strings.TrimSpace(sc.Text())
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		if _, err := compile(l); err != nil {
			fmt.Fprintf(os.Stderr, "übersprungen (%v): %s\n", err, l)
			continue
		}
		out = append(out, l)
	}
	return out
}

func renderParallel(scene *ln.Scene, eye, center, up ln.Vector, w, h, fovy, step float64) ln.Paths {
	scene.Compile()
	matrix := ln.LookAt(eye, center, up).Perspective(fovy, w/h, 0.1, 100)
	paths := scene.Paths().Chop(step)
	workers := runtime.NumCPU()
	res := make([]ln.Paths, workers)
	var wg sync.WaitGroup
	for k := 0; k < workers; k++ {
		wg.Add(1)
		go func(k int) {
			defer wg.Done()
			filter := &ln.ClipFilter{Matrix: matrix, Eye: eye, Scene: scene}
			for i := k; i < len(paths); i += workers {
				res[k] = append(res[k], paths[i].Filter(filter)...)
			}
		}(k)
	}
	wg.Wait()
	var all ln.Paths
	for _, r := range res {
		all = append(all, r...)
	}
	all = all.Simplify(1e-6)
	return all.Transform(ln.Translate(ln.Vector{X: 1, Y: 1, Z: 0}).Scale(ln.Vector{X: w / 2, Y: h / 2, Z: 0}))
}

func writeSVG(path string, paths ln.Paths, w, h float64, m Meta) error {
	var sb strings.Builder
	meta, _ := json.Marshal(m)
	fmt.Fprintf(&sb, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%g\" height=\"%g\" viewBox=\"0 0 %g %g\">\n", w, h, w, h)
	fmt.Fprintf(&sb, "<desc>%s</desc>\n<g fill=\"none\" stroke=\"black\" stroke-width=\"1\">\n", xmlEsc(string(meta)))
	for _, p := range paths {
		if len(p) < 2 {
			continue
		}
		sb.WriteString("<polyline points=\"")
		for i, v := range p {
			if i > 0 {
				sb.WriteByte(' ')
			}
			fmt.Fprintf(&sb, "%.2f,%.2f", v.X, h-v.Y)
		}
		sb.WriteString("\"/>\n")
	}
	sb.WriteString("</g>\n</svg>\n")
	return os.WriteFile(path, []byte(sb.String()), 0644)
}

func xmlEsc(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

// ---------- Packen für den Wallpaper ----------
var (
	reViewBox = regexp.MustCompile(`viewBox="([^"]+)"`)
	reWH      = regexp.MustCompile(`<svg[^>]*\swidth="([\d.]+)[a-z]*"[^>]*\sheight="([\d.]+)[a-z]*"`)
	reDesc    = regexp.MustCompile(`(?s)<desc>(.*?)</desc>`)
	rePoly    = regexp.MustCompile(`<polyline[^>]*\spoints="([^"]+)"`)
	rePath    = regexp.MustCompile(`<path[^>]*\sd="([^"]+)"`)
	reNum     = regexp.MustCompile(`-?[\d.]+(?:e-?\d+)?`)
	reCmd     = regexp.MustCompile(`[MLHVZmlhvz]|-?[\d.]+(?:e-?\d+)?`)
)

type Drawing struct {
	W, H  float64
	Meta  json.RawMessage
	Paths [][]float64
}

func parseSVG(path string) (*Drawing, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	s := string(data)
	d := &Drawing{}
	if m := reViewBox.FindStringSubmatch(s); m != nil {
		v := reNum.FindAllString(m[1], -1)
		if len(v) == 4 {
			d.W, _ = strconv.ParseFloat(v[2], 64)
			d.H, _ = strconv.ParseFloat(v[3], 64)
		}
	}
	if d.W == 0 {
		if m := reWH.FindStringSubmatch(s); m != nil {
			d.W, _ = strconv.ParseFloat(m[1], 64)
			d.H, _ = strconv.ParseFloat(m[2], 64)
		}
	}
	if m := reDesc.FindStringSubmatch(s); m != nil {
		raw := strings.NewReplacer("&amp;", "&", "&lt;", "<", "&gt;", ">", "&quot;", "\"").Replace(m[1])
		if json.Valid([]byte(raw)) {
			d.Meta = json.RawMessage(raw)
		}
	}
	for _, m := range rePoly.FindAllStringSubmatch(s, -1) {
		var p []float64
		for _, n := range reNum.FindAllString(m[1], -1) {
			f, _ := strconv.ParseFloat(n, 64)
			p = append(p, math.Round(f*10)/10)
		}
		if len(p) >= 4 {
			d.Paths = append(d.Paths, p)
		}
	}
	// vpype schreibt <path d="M x,y L x,y …">
	for _, m := range rePath.FindAllStringSubmatch(s, -1) {
		toks := reCmd.FindAllString(m[1], -1)
		var p []float64
		var cmd string
		var cx, cy, sx, sy float64
		flush := func() {
			if len(p) >= 4 {
				d.Paths = append(d.Paths, p)
			}
			p = nil
		}
		num := func(i *int) float64 { f, _ := strconv.ParseFloat(toks[*i], 64); *i++; return f }
		for i := 0; i < len(toks); {
			t := toks[i]
			if strings.ContainsAny(t, "MLHVZmlhvz") {
				cmd = t
				i++
				if cmd == "Z" || cmd == "z" {
					p = append(p, sx, sy)
					cx, cy = sx, sy
				}
				continue
			}
			switch cmd {
			case "M", "m":
				x, y := num(&i), num(&i)
				if cmd == "m" {
					x, y = cx+x, cy+y
				}
				flush()
				cx, cy, sx, sy = x, y, x, y
				p = append(p, x, y)
				if cmd == "M" {
					cmd = "L"
				} else {
					cmd = "l"
				}
				continue
			case "L":
				cx, cy = num(&i), num(&i)
			case "l":
				cx, cy = cx+num(&i), cy+num(&i)
			case "H":
				cx = num(&i)
			case "h":
				cx += num(&i)
			case "V":
				cy = num(&i)
			case "v":
				cy += num(&i)
			default:
				i++
				continue
			}
			p = append(p, cx, cy)
		}
		flush()
	}
	for _, p := range d.Paths {
		for i := range p {
			p[i] = math.Round(p[i]*10) / 10
		}
	}
	return d, nil
}

func pack(args []string) {
	fs := flag.NewFlagSet("pack", flag.ExitOnError)
	out := fs.String("o", "", "Ausgabedatei (Standard: stdout)")
	fs.Parse(args)
	var sb strings.Builder
	sb.WriteString("window.LN_DRAWINGS = [\n")
	count := 0
	for _, f := range fs.Args() {
		d, err := parseSVG(f)
		if err != nil || len(d.Paths) == 0 || d.W == 0 {
			fmt.Fprintln(os.Stderr, "übersprungen:", f)
			continue
		}
		base := f[strings.LastIndex(f, "/")+1:]
		obj := map[string]any{"n": strings.TrimSuffix(base, ".svg"), "w": d.W, "h": d.H, "p": d.Paths}
		if d.Meta != nil {
			obj["meta"] = d.Meta
		}
		js, _ := json.Marshal(obj)
		if count > 0 {
			sb.WriteString(",\n")
		}
		sb.Write(js)
		count++
	}
	sb.WriteString("\n];\n")
	if *out == "" {
		os.Stdout.WriteString(sb.String())
		return
	}
	tmp := *out + ".tmp"
	if err := os.WriteFile(tmp, []byte(sb.String()), 0644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Rename(tmp, *out)
	fmt.Fprintf(os.Stderr, "%d Zeichnung(en) → %s\n", count, *out)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("lnart render [-f formel] [-style grid|x|y|diag|radial|rings|spiral|contour] [-o out.svg]\nlnart pack *.svg -o drawings.js\nlnart list")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "render":
		render(os.Args[2:])
	case "pack":
		pack(os.Args[2:])
	case "strip":
		strip(os.Args[2:])
	case "meta": // Metadaten (<desc>) von src nach dst kopieren – vpype verwirft sie
		if len(os.Args) != 4 {
			fmt.Fprintln(os.Stderr, "lnart meta quelle.svg ziel.svg")
			os.Exit(1)
		}
		src, _ := os.ReadFile(os.Args[2])
		dst, err := os.ReadFile(os.Args[3])
		m := reDesc.FindString(string(src))
		if err != nil || m == "" {
			os.Exit(0)
		}
		loc := regexp.MustCompile(`<svg[^>]*>`).FindStringIndex(string(dst))
		if loc == nil {
			os.Exit(0)
		}
		out := string(dst[:loc[1]]) + "\n" + m + string(dst[loc[1]:])
		os.WriteFile(os.Args[3], []byte(out), 0644)
	case "list":
		for _, f := range builtins {
			fmt.Println(f)
		}
	default:
		render(os.Args[1:])
	}
}
