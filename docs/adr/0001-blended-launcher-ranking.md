# Blended launcher ranking replaces strict match tiers

Launcher results were ordered strictly by match tier (exact > prefix > words > …), with usage and frecency only breaking ties inside a tier. That let any file whose stem equals the query — `~/go/pkg/mod/…/not.go` for "not" — beat Notes.app's prefix match, because nothing could cross a tier boundary. We replaced it with one blended score shared by the file index and the cross-provider merge: match tier weighs most, and a result's likelihood of being the user's own (app kind on short queries, picks carried from longer queries, Spotlight last-opened date, recent modification, shallow path) adds to it, while noise locations and repeat names subtract. Two rules stay absolute: an exact-query pick wins outright, and the fixed slots (calculator, commands, quicklinks first; web search, Ask AI, calendar, now playing last) sit outside the score.

## Considered Options

- **Keep strict tiers, add more tiers or special cases** (e.g. "app prefix counts as exact"). Rejected: each fix reorders some other query, as `exactStemFileStillBeatsUnlearnedAcronym` already shows.
- **Exclude noise folders from the index.** Rejected: dependency sources are occasionally exactly what's wanted; demotion keeps them findable.
- **Hardcoded noise folder names.** Rejected in favour of traits the paths already carry (version-stamped folder names, `.gitignore`), with the user's own noise / not-noise list as the only list. Detecting unusually large folders was also considered and deferred: it needs a post-scan pass and would flag photo and music libraries.

## Consequences

Ranking now has tunable weights, so changes are judged against a ranking eval set of `query → expected top result` cases rather than by intuition.
