# Legacy Browser Compatibility Playbook

**Version**: 1.0
**Date**: 2026-08-06
**Status**: Current

---

## 1. Context

The nanoportal admin web UI (React 19 + Vite 8 + Tailwind CSS v4 + Radix UI / shadcn-style
primitives) rendered **translucent and overlapped** in Chrome 109 (released Jan 2023). Modern
browsers were unaffected. This document records the root cause, the fix, and a reusable
methodology for avoiding the same class of problem in other projects.

## 2. Symptom

- Cards, panels, and the app shell appear **transparent / see-through**; content from layers
  behind shows through (hence "overlapped").
- Text and borders render with wrong/borrowed colors.
- `npm run build` and lint remain **green** — the CSS compiles fine. The failure only happens at
  browser parse time, so build tooling will not catch it.

## 3. Root cause

Chrome 109 predates two CSS features that shipped together in Chrome 111:

| Feature | First Chrome |
| --- | --- |
| `oklch()` / `oklab()` | 111 |
| `color-mix()` | 111 |

### 3.1 Invalid custom properties → every surface goes transparent

The design system stored every color as a CSS custom property in `oklch(...)`:

```css
:root {
  --background: oklch(0.985 0.003 247.858);
  --card: oklch(1 0 0);
  --border: oklch(0.929 0.013 255.508);
  ...
}
```

In Chrome 109 an unsupported value makes the custom property **invalid at computed-value time**.
Any `var(--x)` reference to it then resolves to the *guaranteed-invalid value*, which resets the
property to its initial value:

```css
body { background-color: var(--background); }  /* → transparent */
.card { background-color: var(--card); }       /* → transparent */
* { border-color: var(--border); }             /* → currentColor (bleeds as text color) */
```

This is exactly the "translucent and overlapped" symptom.

### 3.2 Tailwind v4 opacity modifiers compile to `color-mix()`

In Tailwind v4, `bg-primary/10` compiles to:

```css
@supports (color:color-mix(in lab, red, red)) {
  .bg-primary\/10 { background-color: color-mix(in oklab, var(--primary) 10%, transparent); }
}
```

- The `@supports` guard means modern browsers get the correct tint.
- For **static** colors (`bg-black/60`) Tailwind also emits a hex-alpha fallback (`#0009`), which
  works in Chrome 109.
- For **theme-token** colors (`bg-primary/10`) the pre-guard fallback is the fully-opaque
  `var(--primary)`, so on Chrome 109 tints collapse to solid colors.

**Key lesson:** build green ≠ browser green. Always grep the compiled output for modern CSS
functions and know your minimum-browser floor.

## 4. The fix methodology

### Step 1 — Detect

Grep the built CSS for functions above the browser floor:

```bash
grep -oE 'oklch|oklab|color-mix|light-dark|hwb\(|lab\(|lch\(|rgb\(from' dist/assets/*.css
```

Cross-reference against a compatibility reference (Section 6).

### Step 2 — Convert tokens to hex (exact 1:1)

Replace `oklch(...)` token values with their exact sRGB hex equivalents. Conversion is
deterministic; compute it rather than eyeballing (script included in Section 7). Modern browsers
render the hex values pixel-identically, so this is risk-free on evergreen browsers.

### Step 3 — Restore translucent tints with a guarded fallback block

Add **un-layered** CSS rules inside a capability guard. Un-layered author CSS beats Tailwind's
`@layer utilities`, and the `@supports` guard keeps modern browsers completely unaffected:

```css
@supports not (color: color-mix(in srgb, red, blue)) {
  .bg-primary\/10 { background-color: rgb(21 93 252 / 0.1); }
  .dark .bg-primary\/10 { background-color: rgb(107 162 233 / 0.1); }
  /* one rule per used /NN class, scoped per theme */
}
```

Build/minifiers convert `rgb(R G B / A)` to 8-digit hex (`#155dfc1a`), which is supported from
Chrome 62 — safe on the legacy floor.

### Step 4 — Enumerate exactly which /NN classes you use

Don't guess; grep the source:

```bash
grep -rhoE '[a-z]+-[a-z0-9-]+/[0-9]+' src --include='*.tsx' --include='*.css' -r | sort | uniq -c
```

Ignore geometric fractions (`top-1/2`, `w-1/3`). Also scan for gradient/ring/shadow/text
modifiers (`(from|via|to|ring|shadow|text)-[a-z-]+/[0-9]+`). Only the classes actually used need
fallbacks.

### Step 5 — Verify

```bash
grep -c 'oklch' dist/assets/*.css        # expect 0
grep -c 'supports not (color:color-mix' dist/assets/*.css  # expect ≥ 1
npm run build && npm run lint
```

Confirm every `color-mix(` occurrence sits inside an `@supports` guard.

## 5. Full Chrome 109 audit (nanoportal, verified 2026-08)

### CSS features present in compiled output

| Feature | First Chrome | In 109? | Status |
| --- | --- | --- | --- |
| `oklch()` / `oklab()` tokens | 111 | ❌ | Fixed → hex |
| `color-mix()` opacity modifiers | 111 | ❌ | Fixed → `@supports` fallbacks |
| `@property` (Tailwind `--tw-*`) | 85 | ✅ | OK |
| Range media queries `@media (width>=40rem)` | 104 | ✅ | OK |
| Individual `translate` property | 104 | ✅ | OK |
| `:where()` | 88 | ✅ | OK |
| `@layer` | 99 | ✅ | OK |
| 8-digit hex | 62 | ✅ | OK (used by fallbacks) |
| `backdrop-filter` (prefixed + unprefixed) | 76 | ✅ | OK |

### JS / Web APIs present in the bundle

