# CmdTabo icon

`CmdTabo.png` is the reviewed 1024 × 1024 RGBA master. The mark uses two windows
and a Tab arrow on a flat blue tile. The surrounding canvas is transparent.
It was generated with the built-in `image_gen` tool, resized for macOS using
system image tools, and stripped of EXIF metadata. Only PNG image/color chunks
remain. No local paths, credentials or account information are embedded.

`scripts/build-icon.sh` derives the 16–1024 px macOS icon set and `Icon.icns` in
the ignored `build/icon/` directory. Packaging installs that file as the bundle’s
icon; Settings loads the same icon. The menu bar uses a matching vector template
drawn by `MenuBarIcon.swift`: two windows and a Tab arrow, with a small update dot.

The publication auditor permits the exact reviewed source bytes by SHA-256.
Changes to the image require another content/metadata review and a new digest;
PNG extensions alone do not create an exception. Content and path scans still run.

## Final generation prompt

Edit target: the supplied CmdTabo macOS icon. The user wants it MUCH simpler,
calmer, less busy. Redesign as a beautifully minimal, flat native macOS app icon.
Keep only the idea of switching windows, not the glossy styling. A single
perfectly clean rounded-square tile in a restrained solid medium-deep blue.
Center an understated white symbol made of ONLY TWO overlapping rounded rectangles
representing windows: one simple thin white outline behind, one clean white front
window with a small blue right-arrow-with-end-bar tab symbol inside it. Plenty of
empty blue space, extremely clear at 32px, balanced geometry, consistent quiet
proportions. Matte, completely flat surfaces; almost no shading, NO gradients,
NO glass, NO translucent stacked panes, NO glows, NO neon, NO bevels, NO highlights,
NO textures, NO 3D perspective, NO decorative border. Tile fills about 82 percent
of the square canvas with even macOS icon margins; outside tile genuine transparent
alpha. No text, no app name, no letters, no watermark. ONE final application icon,
not a mockup or icon sheet.
