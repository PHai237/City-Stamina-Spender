# Source Layout

This folder is split by responsibility:

- `desktop_app/`: Windows shell app that hosts the WebView UI and runs automation modules.
- `shared/web_ui/`: HTML, CSS, and JavaScript UI used by the desktop app.
- `modules/owners_selection/`: Owner's Selection automation logic, images, recipes, and Python tool.
- `mobile_app/`: Flutter Android app prototype.
- `tools/`: developer scripts used for packaging and release builds.

The release build still packages runtime data as `web_ui/` and `owners_selection/`
inside the app bundle, so existing update/runtime logic stays compatible.
