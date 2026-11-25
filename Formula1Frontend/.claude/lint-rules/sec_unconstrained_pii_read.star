# SEC008: Unconstrained READ on Entities Containing PII Attributes
#
# Flags entities that contain personally identifiable information (PII) where
# at least one module role has READ access with no XPath constraint.
# An unconstrained READ means a role can retrieve ALL rows — typically
# inappropriate for PII entities where access should be scoped to the
# current user's own data.

RULE_ID = "SEC008"
RULE_NAME = "UnconstrainedPiiRead"
DESCRIPTION = "Roles can read all rows of entities containing PII without XPath row-scoping"
CATEGORY = "security"
SEVERITY = "warning"

PII_PATTERNS = [
    "email",
    "password",
    "creditcard",
    "credit_card",
    "cardnumber",
    "dateofbirth",
    "date_of_birth",
    "birthdate",
    "ssn",
    "socialsecurity",
    "passport",
    "phonenumber",
    "phone_number",
    "bsn",
    "iban",
    "taxid",
    "tax_id",
    "nationalid",
    "driverlicense",
]

def check():
    violations = []
    for e in entities():
        if e.entity_type != "Persistent" or e.is_external:
            continue

        # Check for PII-sounding attributes
        pii_attrs = []
        for attr in attributes_for(e.qualified_name):
            attr_lower = attr.name.lower()
            for pattern in PII_PATTERNS:
                if pattern in attr_lower:
                    pii_attrs.append(attr.name)
                    break

        if len(pii_attrs) == 0:
            continue

        # Find roles that can read a PII attribute with no row constraint. The
        # entity-level READ row is emitted when ANY member is readable, so it
        # cannot answer this: a role granted `read (FullName)` has it too. The
        # member row can. Its name is qualified for explicit member rights and
        # bare when expanded from default rights, so match either spelling.
        unconstrained_roles = []
        readable_pii = []
        for perm in permissions_for(e.qualified_name):
            if perm.access_type != "MEMBER_READ" or perm.is_constrained:
                continue
            for attr_name in pii_attrs:
                if perm.member_name == attr_name or perm.member_name.endswith("." + attr_name):
                    if perm.module_role_name not in unconstrained_roles:
                        unconstrained_roles.append(perm.module_role_name)
                    if attr_name not in readable_pii:
                        readable_pii.append(attr_name)

        if len(unconstrained_roles) > 0:
            violations.append(violation(
                message="Entity '{}' contains PII attributes ({}) and is readable without XPath row constraints by: {}".format(
                    e.qualified_name,
                    ", ".join(readable_pii),
                    ", ".join(sorted(unconstrained_roles)),
                ),
                location=location(
                    module=e.module_name,
                    document_type="Entity",
                    document_name=e.qualified_name,
                ),
                suggestion="Add XPath constraints to scope access to the current user's own data, e.g. [Sales.Order_Customer/Sales.Customer/id = '[%CurrentUser%]']",
            ))

    return violations
