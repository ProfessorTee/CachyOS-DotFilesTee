package main

// lnart strip – flache Wellenlinien-Zeichnung ("Unknown Pleasures"-Stil) für ein Panel.
// Jede Zeile ist ein Schnitt durch z = f(x, y); Zeilen werden von vorn nach hinten gezeichnet,
// verdeckte Teile entfernt (Floating-Horizon-Verfahren). Ausgabe: JSON auf stdout.

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"math/rand"
	"os"
	"sort"
	"time"

	"github.com/expr-lang/expr/vm"
)

func evalEnv(a, b, c float64) map[string]any {
	env := map[string]any{"pi": math.Pi, "e": math.E, "a": a, "b": b, "c": c,
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
	}
	return env
}

func strip(args []string) {
	fs := flag.NewFlagSet("strip", flag.ExitOnError)
	formel := fs.String("f", "", "Formel (leer = zufällig)")
	file := fs.String("formeln", "", "Formel-Datei")
	W := fs.Float64("w", 1600, "Breite in px")
	H := fs.Float64("h", 44, "Höhe in px")
	rows := fs.Int("rows", 0, "Anzahl Linien (0 = automatisch)")
	step := fs.Float64("step", 2, "Abtastschritt in px")
	seed := fs.Int64("seed", 0, "Seed (0 = Zeit)")
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
	w, h := *W, *H
	n := *rows
	if n <= 0 {
		n = int(math.Max(5, math.Min(30, h/5.5)))
	}
	cols := int(w / *step) + 1
	aspect := w / h
	xr := math.Min(3.5, 0.9+aspect/14) // halbe Breite des x-Bereichs
	yr := 1.0

	var src string
	var a, b, c, lo, hi float64
	var z []float64
	for attempt := 0; ; attempt++ {
		src = *formel
		if src == "" {
			src = pool[rng.Intn(len(pool))]
		}
		prog, err := compile(src)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Formel-Fehler:", err)
			os.Exit(1)
		}
		a, b, c = 0.5+rng.Float64()*1.5, 0.5+rng.Float64()*1.5, 0.5+rng.Float64()*1.5
		phase := (rng.Float64()*2 - 1) * 0.6 // zufällige Verschiebung → jede Zeichnung anders
		env := evalEnv(a, b, c)
		var machine vm.VM
		z = make([]float64, n*cols)
		for r := 0; r < n; r++ {
			y := (float64(r)/float64(n-1)*2 - 1) * yr
			for i := 0; i < cols; i++ {
				x := (float64(i)/float64(cols-1)*2-1)*xr + phase
				env["x"], env["y"] = x, y
				env["r"], env["phi"] = math.Hypot(x, y), math.Atan2(y, x)
				out, err := machine.Run(prog, env)
				v := 0.0
				if err == nil {
					v = out.(float64)
				}
				if math.IsNaN(v) || math.IsInf(v, 0) {
					v = 0
				}
				z[r*cols+i] = v
			}
			// Anstieg der Zeile entfernen (Gerade zwischen den Enden) → nur Hügel/Täler bleiben
			z0, z1 := z[r*cols], z[r*cols+cols-1]
			for i := 0; i < cols; i++ {
				u := float64(i) / float64(cols-1)
				z[r*cols+i] -= z0 + (z1-z0)*u
			}
		}
		s := append([]float64(nil), z...)
		sort.Float64s(s)
		lo, hi = s[len(s)/50], s[len(s)*49/50]
		if hi-lo < 1e-9 {
			hi = lo + 1
		}
		// "Lebendigkeit": mittlere Richtungswechsel pro Zeile – zu ruhig → andere Formel
		turns := 0
		for r := 0; r < n; r++ {
			prev := 0.0
			for i := 1; i < cols; i++ {
				d := z[r*cols+i] - z[r*cols+i-1]
				if math.Abs(d) > (hi-lo)*1e-4 {
					if prev != 0 && (d > 0) != (prev > 0) {
						turns++
					}
					prev = d
				}
			}
		}
		if *formel != "" || attempt >= 7 || float64(turns)/float64(n) >= 3 {
			break
		}
	}

	// Geometrie: Zeile r=0 ganz hinten (oben), r=n-1 vorn (unten)
	pad := math.Max(1.5, h*0.06)
	amp := h * 0.7                       // maximale Auslenkung nach oben
	top := pad + amp                     // Grundlinie der hintersten Zeile
	bottom := h - pad                    // Grundlinie der vordersten Zeile
	horizon := make([]float64, cols)     // höchster (kleinster) bisher gezeichneter y-Wert pro Spalte
	for i := range horizon {
		horizon[i] = math.Inf(1)
	}
	type path []float64
	var paths []path
	for k := 0; k < n; k++ {
		r := n - 1 - k // vorn → hinten
		base := top + (bottom-top)*float64(r)/float64(n-1)
		// leichte Abschwächung zum Rand hin (wie beim Plattencover) für ruhige Enden
		ys := make([]float64, cols)
		rmin, rmax := math.Inf(1), math.Inf(-1)
		for i := 0; i < cols; i++ {
			rmin, rmax = math.Min(rmin, z[r*cols+i]), math.Max(rmax, z[r*cols+i])
		}
		if rmax-rmin < 1e-9 {
			rmax = rmin + 1
		}
		for i := 0; i < cols; i++ {
			tg := (z[r*cols+i] - lo) / (hi - lo)
			tl := (z[r*cols+i] - rmin) / (rmax - rmin)
			t := 0.2*tg + 0.8*tl
			t = math.Max(0, math.Min(1, t))
			u := float64(i) / float64(cols-1)
			edge := math.Sin(math.Pi * u)
			edge = 0.12 + 0.88*math.Pow(edge, 0.8)
			ys[i] = base - t*amp*edge
		}
		// sichtbare Abschnitte bestimmen (Boustrophedon: abwechselnde Richtung wie ein Plotter)
		var segs []path
		var cur path
		for j := 0; j < cols; j++ {
			i := j
			if k%2 == 1 {
				i = cols - 1 - j
			}
			x := float64(i) / float64(cols-1) * w
			vis := ys[i] < horizon[i]-0.25
			if vis {
				cur = append(cur, math.Round(x*10)/10, math.Round(ys[i]*10)/10)
			} else if len(cur) >= 4 {
				segs = append(segs, cur)
				cur = nil
			} else {
				cur = nil
			}
		}
		if len(cur) >= 4 {
			segs = append(segs, cur)
		}
		for i := 0; i < cols; i++ {
			horizon[i] = math.Min(horizon[i], ys[i])
		}
		paths = append(paths, segs...)
	}

	out := map[string]any{
		"meta": map[string]any{"formel": src, "a": a, "b": b, "c": c, "rows": n},
		"w":    w, "h": h, "p": paths,
	}
	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
