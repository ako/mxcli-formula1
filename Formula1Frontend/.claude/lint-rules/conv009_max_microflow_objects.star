# CONV009: Maximum Microflow Objects (Strict)
#
# Microflows should not contain more than 15 activities (Mendix best practice
# convention). This is stricter than QUAL003's 25-activity threshold.
# Complex microflows should be split into sub-microflows (SUB_).

RULE_ID = "CONV009"
RULE_NAME = "MaxMicroflowObjects"
DESCRIPTION = "Microflows should not exceed 15 activities (Mendix best practice)"
CATEGORY = "quality"
SEVERITY = "info"

MAX_ACTIVITIES = 15

def check():
    violations = []

    for mf in microflows():
        if mf.activity_count > MAX_ACTIVITIES:
            violations.append(violation(
                message="{} '{}' has {} activities (convention max: {}). Split into sub-{}s.".format(
                    mf.document_noun_title, mf.name, mf.activity_count, MAX_ACTIVITIES, mf.document_noun
                ),
                location=location(
                    module=mf.module_name,
                    document_type=mf.document_noun_title,
                    document_name=mf.qualified_name,
                ),
                suggestion="Extract logical sections into SUB_ {}s to keep each under {} activities".format(mf.document_noun, MAX_ACTIVITIES),
            ))

    return violations
