# Flux — Brand

**Everything you download. Under control.**

## Motif

A **halftone blue sky with white cumulus clouds**. The clouds say *the internet*; the
halftone dot pattern says *data, transferred piece by piece*: exactly what Flux's
multi-connection engine does. Source image: `Resources/Brand/sky-halftone.jpg`
(1358 × 1697).

## Palette (measured from the source image)

| Name | Hex | Role |
|---|---|---|
| Flux Blue (ink) | `#2D57D5` | Primary brand color, accent in light mode, progress bars |
| Cloud White (paper) | `#ECF9FE` | Highlights, text on blue, logo negative space |
| Sky (blend) | `#5D80D8` | How ink + paper read at a distance; secondary surfaces |
| Flux Blue, dark mode | `#6F92F2` | Accent in dark mode (lifted for contrast) |

Defined in code in `Sources/Flux/Theme/FluxTheme.swift`; never hard-code these elsewhere.

## Usage in the app

- The sky image sits behind the main window, Settings and the Add sheet at **16 % opacity
  in light mode, 22 % in dark mode**, so text stays readable.
- Controls and progress use the Flux Blue accent.
- Native materials (sidebar, toolbar, status bar) stay native; the sky shows through
  translucent areas.
- Empty states use cloud SF Symbols (`icloud.and.arrow.down`).

## Logo direction (to design)

Requirements:
1. Built from the halftone sky: a cloud silhouette rendered in Flux Blue halftone dots
   on Cloud White, or the reverse.
2. A downward motion inside or below the cloud (arrow or falling dots, like rain or
   data coming down) for "download".
3. Works as a macOS app icon (rounded square, legible at 16 px: at small sizes,
   switch from halftone dots to a solid cloud shape) and as a monochrome menu bar glyph.
4. Wordmark "Flux" set in a clean geometric sans, Flux Blue.
