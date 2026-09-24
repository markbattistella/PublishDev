# Changelog

## Unreleased

- Prevent cached preview pages, assets, and reload revisions from surviving a rebuild.
- Name the failed validation step in release summaries and show version-repair advice only when the version check fails.
- Add `make release VERSION=x.y.z` to commit the version bump and atomically push the branch and tag for automatic GitHub publication, with checks for unfinished work, conflicting tags, and behind branches, plus retries after a failed push.
- Add a version-preparation command that offers to fix the source version before committing and tagging.
- Validate source and compiled versions, tests, and terminal behavior before automatically publishing a pushed release tag.
- Flag invalid manually published releases with a clear explanation and repair instructions.

## 0.1.0

- Preview a Publish website locally, rebuild when inputs change, and refresh the browser after successful builds.
- Keep the previous preview available when generation fails.
- Show Return and Ctrl+C instructions at startup and after each build.
- Stop the server and active build processes on normal shutdown or terminal closure; a Python watchdog also releases the preview port after PublishDev is force-killed.
- Offer to replace a verified existing development session, or use another port when an unrelated application occupies it.
- Check for stable GitHub releases daily and offer an update before starting an interactive preview.
- Add `publish dev --version` and `publish dev update`, with `--check` and `--yes` options.
- Build and verify updates before replacing the installed executable, keeping the existing copy working if preparation fails.
