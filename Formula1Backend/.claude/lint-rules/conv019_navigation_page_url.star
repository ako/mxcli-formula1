# CONV019: Navigation Pages Should Be Addressable
#
# Flags a page a navigation profile routes to that has no URL.
#
# A Mendix page is only reachable at `/p/<url>` if it has been given one. Without
# it the page exists solely at the end of a click path: it cannot be bookmarked,
# linked to from an email, reopened after a refresh, or captured directly by
# `mxcli run --local --screenshot-url` — verifying one screen means driving a
# browser through login and the menu (ako/CapTrackV4 FINDINGS 014, R4).
#
# WHY ONLY NAVIGATION TARGETS. Measured on a blank Mendix 11.12.1 app: 0 of 16
# pages carry a URL, Mendix's own included. Reporting every page without one
# would warn about every page of every project from the day it is created, which
# is noise rather than a finding. The pages a profile routes to are different:
# they are the app's top-level screens, the ones a user lands on, bookmarks and
# shares. A page reached only from a button inside another screen is not
# expected to be addressable and is never reported.
#
# Deliberately not reported:
#   - the login page and the not-found page — the platform routes to those
#     itself, so a URL on them buys nothing;
#   - microflow-valued menu items and home pages — the microflow decides what
#     opens, so there is no page here to be addressable;
#   - targets in System and Marketplace modules — that is somebody else's model,
#     and it drops out of the join against pages() rather than being listed here.
#
# Options (.claude/lint-config.yaml):
#   rules:
#     CONV019:
#       enabled: false          # a project that does not want deep links at all
#
# Navigation target properties (navigation_targets()):
#   .profile  - "Responsive", "Phone", "Tablet", …
#   .kind     - "home", "role_home" or "menu"
#   .role     - user role, for a role_home
#   .caption  - menu item caption, for a menu target
#   .page     - qualified page name
#
# Page properties (pages()):
#   .qualified_name, .url  - "" when the page has no URL

RULE_ID = "CONV019"
RULE_NAME = "NavigationPageURL"
DESCRIPTION = "Pages reachable from navigation should have a URL so they can be linked to directly"
CATEGORY = "quality"
SEVERITY = "info"

def _describe(target):
    """How this page is reached, in the words the navigation document uses."""
    if target.kind == "home":
        return "the home page of the '{}' profile".format(target.profile)
    if target.kind == "role_home":
        return "the home page for role '{}' in the '{}' profile".format(target.role, target.profile)
    if target.caption != "":
        return "the '{}' menu item in the '{}' profile".format(target.caption, target.profile)
    return "a menu item in the '{}' profile".format(target.profile)

def check():
    # Pages the linter can see. A target missing from this map is in a System or
    # Marketplace module — not the user's page to give a URL to.
    urls = {}
    modules = {}
    for page in pages():
        urls[page.qualified_name] = page.url
        modules[page.qualified_name] = page.module_name

    # One page can be routed to several ways (home page AND a menu item). Report
    # the page once, naming every route, rather than once per route.
    routes = {}
    for target in navigation_targets():
        if target.page not in urls:
            continue
        if urls[target.page] != "":
            continue
        routes.setdefault(target.page, []).append(_describe(target))

    violations = []
    for page in sorted(routes.keys()):
        how = routes[page]
        violations.append(violation(
            message = "Page '{}' is reachable from navigation ({}) but has no URL, so it cannot be linked to or bookmarked.".format(
                page,
                ", ".join(how),
            ),
            location = location(
                module = modules[page],
                document_type = "Page",
                document_name = page,
            ),
            suggestion = "Give the page a URL — `Url: '{}'` on CREATE PAGE, or the URL property in Studio Pro — so it is reachable at /p/{}. Disable CONV019 in .claude/lint-config.yaml if this app deliberately has no deep links.".format(
                page.split(".")[-1].lower(),
                page.split(".")[-1].lower(),
            ),
        ))

    return violations
