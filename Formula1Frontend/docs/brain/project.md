# Project

<!-- mxcli-brain -->

Decisions that are not about one module. This file is loaded every
session, so it carries the tightest cap — see `mxcli brain show`.

## Regenerating consumed entities means DROP ODATA CLIENT and recreate, and that wipes every entity access grant on the module. They are all in 11-navigation-security.mdl, so re-running it restores them -- but only if you notice, and the symptom is a build failure in a file you did not touch.

Anchors: none · id `337e53` · 2026-09-04

## A page-level identifier is not one vocabulary. The enclosing data view's own name resolves in a styling expression -- it is how the session chips highlight themselves -- and is refused as a datasource argument, which wants $currentObject. The build reports it as four generic 'Error(s) in expression' against the data widgets rather than naming the word that is wrong.

Anchors: none · id `f05143` · 2026-09-04
