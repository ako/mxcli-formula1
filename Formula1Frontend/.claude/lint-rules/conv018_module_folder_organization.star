# CONV018: Module Folder Organization
#
# Flags a module that has grown past a readable size while keeping every
# document loose in the module root — no folders at all.
#
# Studio Pro lets a module hold folders, and every Mendix style guide expects
# them once a module is more than a handful of documents. Nothing in mxcli
# reported their absence, so a project with 200 documents in one flat module
# scored clean.
#
# THE CONDITION IS DELIBERATELY NARROW, and both halves matter:
#
#   1. more than MAX_ROOT_DOCUMENTS documents sit directly in the module root, AND
#   2. NOT ONE document in the module is in a folder.
#
# The second half is what keeps this from becoming noise. A module that has
# started to organise itself — even one folder — is never flagged, however many
# documents remain at its root, because the team has evidently made a choice
# about where things go and a linter guessing at the rest would be nagging. The
# first half exempts genuinely small modules, where a folder tree costs more
# than it repays. Together they catch exactly one thing: a module nobody has
# ever organised.
#
# Options (.claude/lint-config.yaml):
#   rules:
#     CONV018:
#       options:
#         max_root_documents: 40   # default 20 — documents allowed at a module
#                                  # root before folders are expected
#
# Document properties (documents()):
#   .kind           - catalog ObjectType: "MICROFLOW", "PAGE", "WORKFLOW", …
#   .name           - document name
#   .qualified_name - Module.Name
#   .module_name    - the module holding it
#   .folder         - folder path, or "" when the document is in the module root

RULE_ID = "CONV018"
RULE_NAME = "ModuleFolderOrganization"
DESCRIPTION = "Modules past a readable size should organise their documents into folders"
CATEGORY = "quality"
SEVERITY = "info"

# Default; override with the max_root_documents option.
MAX_ROOT_DOCUMENTS = 20

# The kinds Studio Pro actually lets you file in a folder.
#
# `documents()` projects the whole catalog `objects` view, which includes rows
# whose Folder is hardcoded empty because the element is not a document at all —
# an association belongs to the domain model, an external entity to a consumed
# service, an entity to the Domain Model document. Counting those would report a
# module as unorganised on the strength of elements no one can move.
#
# An allow-list rather than a deny-list on purpose: a document type added to the
# catalog and forgotten here is undercounted, so the rule stays quiet. The other
# polarity would invent violations out of a new non-foldered kind.
FOLDERABLE_KINDS = [
    "MICROFLOW",
    "NANOFLOW",
    "RULE",
    "PAGE",
    "SNIPPET",
    "BUILDING_BLOCK",
    "LAYOUT",
    "ENUMERATION",
    "CONSTANT",
    "JAVA_ACTION",
    "JAVASCRIPT_ACTION",
    "IMAGE_COLLECTION",
    "ICON_COLLECTION",
    "MENU",
    "PAGE_TEMPLATE",
    "SCHEDULED_EVENT",
    "TASK_QUEUE",
    "REGULAR_EXPRESSION",
    "DATA_TRANSFORMER",
    "WORKFLOW",
    "AGENT",
    "AI_MODEL",
    "KNOWLEDGE_BASE",
    "CONSUMED_MCP_SERVICE",
    "DATABASE_CONNECTION",
    "CONSUMED_REST_SERVICE",
    "PUBLISHED_REST_SERVICE",
]

# The kinds a person recognises from the App Explorer, in the order a summary
# reads best. Anything else is counted but summarised under its own kind name.
KIND_LABELS = {
    "MICROFLOW": "microflows",
    "NANOFLOW": "nanoflows",
    "PAGE": "pages",
    "WORKFLOW": "workflows",
    "SNIPPET": "snippets",
    "ENUMERATION": "enumerations",
    "JAVA_ACTION": "Java actions",
    "JAVASCRIPT_ACTION": "JavaScript actions",
    "LAYOUT": "layouts",
    "RULE": "rules",
}

def _summarise(counts):
    """Render the two or three biggest kinds, so the message says what the
    clutter actually IS rather than only how much of it there is."""
    pairs = [(kind, n) for kind, n in counts.items()]
    pairs = sorted(pairs, key = lambda p: (-p[1], p[0]))

    parts = []
    for kind, n in pairs[:3]:
        label = KIND_LABELS.get(kind, kind.lower().replace("_", " "))
        parts.append("{} {}".format(n, label))

    if len(pairs) > 3:
        parts.append("and more")
    return ", ".join(parts)

def check():
    max_root = get_option("max_root_documents", MAX_ROOT_DOCUMENTS)

    foldered = {}   # module -> True once any document is in a folder
    root_counts = {}  # module -> {kind: count} for documents at the root

    for doc in documents():
        if doc.kind not in FOLDERABLE_KINDS:
            continue

        module = doc.module_name
        if module not in root_counts:
            root_counts[module] = {}
            foldered[module] = False

        if doc.folder != "":
            foldered[module] = True
        else:
            counts = root_counts[module]
            counts[doc.kind] = counts.get(doc.kind, 0) + 1

    violations = []
    for module in sorted(root_counts.keys()):
        if foldered[module]:
            continue

        counts = root_counts[module]
        total = 0
        for n in counts.values():
            total += n

        if total <= max_root:
            continue

        violations.append(violation(
            message = "Module '{}' keeps all {} of its documents ({}) in the module root and has no folders.".format(
                module,
                total,
                _summarise(counts),
            ),
            location = location(
                module = module,
                document_type = "Module",
                document_name = module,
            ),
            suggestion = "Group the documents into folders by feature or by type — `mxcli -p <app.mpr> -c \"show structure in {}\"` to see the current layout, then MOVE documents into folders. Set CONV018.options.max_root_documents in .claude/lint-config.yaml if a flat module is intended here.".format(module),
        ))

    return violations
