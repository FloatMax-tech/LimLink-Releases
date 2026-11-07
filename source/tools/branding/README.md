# Shared LimLink icon

Android is the reference: black background and a white ring centered at (54, 54),
with outer radius 26 and inner radius 18 in a 108-unit viewport. Android launchers
display the central 72 units; fixed Apple/Windows canvases therefore use radii
39 and 27, preserving the ring thickness ratio and matching the visible scale.

Run from the repository root on macOS:

```sh
swift tools/branding/generate-icons.swift
```

This generates iPhone/iPad AppIcon (opaque PNG), macOS AppIcon (rounded tile
with transparent margins), and the multi-resolution Windows ICO. XcodeGen
projects select the AppIcon asset; the Windows project embeds the ICO and the
main window loads the executable icon. Android retains its adaptive icon.

After changing generated Apple resources, regenerate the Xcode projects with
XcodeGen before building. Existing installed apps need a new build installed to
show these icons.
