# Release Notes

Per-version **user-facing** release notes live in [`app/release_notes/`](app/release_notes/) — one file per released version, named `{VERSION}.md`. They describe what changed from the point of view of someone running the collector and watching the dashboards: what's new, what improved, what was fixed.

For the technical detail behind the same releases, see [`CHANGELOG.md`](CHANGELOG.md).

- Format: [`app/release_notes/writing-guide.md`](app/release_notes/writing-guide.md)
- Process: `luxarch --doc FLEET-RELEASE-PROCESS`

The current version is in [`VERSION`](VERSION); every release ships both documents.
