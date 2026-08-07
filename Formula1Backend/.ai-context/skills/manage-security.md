# Security Management Skill

This skill covers Mendix security configuration via MDL: module roles, user roles, access control (microflows, pages, entities), project security settings, and demo users.

## When to Use This Skill

Use when the user asks to:
- Set up security for a module or project
- Create or manage module roles / user roles
- Grant or revoke access to microflows, pages, or entities
- Configure project security level or demo users
- Review existing security configuration

## Security Concepts

- **Module Roles** define permissions within a single module (e.g., `Shop.Admin`, `Shop.Viewer`)
- **User Roles** aggregate module roles from multiple modules (e.g., `Administrator` includes `Shop.Admin` + `System.Administrator`)
- **Access Rules** control CRUD rights on entities per module role
- **Microflow/Page Access** controls which module roles can execute/view specific elements
- **Project Security Level** determines enforcement: `off`, `prototype`, or `production`

## Syntax Reference

### Show Commands (Read-Only)

```sql
-- Project-wide security overview
show project security;

-- Module roles (all or filtered)
show module roles;
show module roles in MyModule;

-- User roles and demo users
show user roles;
show demo users;

-- Access on specific elements
show access on microflow MyModule.ProcessOrder;
show access on page MyModule.CustomerOverview;
show access on MyModule.Customer;

-- Full security matrix
show security matrix;
show security matrix in MyModule;
```

### Describe Commands

```sql
-- Describe individual roles and users (MDL output)
describe module role MyModule.Admin;
describe user role Administrator;
describe demo user 'demo_admin';
```

### Catalog Queries (SQL)

Security data is available in catalog tables for advanced querying. Use `refresh catalog full` to populate permissions and role mappings.

```sql
-- All permissions (entity, microflow, page, OData access)
select * from CATALOG.PERMISSIONS where ModuleRoleName = 'MyModule.Admin';

-- Filter by type
select ElementName, AccessType from CATALOG.PERMISSIONS
  where ElementType = 'ENTITY' and ModuleName = 'MyModule';

select ElementName from CATALOG.PERMISSIONS
  where ElementType = 'MICROFLOW' and AccessType = 'EXECUTE';

-- User role to module role mappings
select * from CATALOG.ROLE_MAPPINGS;
select ModuleRoleName from CATALOG.ROLE_MAPPINGS where UserRoleName = 'Administrator';

-- Which user roles have access to a module?
select distinct UserRoleName from CATALOG.ROLE_MAPPINGS where ModuleName = 'MyModule';

-- Describe catalog table schema
describe CATALOG.PERMISSIONS;
describe CATALOG.ROLE_MAPPINGS;
```

**Catalog tables:**
| Table | Contents | Build mode |
|-------|----------|------------|
| `CATALOG.PERMISSIONS` | Entity CRUD, microflow EXECUTE, page VIEW, OData ACCESS | `refresh catalog full` |
| `CATALOG.ROLE_MAPPINGS` | User role → module role assignments | `refresh catalog` |

### Module Roles

```sql
-- Create module roles
create module role MyModule.Admin description 'Full administrative access';
create module role MyModule.User;
create module role MyModule.Viewer description 'Read-only access';

-- Remove a module role
drop module role MyModule.Viewer;
```

### Microflow Access

```sql
-- Grant execute access (multiple roles supported)
grant execute on microflow MyModule.ACT_Customer_Create to MyModule.User, MyModule.Admin;

-- Revoke from specific roles
revoke execute on microflow MyModule.ACT_Customer_Create from MyModule.User;
```

### Nanoflow Access

```sql
-- Grant execute access (same syntax as microflows)
grant execute on nanoflow MyModule.NF_ValidateCart to MyModule.User, MyModule.Admin;

-- Revoke from specific roles
revoke execute on nanoflow MyModule.NF_ValidateCart from MyModule.User;

-- Show current access
show access on nanoflow MyModule.NF_ValidateCart;
```

