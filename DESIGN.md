# City Stamina Spender Design System

This design contract is inspired by Open Design's `linear-app` and `mission-control` systems. The app is an operational automation tool, so the interface should feel precise, calm, and easy to scan rather than decorative.

## Product Feel

- Quiet utility with a confident automation-console tone.
- Dense controls are acceptable when they reduce taps, but avoid clutter.
- State should be legible at a glance: active game, stage check, run state, amount, and last action.
- Prefer concrete labels over cute copy. Short status text beats long explanations.

## Visual Language

- Backgrounds: near-neutral dark surfaces or clean light surfaces, with subtle contrast between app, panel, toolbar, and controls.
- Accent: use one restrained action accent for primary automation states, plus semantic status colors for success, warning, and failure.
- Avoid one-note purple/blue gradients, oversized cards, decorative glows, and marketing-style hero layouts.
- Corners: 6-8 dp for panels and repeated items; circular only for the collapsed floating icon or icon-only controls.
- Borders and shadows should separate layers without making the overlay feel bulky.

## Typography

- Use compact labels and stable button widths so text never wraps awkwardly.
- Floating buttons should use one-line labels such as `Run`, `Game`, `Stage`, `Stop`, `Hide`.
- Status messages should be short: `NTE ready`, `Open NTE`, `Stage 1-1`, `Wrong stage`, `Scrolling`, `Need capture`, `Running`, `Stopped`.
- Do not scale type with viewport width. Use fixed sp sizes plus responsive layout constraints.

## Mobile Floating Controls

- Collapsed state is a small draggable icon that does not block system gestures, navigation bars, or app switcher gestures.
- Expanded state should feel like a compact tool tray, not a floating settings page.
- Tapping outside the expanded tray collapses it immediately.
- Controls must remain usable in portrait and landscape, with clamping based on real window metrics.
- Keep the tray away from the bottom gesture zone when possible.
- Text fields must focus reliably and dismiss the keyboard on Done, Run, Game, Stage, Stop, collapse, or outside tap.
- Any button with uncertain latency must show a transient state: checking, scrolling, running, or failed.

## Interaction Rules

- Use icon buttons where the meaning is familiar; pair text only when the action might be ambiguous.
- Use segmented controls or compact toggles for future mode selection such as `1-1` versus `1-9`.
- Avoid nested cards and page sections styled as floating cards.
- Every layout must be checked for text clipping/wrapping on narrow portrait and landscape widths.

## Automation Feedback

- Detection steps should distinguish app-active checks from stage checks.
- Failure messages should tell the next action in 2-4 words, not a paragraph.
- Prefer reversible or observable actions before automation taps/swipes.
- Do not hard-code visual positions when screen-derived detection or calibrated ratios are available.
