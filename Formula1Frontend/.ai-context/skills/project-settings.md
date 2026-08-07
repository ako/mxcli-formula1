# Project Settings

## When to Use This Skill

Use this skill when the user wants to:
- Configure database connections (PostgreSQL, SQLServer, etc.)
- Set up Kafka endpoints or other constant overrides
- Change the after-startup or before-shutdown microflows
- Modify hash algorithms, Java versions, or rounding modes
- View or modify language settings
- Configure workflow settings (user entity, parallelism)

## Commands

### View Settings

```sql
-- Overview table of all settings parts
show settings;

-- Full MDL output (round-trippable ALTER SETTINGS statements)
describe settings;
```

### Modify Model Settings

```sql
alter settings model AfterStartupMicroflow = 'Module.MF_Startup';  -- must return Boolean (CE0142)
alter settings model BeforeShutdownMicroflow = 'Module.MF_Shutdown';
alter settings model HealthCheckMicroflow = 'Module.MF_HealthCheck';
alter settings model HashAlgorithm = 'BCrypt';
alter settings model BcryptCost = 12;
alter settings model JavaVersion = 'Java21';  -- or '21'; see note below
alter settings model RoundingMode = 'HalfUp';
alter settings model AllowUserMultipleSessions = true;
alter settings model ScheduledEventTimeZoneCode = 'Etc/UTC';
```

**JavaVersion spelling.** Mendix renamed this property between versions: up to 11.6
it stores `JavaVersion` = `'Java21'`, from 11.12 it stores `JavaMajorVersion` =
`'21'`. Write either spelling — mxcli reads which one the project uses and stores
the value in that dialect. Getting this wrong is not a cosmetic difference: 11.12
parses the bare major and rejects the project outright with
`ArgumentOutOfRangeException: majorVersion is an unsupported value: Java21`.
`describe settings` always emits the project's own spelling, so its output replays
cleanly.

### Modify Configuration Settings

```sql
-- Full database configuration
alter settings configuration 'Default'
  DatabaseType = 'PostgreSql',
  DatabaseUrl = 'localhost:5432',
  DatabaseName = 'mydb',
  DatabaseUserName = 'mendix',
  DatabasePassword = 'mendix',
  HttpPortNumber = 8080,
  ServerPortNumber = 8090;

-- Update a single field
alter settings configuration 'Default'
  DatabaseUrl = 'newhost:5432';
```

`HttpPortNumber`, `ServerPortNumber`, `BcryptCost`, `DefaultTaskParallelism` and
`WorkflowEngineParallelism` are Integer-typed, and `AllowUserMultipleSessions` is
Boolean. An unparseable value is rejected by `mxcli check` (MDL-SET01 / MDL-SET02)
and by the write itself — it is no longer silently ignored. Quoted numbers are
fine: `HttpPortNumber = '8080'` and `HttpPortNumber = 8080` are equivalent.

### Constant Overrides

```sql
-- View constant values across all configurations
show constant values;
show constant values in MyModule;    -- Filter by module

-- Override a constant value in a configuration
alter settings constant 'BusinessEvents.ServerUrl' value 'kafka:9092'
  in configuration 'Default';

-- Without IN CONFIGURATION (uses first configuration)
alter settings constant 'MyModule.ApiKey' value 'abc123';

-- Remove a constant override (reset to default)
alter settings drop constant 'MyModule.ApiKey' in configuration 'Default';
```

#### Shared vs private values

A constant override's value is either **shared** — stored in the model and therefore
in version control, where every developer gets it — or **private**, stored on the
developer's own workstation and deliberately kept out of the repository. Development
API tokens are the usual reason to make one private.

MDL **preserves that choice but never changes it**. The two statements above operate
on shared values only:

- `show constant values` reports a private override as `(private)` rather than a blank
  cell — the value is not in the project, so mxcli cannot show it.
- `describe settings` reports a private override as a comment, not as a re-executable
  `alter settings constant` line — replaying that line would publish into the shared
  model a value the developer chose to keep local.
- `alter settings constant ... value ...` on a private override is **refused**, with a
  pointer to change it in Studio Pro first. Setting a value would convert it to a
  shared one and break the developer's local binding.
- `alter settings drop constant ...` **is** allowed: it removes the whole override,
  private marker included, which is what was asked for.

### Create / Drop Configurations

```sql
-- Create a new server configuration
create configuration 'Staging';

-- Create with properties
create configuration 'Production'
  DatabaseType = 'PostgreSql',
  DatabaseUrl = 'prod-db:5432',
  HttpPortNumber = 8080;

-- Drop a configuration
drop configuration 'Staging';
```

`DatabaseType` must name a Mendix database type — `Db2`, `Hsqldb`, `MySql`,
`Oracle`, `PostgreSql`, `SapHana` or `SqlServer` — matched case-insensitively and
stored in that spelling. Any other value is rejected; a configuration stored with
one Mendix does not recognise cannot be opened in Studio Pro.

### Language and Workflow Settings

```sql
alter settings LANGUAGE DefaultLanguageCode = 'en_US';

alter settings workflows
  UserEntity = 'System.User',
  DefaultTaskParallelism = 3;
```

## Common Patterns

### PostgreSQL Configuration
```sql
alter settings configuration 'Default'
  DatabaseType = 'PostgreSql',
  DatabaseUrl = 'localhost:5432',
  DatabaseName = 'myapp',
  DatabaseUserName = 'mendix',
  DatabasePassword = 'mendix',
  HttpPortNumber = 8080;
```

### SQL Server Configuration
```sql
alter settings configuration 'Default'
  DatabaseType = 'SqlServer',
  DatabaseUrl = 'localhost:1433',
  DatabaseName = 'myapp',
  DatabaseUserName = 'sa',
  DatabasePassword = 'MyPassword',
  HttpPortNumber = 8080;
```

## Checklist

- [ ] Always run `show settings` or `describe settings` first to see current values
- [ ] Verify changes after modification with `show settings`
- [ ] There is always exactly one ProjectSettings document; it cannot be created or deleted
- [ ] Model setting key names are case-sensitive (e.g., `JavaVersion`, not `javaversion`)
- [ ] Configuration names are case-insensitive (e.g., `'default'` matches `'default'`)
- [ ] Integer / Boolean settings must parse — `mxcli check` reports MDL-SET01 / MDL-SET02 before the write