> **Note:** Security roles persist through DROP+CREATE of the same nanoflow name within a session (by design, for refactor-in-place workflows).

### Page Access

```sql
-- Grant view access
grant view on page MyModule.Customer_Overview to MyModule.User, MyModule.Admin;

-- Revoke from specific roles
revoke view on page MyModule.Customer_Overview from MyModule.User;
```

### Entity Access (CRUD)

GRANT is **additive** — it merges with existing access, never removes permissions.

```sql
-- Full access (all CRUD + all members)
grant MyModule.Admin on MyModule.Customer (create, delete, read *, write *);

-- Read-only (all members)
grant MyModule.Viewer on MyModule.Customer (read *);

-- Selective member access
grant MyModule.User on MyModule.Customer (read (Name, Email), write (Email));

-- Additive: adds Phone to existing read access (Name, Email preserved)
grant MyModule.User on MyModule.Customer (read (Phone));

-- With XPath constraint
grant MyModule.User on MyModule.Order (read *, write *) where '[Status = ''Open'']';

-- Revoke entity access entirely
revoke MyModule.Viewer on MyModule.Customer;

-- Partial revoke: remove read on specific attribute
revoke MyModule.User on MyModule.Customer (read (Phone));

-- Partial revoke: downgrade write to read-only
revoke MyModule.User on MyModule.Customer (write (Email));

-- Partial revoke: remove structural permission
revoke MyModule.User on MyModule.Customer (delete);
```

#### Inherited members

Mendix inheritance is multi-table: a child adds attributes to its parent's, and
**all** the parent's members belong to the child. Grant them exactly like the
entity's own — `read *` / `write *` cover them too:

```sql
create persistent entity Docs.DocumentBase (
  DocName: String(200),
  Confidential: Boolean
);

create persistent entity Docs.Contract extends Docs.DocumentBase (
  ContractNumber: String(50)
);

-- DocName is inherited, ContractNumber is Contract's own — name both the same way
grant Docs.Viewer on Docs.Contract (read (DocName, ContractNumber));

-- Attachment inherits the file members from System.FileDocument
create persistent entity Docs.Attachment extends System.FileDocument (
  Category: String(50)
);
grant Docs.Viewer on Docs.Attachment (read (Category, "Name", Size));
```

An access rule must carry an entry for **every** member, own and inherited —
mxcli writes the ones you did not grant with rights `None`. Omitting them is
Mendix **CE0066** "Entity access is out of date", which masks the CE2729
"No read access to attribute" errors underneath until Studio Pro's *Update
security* is clicked.

A member name that matches nothing is now an error rather than a silent skip:

```
Error: entity Docs.Contract has no member(s) DocNam; grant only names members
of the entity or of an entity it inherits from
```

**Exception — user entities.** An entity extending `System.User` is a *user
entity*, and Mendix manages its inherited platform members (`Name`, `Password`,
`Blocked`, …). Those must **not** appear in the rule; listing them is CE0066.
Grant only the entity's own members — mxcli leaves the platform ones out
automatically:

```sql
create persistent entity Docs.Employee extends System.User (
  EmployeeNo: String(20)
);
grant Docs.Viewer on Docs.Employee (read (EmployeeNo));   -- not Name/Blocked
```

### User Roles

```sql
-- Create with module roles
create user role RegularUser (MyModule.User, OtherModule.Reader);

-- Create with manage all roles permission
create user role SuperAdmin (MyModule.Admin) manage all roles;

-- Add/remove module roles
alter user role RegularUser add module roles (MyModule.Viewer);
alter user role RegularUser remove module roles (MyModule.Viewer);

-- Remove user role
drop user role RegularUser;
```

### Project Security Settings

```sql
-- Set security level
alter project security level off;
alter project security level prototype;
alter project security level production;

-- Enable/disable demo users
alter project security demo users on;
alter project security demo users off;
```

### Demo Users

