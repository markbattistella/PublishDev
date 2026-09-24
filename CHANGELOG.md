# Changelog

## 0.1.0

- Preview a Publish website locally, rebuild when inputs change, and refresh the browser after successful builds.
- Keep the previous preview available when generation fails.
- Show Return and Ctrl+C instructions at startup and after each build.
- Stop the server and active build processes on normal shutdown or terminal closure; a Python watchdog also releases the preview port after PublishDev is force-killed.
- Offer to replace a verified existing development session, or use another port when an unrelated application occupies it.
- Check for stable GitHub releases daily and offer an update before starting an interactive preview.
- Add `publish dev --version` and `publish dev update`, with `--check` and `--yes` options.
- Build and verify updates before replacing the installed executable, keeping the existing copy working if preparation fails.
