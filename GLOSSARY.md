# Overboard Launcher

How the launcher turns a typed query into an ordered list of results across apps, files, clipboard and other kinds.

## Ranking

**Pick**:
A successful selection of a result for a query. Picks are the only usage the launcher learns from; viewing or scrolling past a result is not a pick.
_Avoid_: Click, use, open

**Exact-query pick**:
A pick made for exactly the query now typed. It is the one signal that outranks everything else in ranking; picks made for longer queries only contribute.
_Avoid_: Pin, favourite

**Match tier**:
How well a result's name matches the query text alone: exact, prefix, words, substring, fuzzy or related. It is one input to ranking, not the ranking itself.
_Avoid_: Score, rank

**Noise location**:
A folder whose contents are machine-managed rather than the user's own, such as dependency caches, vendored code and build output. Recognised from the folder's own traits or marked by the user; results inside it are demoted but stay findable.
_Avoid_: Junk, ignored path

**Excluded folder**:
A folder the user removed from file search entirely. Unlike a noise location, nothing inside it can be found.
_Avoid_: Noise location, ignored path

**Repeat name**:
A result whose display name matches one already ranked above it, e.g. the sixth `not.json` from sibling test folders.
_Avoid_: Duplicate (the files are distinct)
