# Starlark Lint Rule: Orphaned Elements
#
# This rule checks for elements that are not referenced anywhere in the project.
# Orphaned elements may be:
#   - Dead code that should be removed
#   - Entry points that should be documented
#   - Work in progress that was forgotten
#
# Checks:
#   - Microflows with no callers (except ACT_ which are UI entry points)
#   - Pages with no show_page references (except entry pages)
#   - Entities with no references at all
#
# This rule requires REFRESH CATALOG FULL to populate the refs table.
#
# Options (lint-config.yaml, rules.QUAL004.options):
#   entry_point_prefixes - microflow name prefixes that mark an entry point,
#                          as a YAML list or comma-separated text. Replaces
#                          the built-in list below; unset keeps it.
#
# Edit the option, not this file: an edited copy is kept, and no longer
# receives mxcli's updates to the rule.

RULE_ID = "QUAL004"
RULE_NAME = "Orphaned Elements"
DESCRIPTION = "Elements should be referenced somewhere in the project or marked as entry points"
CATEGORY = "quality"
SEVERITY = "info"

# Prefixes for microflows that are expected to be entry points, unless the
# entry_point_prefixes option says otherwise
ENTRY_POINT_PREFIXES = ["ACT_", "SCH_", "WS_", "REST_", "OData_"]

# Page name patterns that are likely entry points
ENTRY_PAGE_PATTERNS = ["Home", "Login", "Index", "Dashboard"]

# Reference kinds that mean "something causes this microflow to run". These are
# catalog RefKind values (mdl/catalog/builder_references.go); a kind missing here
# turns a live document into a false "not called from anywhere" finding.
MICROFLOW_ENTRY_KINDS = ["call", "schedule", "publish", "datasource", "action", "calculate", "settings", "event"]

# Reference kinds that mean "something opens this page".
PAGE_ENTRY_KINDS = ["show_page", "home_page", "login_page", "menu_item", "action"]

def is_entry_point_microflow(name, prefixes):
    """Check if a microflow name suggests it's a UI/scheduled entry point."""
    for prefix in prefixes:
        if name.startswith(prefix):
            return True
    return False

def is_entry_point_page(name):
    """Check if a page name suggests it's an entry point."""
    for pattern in ENTRY_PAGE_PATTERNS:
        if pattern in name:
            return True
    return False

def check():
    """
    Check for orphaned elements that have no incoming references.
    """
    violations = []
    entry_prefixes = get_list_option("entry_point_prefixes", ENTRY_POINT_PREFIXES)
    rename_hint = "/".join(entry_prefixes[:2]) if entry_prefixes else "an entry-point"

    # Check microflows
    for mf in microflows():
        # Skip entry point microflows
        if is_entry_point_microflow(mf.name, entry_prefixes):
            continue

        # Get references to this microflow
        refs = refs_to(mf.qualified_name)

        # Anything that causes the microflow to run counts as a caller, not just
        # a literal "call" edge. A microflow reached only through one of the other
        # kinds was reported as orphaned with the suggestion "Remove if unused":
        #
        #   schedule    a scheduled event runs it (Mendix's cron)
        #   datasource  a page or widget uses it as a data source
        #   action      a widget button calls it
        #   calculate   a calculated attribute computes with it
        #   settings    a project setting names it (after-startup, before-shutdown,
        #               health-check) — the RUNTIME calls it, and nothing in the
        #               model does
        #
        # The banking-app report hit the 'datasource' case: DS_CurrentCustomer and
        # DS_MyAccounts are both page data sources and both were flagged. The
        # CapTrackV4 report hit 'settings': the project's own AfterStartupMicroflow
        # was reported as "not called from anywhere. Remove if unused", and taking
        # that advice left a dangling name mx check did not catch either — only the
        # runtime refused to start.
        has_callers = False
        for ref in refs:
            if ref.ref_kind in MICROFLOW_ENTRY_KINDS:
                has_callers = True
                break

        if not has_callers:
            loc = location(
                module=mf.module_name,
                document_type=mf.document_noun_title,
                document_name=mf.qualified_name
            )
            v = violation(
                message="{} '{}' is not called from anywhere.".format(mf.document_noun_title, mf.name),
                location=loc,
                suggestion="Remove if unused, rename with {} prefix if it's an entry point, or add its prefix to rules.QUAL004.options.entry_point_prefixes in lint-config.yaml.".format(rename_hint)
            )
            violations.append(v)

    # Check pages
    for page in pages():
        # Skip likely entry point pages
        if is_entry_point_page(page.name):
            continue

        # Get references to this page
        refs = refs_to(page.qualified_name)

        # A page is reachable if anything opens it. Navigation counts: a page that
        # is only a home page, a login page or a menu item is reached by the
        # client, not by a microflow. Counting only 'show_page' reported those as
        # orphaned — masked until now by ENTRY_PAGE_PATTERNS, which happens to
        # cover the pages most likely to be navigation targets.
        is_shown = False
        for ref in refs:
            if ref.ref_kind in PAGE_ENTRY_KINDS:
                is_shown = True
                break

        if not is_shown:
            loc = location(
                module=page.module_name,
                document_type="Page",
                document_name=page.qualified_name
            )
            v = violation(
                message="Page '{}' is not shown from any microflow.".format(page.name),
                location=loc,
                suggestion="Remove if unused, or verify it's configured as a menu item or home page."
            )
            violations.append(v)

    return violations
