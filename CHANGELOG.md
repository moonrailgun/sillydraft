# Changelog

[简体中文](CHANGELOG.zh-CN.md)

User-facing changes from v1.0.0 onward, including v1.0.0. Historical entries were reconstructed from Git tags, the corresponding commits and [GitHub Releases](https://github.com/moonrailgun/sillydraft/releases); their dates use tag dates in UTC+8.

## Unreleased

## v1.2.2 · 2026-11-10

### Improved

- Maintenance release.

## v1.2.1 · 2026-11-10

### Fixed

- World books using positions before or after the author’s note now work in writing generation and assistant conversations, with their content included at the default author’s note position.

- HTML frontends preserve their own colors when switching app or reader themes, fixing hard-to-read text on light backgrounds in dark mode. Pages without specified colors default to black text on white, while author-defined colors and backgrounds take precedence.

## v1.2.0 · 2026-11-10

### Added

- A persistent Beta mode switch in Settings enables experimental features.
- Create original comic works in Beta mode, or adapt novel chapters into comics, with a page canvas, editable storyboards and full-screen reading.
- Generate character model sheets and use them as references when drawing comic pages.
- Resume unfinished comic generation, export comics for offline reading, and preserve comic content in backups and version history.

### Improved

- Release notes are maintained in Chinese and English and shared by GitHub Releases and in-app update prompts.

### Fixed

- Available updates now appear above Settings so they are easier to find.

## v1.1.1 · 2026-11-09

### Added

- A setup guide appears when no local model connections are configured, with a shortcut to model settings and an option to keep working offline.
- Available updates remain accessible after choosing Later or restarting the app. Desktop navigation has an update entry, and mobile navigation shows a badge, so release notes and downloads can be reopened.
- The assistant can organize characters, locations, world settings and foreshadowing directly into the story's lore, updating existing entries while preserving images and manually maintained fields. The shortcut is now labeled Organize lore.

### Improved

- Settings are organized into General, Models, Creation and About tabs; model setup links open the Models tab directly.
- Background lore organization also records world rules and background settings from completed chapters.

### Fixed

- Community HTML frontends can read the current character names, messages and variables through the supported SillyTavern context fields, including the user name needed when initializing MVU variables.
- Desktop settings navigation keeps its row height when a badge is displayed.

## v1.1.0 · 2026-11-09

### Improved

- This version remained an unpublished draft. Its features and fixes were first publicly released in v1.1.1 and are listed under that version above.

## v1.0.1 · 2026-11-08

### Improved

- macOS development builds use a distinct SillyDraft Debug name and icon, with a separate library and settings, so they can run alongside the release app without sharing its data.

### Fixed

- Usage and diagnostic reports consistently include the installed app version, making version-specific issues easier to identify.

## v1.0.0 · 2026-11-07

### Added

- Configure separate image engines for ordinary and NSFW content. Illustrations, reference images and regeneration use the classified content type; confirmation shows the selected engine, and NSFW generation stops if no suitable engine is configured.
- Choose a default preset for new blank novels, novels started from character cards and imported novels, without changing existing works.
- Mark lore entries as required for writing context. Request previews explain which entries were included or omitted and why; automatic lore organization preserves the author's required-entry choices.
- HTML frontends preload commonly used Tavern frontend libraries, improving support for community cards and their styles.
- HTML frontends can call EjsTemplate for template rendering and variable operations. Templates in model prompts and world books are not executed automatically.
- Settings include a link to the privacy policy describing local data and network features.
- Basic usage and diagnostic reporting covers page visits, creation tasks, request status and errors, without sending manuscript text, prompts or API keys.

### Improved

- Writing context selects relevant lore within the available prompt budget, prioritizing entries required by the author, named in the request or referenced by those entries.
- Lore timelines group facts and projections by certainty, then order entries by chapter and recording time.
- Writing request preparation keeps the interface responsive while fitting lore into the context budget.

### Fixed

- Focused assistant requests include the current chapter text, helping the assistant interpret references to this chapter and short numbered choices.
- Lore entries without a marked status remain unmarked instead of being shown or saved as in progress.
- Background character organization uses explicit descriptions from the manuscript or existing lore for appearance and clothing, leaving unknown details unspecified.
- HTML frontends that rewrite their page retain host styles, input controls, events and automatic height updates, along with pending requests to the app.
