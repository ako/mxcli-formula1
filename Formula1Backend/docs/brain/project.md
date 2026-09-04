# Project

<!-- mxcli-brain -->

Decisions that are not about one module. This file is loaded every
session, so it carries the tightest cap — see `mxcli brain show`.

## A two-condition RETRIEVE must spell the operator lowercase: WHERE a = x and b = y. With uppercase AND and a variable reference on either side the build fails CE0161 'Error(s) in XPath constraint', while mxcli check passes -- on every build tried, including current main. With literals on both sides uppercase builds fine, which is why the first reproducer written for this did not reproduce.

Anchors: none · id `bdb04b` · 2026-09-04

## A definition that lives in two MDL files belongs to whichever script ran last. This has bitten three times: a scheduled event in 19 and 20, RowId attributes in 21 and 19/20, and seven Read_Live microflows in 15 and 22 -- the last silently reverted a day's work and the screen went back to reading CSVs. Before adding a definition, grep the model for its name.

Anchors: none · id `dd4c50` · 2026-09-04

## mxcli test --local recompiles the project's Java into deployment/run/bin, the classpath a live 'mxcli run --local' holds open. A class the running app has not loaded yet then fails with NoClassDefFoundError, and the microflows behind it answer HTTP 200 with an empty body rather than an error, so half the app works and half returns nothing. mxcli warns about this now; restart the app afterwards.

Anchors: none · id `84880f` · 2026-09-04

## Upgrading the Mendix version needs mx convert, which sits beside mxbuild and is not wrapped by mxcli. Whether the version can be relabelled rather than converted is decided by _SchemaHash in the .mpr's _MetaData table: create a blank project at the target version and compare. MxBuild's --loose-version-check is not an upgrade -- it prints BUILD SUCCEEDED and leaves the project on the old version.

Anchors: none · id `bfefdc` · 2026-09-04

## mxcli brain resolves its capture queue relative to the working directory, not to -p. Capturing from the repo root and promoting from inside the app silently loses the entries: they queue into ./.mxcli/brain, and a promote run elsewhere never sees them. Run capture, staged and promote from the same directory -- the app directory, where docs/brain lives.

Anchors: none · id `3c35e8` · 2026-09-04
