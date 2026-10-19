# Ultracam icon

The final editable artwork is `Assets/Ultracam-icon.svg`: six flat blue and cyan
aperture blades on a pale blue macOS tile. It has no holder, bevels, reflections,
shadows or simulated depth. The outer canvas is transparent. The vector artwork
was refined from a concept created with the built-in image-generation tool on
October 19, 2026.

`bash scripts/generate_icon.sh` renders the SVG with `rsvg-convert` from librsvg,
updates `Assets/Ultracam-icon.png`, and generates all ten macOS AppIcon sizes in
`Config/Assets.xcassets/AppIcon.appiconset`. The artwork and generated sizes are
checked into the project, so normal app builds do not require librsvg. Xcode
compiles the asset catalog for Finder, the Dock and application switching.

Flat concept prompt:

> Use case: style-transfer. Edit target: the attached Ultracam application icon. Completely simplify it into a FLAT VECTOR-STYLE modern macOS camera app icon. Remove the U-shaped holder entirely. Remove every 3D treatment, bevel, lens reflection, drop shadow, material texture, glossy edge and glass effect. The new design is one bold two-dimensional camera-aperture symbol: six simple smooth geometric shutter blades arranged in a circle around a small clean circular negative-space opening. Use a restrained palette of solid cobalt blue and solid cyan on the blades, with excellent contrast and spacious precise geometry. The blades should read as one simple elegant camera-aperture mark at 16px. Center it on a very pale cool blue, completely flat macOS rounded-square tile. The tile itself has no border, no shine, no gradient, no rim or simulated thickness. No concentric realistic lens discs. No U shape, no stand, no holder, no microphone shape, no camera body. No perspective, no 3D, no lighting effects, no photographic or metallic details. Clean vector-art appearance, perfectly crisp smooth edges and generous negative space. One square production app icon with 10% clean transparent margins outside the rounded-square tile. All pixels outside its silhouette must be completely transparent; no stray pixels or noise, no halo, no checkerboard. No letters, no text, no numbers, no watermark, no mockup. Render only this minimal flat icon.
