# Repository Instructions

Before changing user-facing UI, mobile floating controls, or visual styling, read `DESIGN.md` and keep the implementation aligned with it.

For desktop web UI changes, run `python source/tools/design_review.py` before committing. Inspect the generated screenshots in `source/_design_review/` and fix any audit failures instead of relying on memory or a verbal design claim.

For mobile automation work, preserve logs and generated caches only while debugging. Delete throwaway log files and build caches that should not ship before committing.