```sql
-- Create demo user (auto-detects entity that generalizes System.User)
create demo user 'demo_admin' password 'Admin123!' (Administrator, SuperAdmin);

-- Create demo user with explicit entity
create demo user 'demo_admin' password 'Admin123!' entity Administration.Account (Administrator, SuperAdmin);

-- Remove demo user
drop demo user 'demo_admin';
```

The ENTITY clause specifies which entity (generalizing `System.User`) to use. If omitted, it auto-detects the unique System.User subtype in the project. If multiple subtypes exist, you must specify ENTITY explicitly.

## Starlark Lint Rule APIs

Security data is available in Starlark lint rules (`.star` files):

| Function | Returns | Description |
|----------|---------|-------------|
| `permissions()` | list of permission | All permissions across all element types |
| `permissions_for(qn)` | list of permission | Permissions for a specific entity |
| `user_roles()` | list of user_role | User roles with module role assignments |
| `module_roles()` | list of module_role | Distinct module roles |
| `role_mappings()` | list of role_mapping | User role → module role mappings |
| `project_security()` | struct or None | Security level, guest access, password policy |

See `write-lint-rules.md` for object property details.

## Common Workflow: Setting Up Module Security

A typical security setup follows this order:

```sql
-- 1. Create module roles
create module role Shop.User description 'Regular user access';
create module role Shop.Admin description 'Administrative access';
create module role Shop.Viewer description 'Read-only access';

-- 2. Grant entity access
grant Shop.Admin on Shop.Customer (create, delete, read *, write *);
grant Shop.User on Shop.Customer (read (Name, Email), write (Email));
grant Shop.Viewer on Shop.Customer (read *);

-- 3. Grant microflow access
grant execute on microflow Shop.ACT_Customer_Create to Shop.User, Shop.Admin;
grant execute on microflow Shop.ACT_Customer_Delete to Shop.Admin;

-- 4. Grant page access
grant view on page Shop.Customer_Overview to Shop.User, Shop.Admin, Shop.Viewer;
grant view on page Shop.Customer_Edit to Shop.User, Shop.Admin;

-- 5. Create user roles (project-level)
create user role AppUser (Shop.User);
create user role AppAdmin (Shop.Admin) manage all roles;

-- 6. Verify
show security matrix in Shop;
describe user role AppAdmin;
```

### What counts as a member of an entity

An access rule has to cover **every** member of the entity, or Mendix fails the
build with `CE0066 "Entity access is out of date"` — a partially covered rule is
worse than no rule at all. `read *` / `write *` cover them all, including the
ones that are easy to overlook:

| Member | Named in a GRANT as | Notes |
|--------|--------------------|-------|
| Attributes (own and inherited) | the attribute name | see "Inherited members" above |
| Association, `OWNER Default` | the association name | **on the FROM entity only** — adding it to the TO side is itself a CE0066 |
| Association, `OWNER Both` | the association name | on **both** entities — each end owns it |
| `createdDate` / `changedDate` | the member name | covered by the rule's **default** only; Mendix stores no per-member access for them |
| `owner` / `changedBy` | — | emitted automatically as `System.owner` / `System.changedBy` |

Audit members are the one case where naming a member cannot change its rights:
`grant R on M.E (write *, read (createdDate))` is refused, because Mendix has no
member access to write for it and a rule that carries one fails CE0066. Let the
rule's default cover it, or change the default.

## Common Mistakes

1. **Creating module roles before the module exists** — `create module` must come first
2. **Referencing non-existent roles in GRANT** — create the module role before granting access
3. **Forgetting qualified names** — roles use `Module.Role` format in GRANT/REVOKE
4. **User roles without System module roles** — in Production security, user roles need at least one System module role (CE0156)
5. **Entity access without proper member rights** — use `read *` for all members or `read (Attr1, Attr2)` for specific ones

## Validation

After setting up security, verify with:
```bash
# check security matrix
mxcli -p app.mpr -c "show security matrix in MyModule"

# Validate with Mendix
~/.mxcli/mxbuild/*/modeler/mx check app.mpr
```
