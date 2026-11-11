# iOS-Like interface

Enable **Settings → Appearance → Interface style → iOS-Like**. The mode applies
across platforms; it does not change VPN configuration or platform capabilities.
Standard mode keeps its imported font, background and effects. The selected theme
provides the accent in both interface styles.
The interface style and iOS-Like light/dark selection persist independently.
New installations start in Standard mode; iOS-Like defaults to dark unless a
light/dark preference has already been saved.

## Visual system

This is an operating interface: prioritize connection state, server selection,
legible settings, keyboard access and predictable navigation.

- Background: `#F2F2F7` light / `#101114` dark.
- Surface: `#FFFFFF` light / `#202126` dark.
- Accent: inherited from the selected theme, including custom accents.
- Spacing: 4 pt grid using 8/12/16/24/32 pt, 16 pt page insets, 24 pt primary surface padding.
- Corners: 12 pt controls, 18 pt cards, 24 pt sheets; circular connection control.
- Typography: native Apple system family on Apple platforms, sans-serif fallbacks
  elsewhere. No Apple font files are distributed. Semibold headings, restrained
  tracking, regular body text, localized Russian and English navigation labels.
- Material: opaque cards and lists; clipped backdrop blur and fine edge highlights only for navigation and overlays.
  Glass strength follows the existing appearance setting. Optimized rendering
  removes blur; disabling glass panels makes the shared material opaque.
- Motion: state and navigation transitions use ease-out timing and the selected
  transition speed. Reduced motion and system animation preferences disable the
  new component animations. Animated ambient backgrounds are omitted in this mode.

## Implementation

`lib/theme/ios_like.dart` owns the bounded glass surface, responsive navigation
and connection control. `ThemeController` persists `appearance.interfaceStyle`
and `appearance.iosDarkMode`. `HomePage` selects the presentation while retaining
existing connection, routing and server actions. Shared glass dialogs use the
same material in this mode. Returning to Standard restores its appearance inputs.

## Verification scope

Linux debug build and Dart static analysis; manual captures of narrow and desktop
layouts. Native iOS, Android, macOS and Windows builds require their respective
platform toolchains and were not run for this shared Flutter change.

Refined with the `ios-like-minimalism` skill. Shared geometry and type tokens live
in `lib/theme/ios_like_tokens.dart` (12/14/16/20/28 pt type scale).

The navigation selection substrate has concentric corners (24/20 pt on the
bottom bar, 18/14 pt on the sidebar), follows drag input continuously and commits
the tab on release. While dragging, bounded Liquid Glass adds translucency and
highlight; reduced motion/optimized rendering use a solid fallback. Shared
toggles keep a 44 pt target and use a smaller 15 pt thumb.
