# ObjectForge 3D

ObjectForge 3D is an iPhone-first custom-parts app for Continuum Repair.

V1 goal:

- import a photo
- convert the front view into a printable raised/relief or flat-back 3D mesh
- use shape-from-shading style luminance depth and edge boost math
- resize/stretch the part with touch-friendly controls
- export an STL for a slicer or 3D printer workflow

## Current build

This starter app is intentionally practical, not magic. It focuses on photo-to-relief parts first, then later can grow into multi-photo scan/Object Capture.

## Truth rule

ObjectForge should never pretend guessed hidden geometry is perfect.

Future UI should mark confidence zones:

```text
GREEN  = visible/scanned
YELLOW = inferred by math/symmetry
RED    = low-confidence/needs another angle
```

## Build

```bash
brew install xcodegen
xcodegen generate
open ObjectForge3D.xcodeproj
```

GitHub Actions workflow: `.github/workflows/build-objectforge-ios.yml`
