# CONV006: No Direct Create/Delete Rights
#
# Entity access rules should not grant CREATE or DELETE directly. Instead,
# create and delete operations should go through microflows that enforce
# business logic. Only READ and WRITE should be granted via access rules.
#
# One finding per entity, naming every role per right: the advice is the same
# for each role, and one row per entity x role x right buried the report (111
# findings on a mid-sized app, ako/mxcli#953).
#
# Requires FULL catalog (REFRESH CATALOG FULL).

RULE_ID = "CONV006"
RULE_NAME = "NoCreateDeleteRights"
DESCRIPTION = "Entity access rules should not grant CREATE or DELETE directly; use microflows instead"
CATEGORY = "security"
SEVERITY = "warning"

RIGHTS = ("CREATE", "DELETE")

def check():
    violations = []

    for entity in entities():
        if entity.entity_type != "Persistent" or entity.is_external:
            continue

        # right -> sorted, de-duplicated roles (a role can hold several rules)
        roles = {}
        for perm in permissions_for(entity.qualified_name):
            if perm.access_type in RIGHTS:
                held = roles.setdefault(perm.access_type, [])
                if perm.module_role_name not in held:
                    held.append(perm.module_role_name)

        granted = [r for r in RIGHTS if r in roles]
        if not granted:
            continue

        parts = ["{} ({})".format(r, ", ".join(sorted(roles[r]))) for r in granted]
        violations.append(violation(
            message="Entity '{}' grants {}. Use a microflow to enforce business logic.".format(
                entity.qualified_name, "; ".join(parts)
            ),
            location=location(
                module=entity.module_name,
                document_type="Entity",
                document_name=entity.qualified_name,
            ),
            suggestion="Remove the {} right{} and implement a microflow (ACT_) with security checks".format(
                " and ".join(granted), "s" if len(granted) > 1 else ""
            ),
        ))

    return violations