- No ES2023+ builtins (`findLast`, `toSorted`, `toReversed`, `withResolvers`, `groupBy`, …).
- `@radix-ui/react-collection` defines its own `OrderedDict extends Map` with internal
  `toSorted`/`at` — no reliance on global Array methods.
- Web APIs: `IntersectionObserver` (51), `ResizeObserver` (64), `queueMicrotask` (71) — all fine.
- No `structuredClone`, `randomUUID`, `AbortSignal.timeout`, lookbehind regex.
- React 19 / react-router 7 / sonner (CSS clean) — all Chrome-109-safe.

### Known minor deltas (not breakages)

1. Tints on legacy browsers blend in **sRGB**; modern browsers blend in **oklab**. At 10–15%
   opacity the difference is imperceptible.
2. No enter/exit animations: the `animate-in`/`fade-in-*` classes are inert on **all** browsers
   when the `tailwindcss-animate` plugin is absent — not a Chrome-109-specific regression.
3. Inter font is referenced but not bundled; falls back to system-ui (cosmetic, all browsers).

## 6. Compatibility reference

| Feature | Chrome | Safari | Firefox |
| --- | --- | --- | --- |
| `oklch()` / `oklab()` | 111 | 15.4 | 113 |
| `color-mix()` | 111 | 16.2 | 113 |
| `light-dark()` | 123 | 17.5 | 120 |
| `@property` | 85 | 16.4 | 128 |
| Range media queries | 104 | 16 | 102 |
| Individual `translate`/`rotate`/`scale` | 104 | 14.1 | 72 |
| `:has()` | 105 | 15.4 | 121 |
| `:where()` | 88 | 14 | 78 |
| `@layer` | 99 | 15.4 | 97 |
| `backdrop-filter` | 76 | 9 | 103 |
| 8-digit hex (`#rrggbbaa`) | 62 | 10 | 49 |
| `dvh`/`svh` units | 108 | 15.4 | 101 |
| `Array.prototype.at` | 92 | 15.4 | 90 |
| `Promise.withResolvers` | 119 | 17.4 | 121 |

## 7. Reusable checklist for other projects

1. **Define the browser floor** up front (e.g., "Chrome ≥ 109, Safari ≥ 16, Firefox ≥ 102").
2. After building, **grep `dist` for modern functions** above the floor (Section 4, Step 1).
3. If tokens use `oklch`/`lab`/`hwb`, **convert to hex** with the script below (Section 8).
4. If `/NN` opacity modifiers exist, **add the guarded fallback block** for the exact classes
   used (Section 4, Steps 3–4).
5. Re-grep the bundle for **JS globals / Web APIs** above the floor (ES2023+ Array methods,
   `Promise.withResolvers`, `structuredClone`, `AbortSignal.timeout`, …).
6. Smoke-test the actual pages on the oldest supported browser.
7. Optionally add a **CI regression guard** that fails the build if unguarded `oklch`/`color-mix`
   appears in `dist` again.

### Adaptation notes

- **Tailwind v3 / shadcn-v3 projects**: tokens are usually stored as `R G B` triplets and used via
  `rgb(var(--x) / <alpha-value>)`, which Chrome 109 supports natively — only the token values
  need to be checked for `oklch()`.
- **PostCSS / browserslist setups**: a fallback plugin (e.g. `postcss-preset-env` with
  `browsers: ['chrome 109']`) may auto-generate fallbacks, but always verify the output — it does
  not polyfill every value-level function (notably `color-mix()` in some versions).
- **Polyfills**: syntax transpilation (`build.target`) does **not** polyfill missing globals
  (e.g. `toSorted`). If you later introduce such APIs, add an explicit polyfill targeted at the
  floor.

## 8. oklch → sRGB hex conversion (Node)

```js
function oklchToHex(L, C, h) {
  const rad = (h * Math.PI) / 180;
  const a = C * Math.cos(rad), b = C * Math.sin(rad);
  let l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  let m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  let s_ = L - 0.0894841775 * a - 1.2914855480 * b;
  l_ = l_ * l_ * l_; m_ = m_ * m_ * m_; s_ = s_ * s_ * s_;
  let r = 4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_;
  let g = -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_;
  let bb = -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_;
  const c = (v) => {
    v = Math.min(1, Math.max(0, v));
    v = v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
    return Math.round(v * 255).toString(16).padStart(2, "0");
  };
  return `#${c(r)}${c(g)}${c(bb)}`;
}
```

## 9. Chrome 109 smoke-test checklist (nanoportal)

- Overview: health banner, 5 KPI cards, tier bars, top-alerts feed.
- Components: grid, detail metrics, instance table; URL-driven `/components/:type`.
- Users & Agents: search + filters, table, pagination.
- User detail tabs: Identity / Agents / Containers / Effective config.
- Agent detail: profile, tools, system prompt, sessions.
- Config Center: editable scalar rows, save flow, audit history.
- Audit Log: search, action filter, JSON detail drawer.
- Alert Rules: create modal, delete confirm, enabled badges.
- Chat: gateway login, agent rail, streaming bubbles, sign out.
- Workspaces: user → agent selectors, directory breadcrumbs.
- Cross-cutting: Radix Select/Dropdown/Dialog/Tooltip/Tabs, sonner toasts, theme toggle
  (dark/light/system), mobile sidebar.
- Browser console: zero errors/warnings; verify no `oklch`/`color-mix` remains in served CSS.

## 10. References

- Fix commit: nanoportal `191220c` — "nanoportal: fix Chrome 109 rendering — replace oklch tokens
  with hex, add color-mix tint fallbacks".
- Changed file: `nanoportal/web/src/index.css`.
- Related: super-repo pointer `b1f17bc`.
