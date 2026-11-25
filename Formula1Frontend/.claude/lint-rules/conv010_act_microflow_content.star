# CONV010: ACT_ Microflow Content Restriction
#
# Microflows prefixed with ACT_ are page action microflows. They should only
# contain UI-related activities:
#   - ShowPageAction (show page)
#   - ClosePageAction (close page)
#   - ShowHomePageAction (show home page)
#   - ShowMessageAction (show message)
#   - DownloadFileAction (download file)
#   - MicroflowCallAction (call sub-microflow for logic delegation)
#   - NanoflowCallAction (the same delegation from an ACT_ NANOFLOW)
#
# Business logic should be delegated to SUB_ microflows.
# Requires FULL catalog (REFRESH CATALOG FULL).
#
# NOTE ON NAMES: the catalog labels an action with its *SDK* type name, derived
# from the parsed action's Go type (catalog.getMicroflowActionType). That is not
# always the name Mendix uses in BSON: ShowPageAction is stored as
# "Microflows$ShowFormAction", ClosePageAction as "CloseFormAction", and so on
# (see the storage-name table in CLAUDE.md). This rule matches what the linter
# sees, so it must use the SDK names — it previously used the storage names and
# therefore matched nothing, flagging every ACT_ microflow that showed a page,
# closed one, or called a sub-microflow. Both spellings are listed so the rule
# keeps working if the catalog's vocabulary is ever changed to the storage names.

RULE_ID = "CONV010"
RULE_NAME = "ACTMicroflowContent"
DESCRIPTION = "ACT_ microflows should only contain UI actions and sub-microflow calls"
CATEGORY = "architecture"
SEVERITY = "warning"

# Allowed action types in ACT_ microflows
ALLOWED_ACTIONS = (
    # SDK names — what the catalog actually reports.
    "ShowPageAction",
    "ClosePageAction",
    "ShowHomePageAction",
    "ShowMessageAction",
    "DownloadFileAction",
    "MicroflowCallAction",
    # An ACT_ NANOFLOW delegates with a nanoflow call, not a microflow call.
    # microflows() yields nanoflows too (the catalog's `microflows` table carries
    # a MicroflowType column), so CONV010 lints them — and without this entry it
    # flagged the very delegation it demands: an ACT_ nanoflow could satisfy the
    # rule in no way at all. Reported from a real project, which patched its own
    # copy of the rule and asked for it upstream (ako/mxcli#644).
    #
    # This is the third time this allowlist has been short. It has held the wrong
    # vocabulary (storage names, matching nothing) and been missing an activity a
    # permitted one necessarily creates (ExclusiveMerge). The pattern is the same
    # each time: a rule that cannot be satisfied reads as the code being wrong.
    "NanoflowCallAction",
    # Storage names — belt and braces; see the note above.
    "ShowFormAction",
    "CloseFormAction",
    "ShowHomeFormAction",
)

# Allowed activity types (non-action activities)
#
# ExclusiveMerge is here because an `if` produces BOTH a split and a merge. The
# list allowed the split and forbade the join it necessarily creates, so an ACT_
# microflow that guards anything — "do not open a page with an empty parameter" —
# could not be written cleanly: the guard was permitted and its own closing brace
# was reported. Measured on a microflow whose ONLY violation was the merge, and
# 122 times over on one real project.
ALLOWED_ACTIVITY_TYPES = (
    "SubMicroflow",
    "MicroflowCallAction",
    "StartEvent",
    "EndEvent",
    "ExclusiveSplit",
    "ExclusiveMerge",
    "Annotation",
)

def check():
    violations = []

    for mf in microflows():
        if not mf.name.startswith("ACT_"):
            continue

        for act in activities_for(mf.qualified_name):
            # Skip allowed activity types
            if act.activity_type in ALLOWED_ACTIVITY_TYPES:
                continue

            # For ActionActivity, check the action type
            if act.activity_type == "ActionActivity":
                if act.action_type in ALLOWED_ACTIONS:
                    continue

                violations.append(violation(
                    message="ACT_ {} '{}' contains '{}' action. Delegate business logic to a SUB_ {}.".format(
                        mf.document_noun, mf.name, act.action_type, mf.document_noun
                    ),
                    location=location(
                        module=mf.module_name,
                        document_type=mf.document_noun_title,
                        document_name=mf.qualified_name,
                    ),
                    suggestion="Move the '{}' action to a SUB_ {} and call it from '{}'".format(
                        act.action_type, mf.document_noun, mf.name
                    ),
                ))
            elif act.activity_type not in ALLOWED_ACTIVITY_TYPES:
                # Any other non-allowed activity type
                violations.append(violation(
                    message="ACT_ {} '{}' contains '{}' activity. Delegate to a SUB_ {}.".format(
                        mf.document_noun, mf.name, act.activity_type, mf.document_noun
                    ),
                    location=location(
                        module=mf.module_name,
                        document_type=mf.document_noun_title,
                        document_name=mf.qualified_name,
                    ),
                    suggestion="Move the '{}' to a SUB_ {} called from '{}'".format(
                        act.activity_type, mf.document_noun, mf.name
                    ),
                ))

    return violations
