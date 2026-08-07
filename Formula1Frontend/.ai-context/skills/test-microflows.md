# Test Microflows Skill

This skill guides you through writing and running MDL-based microflow tests using `mxcli test`.

## When to Use This Skill

Use this when:
- The user asks to test microflow logic (not UI/pages)
- The user wants to verify that microflows return correct values
- The user wants to validate entity creation, updates, or control flow
- You have generated MDL microflows and want to verify they work at runtime
- The user asks for unit tests or integration tests on business logic

For **UI/page testing** (widget rendering, form interactions, browser tests), see the `test-app` skill instead.

## Prerequisites

- Mendix project with microflows to test
- A way to run the app — **either** of:
  - `--local` (no Docker): mxcli boots the runtime itself, the same way
    `mxcli run --local` does. This is the only option in a container without a
    Docker daemon, which includes Claude Code web sessions.
  - Docker: stack initialized (`mxcli docker init -p app.mpr`) and the app
    buildable (`mxcli docker build -p app.mpr`).

```bash
mxcli test tests/ -p app.mpr --local     # no daemon needed
mxcli test tests/ -p app.mpr             # Docker
```

`--local` uses its own ports (app 8081, admin 8091) and its own
`<project>_test` database, so a `mxcli run --local` dev loop can keep serving the
same project while the tests run — the tests never write into the database you
are looking at in the browser. The database is created on first use.

---

## Test File Formats

### `.test.mdl` — Pure MDL Tests

Test blocks separated by `/`, each with a javadoc comment containing test annotations:

```sql
/**
 * @test String concatenation
 * @expect $result = 'John Doe'
 */
$result = call microflow MyModule.ConcatNames(
  FirstName = 'John', LastName = 'Doe'
);
/

/**
 * @test Arithmetic operation
 * @expect $result = 50
 */
$result = call microflow MyModule.Multiply(A = 10, B = 5);
/
```

### `.test.md` — Markdown Specification

Tests embedded in documentation as `mdl-test` fenced code blocks:

~~~markdown
# MyModule Specification

## string Operations

The ConcatNames microflow joins first and last name.

```mdl-test
/** @expect $result = 'John Doe' */
$result = call microflow MyModule.ConcatNames(
  FirstName = 'John', LastName = 'Doe'
);
```
~~~

The markdown format turns your tests into living documentation.

---

## Annotations

| Tag | Purpose | Example |
|-----|---------|---------|
| `@test` | Test name (required) | `@test string concatenation` |
| `@expect` | Assert variable value | `@expect $result = 'John Doe'` |
| `@expect` | Assert entity attribute | `@expect $product/Name = 'TestProduct'` |
| `@verify` | OQL post-condition | `@verify select count(*) from Mod.E where Code = 'X' = 1` |
| `@throws` | Expect error | `@throws 'validation failed'` |
| `@cleanup` | Rollback strategy | `@cleanup rollback` (default) or `@cleanup none` |

---

## Running Tests

```bash
# run tests from a file
mxcli test tests/microflows.test.mdl -p app.mpr

# run all tests in a directory
mxcli test tests/ -p app.mpr

# list tests without executing
mxcli test tests/ -p app.mpr --list

# Output JUnit xml for CI
mxcli test tests/ -p app.mpr --junit results.xml

# Skip build (reuse existing deployment)
mxcli test tests/ -p app.mpr --skip-build

# Verbose output (show all runtime logs)
mxcli test tests/ -p app.mpr --verbose
```

---

## How It Works

There are two mechanisms. `--local` uses the **test endpoint**; Docker uses the
older **after-startup microflow** pattern.

### `--local`: the test endpoint

1. Parses test files and extracts test blocks with annotations
2. Records the project's current after-startup microflow, and whether an `MxTest`
   module already exists
3. Generates **one `MxTest.Test_<id>` microflow per test**, plus a Java action
   that registers an HTTP endpoint, and points after-startup at a microflow whose
   only job is to call it — **no test runs during startup**
4. Builds and boots the app once
5. Invokes each test by name over HTTP; each returns its own verdict in the
   response
6. Restores the original after-startup setting and removes everything generated
7. Outputs results (console, JUnit XML)

Two consequences worth knowing when reading a failing run:

- **A test that throws fails only itself.** It is reported as `ERROR` with the
  root-cause message, and the next test still runs. Under the after-startup
  mechanism an uncaught error ends the whole flow — and because that flow *is*
  the startup action, it also fails the boot.
- **Results are returned, not scraped**, so a test cannot be lost to log
  buffering or a runtime that stopped echoing to the console.

Each test is a separate microflow with its own variable scope, so `$result` in
one test never collides with `$result` in another.

#### `--watch`: keep the runtime warm

```bash
mxcli test tests/ -p app.mpr --local --watch
```

The first run pays the cold boot; after that the runtime and the build server
stay up, and the suite re-runs on every change — to a test file **or** to the
project's model. Measured on an 11.13.0 app:

| | |
|---|---|
| First run (cold boot) | ~30s |
| Edit a test → verdict on screen | **~2s** |
| Edit a microflow → verdict on screen | **~2s** |
| The tests themselves | 20–70ms |

Editing a microflow and seeing straight away whether it still passes is the loop
this exists for. Ctrl-C stops watching and restores the project — the shutdown
prints `project restored` when it has.

Adding, editing and deleting tests all work mid-session: the suite is re-parsed
on every change, and a deleted test's microflow is dropped rather than left
behind reporting a stale pass.

`--watch` requires `--local`. The Docker and `--legacy-runner` paths can only
re-run tests by restarting, which is the thing being avoided.

#### `--attach`: no boot at all

If you already have the app running, tests can skip the boot entirely. The dev
loop has to opt into hosting the endpoint, because the handler is registered by
the after-startup microflow and so cannot be added to an app that is already up:

```bash
# terminal 1 — the app you are working in
mxcli run --local --test-endpoint -p app.mpr

# terminal 2 — runs in ~2s, no boot, repeatable
mxcli test tests/ -p app.mpr --attach
mxcli test tests/ -p app.mpr --attach --watch    # ...and re-run on every change
```

The hosting app chains your project's own after-startup microflow rather than
displacing it, so it still boots normally. The endpoint and the handshake file
(`.mxcli/test-endpoint.json`, mode 0600) are removed when the app stops.

Three things to know before reaching for it:

- **Tests run against the running app's database**, not a scratch one, so they
  can leave data behind in the app you are looking at. `--local` uses a separate
  `<project>_test` database; `--attach` does not.
- **An attach only owns its own test microflows.** The endpoint and the
  after-startup setting belong to the app hosting them, and cleanup never
  touches them.
- **A change needing a runtime restart is refused** — a new entity or
  association. That runtime belongs to the other process. Restart it, or drop
  `--attach`.

| | Boot | Database | Owns the runtime |
|---|---|---|---|
| `--local` | ~30s each run | `<project>_test` | yes |
| `--local --watch` | ~30s once, then ~2s | `<project>_test` | yes |
| `--attach` | none | the running app's | no |

#### Security of the endpoint

It executes microflows under a system context, so it is gated four ways:

| Guard | Behaviour |
|---|---|
| No `MXCLI_TEST_TOKEN` in the runtime's environment | The handler is **not registered at all** (404) |
| Missing or wrong `X-MxTest-Token` header | 401, compared in constant time |
| Non-loopback caller | 403 |
| `mf` outside `MxTest.Test_*` | 403 — it is not a general microflow-invocation API |

The token is generated per run and reaches the runtime through its **environment**,
never written into the project. Combined with fail-closed registration, that means
a project which kept the `MxTest` module through a failed cleanup exposes nothing
when deployed anywhere else.

### Docker: the after-startup microflow

1. Parses test files and extracts test blocks with annotations
2. Records the project's current after-startup microflow, and whether an `MxTest`
   module already exists
3. Generates a single `MxTest.TestRunner` microflow containing every test, and
   points after-startup at it
4. Builds the project and restarts the container
5. Captures structured `MXTEST:` log lines for pass/fail
6. Restores the original after-startup setting and removes the generated runner —
   the whole `MxTest` module when the runner created it, otherwise just the
   `TestRunner` microflow
7. Outputs results (console, JUnit XML)

### Both mechanisms

The project's **Security Level is not modified**. The after-startup microflow runs
in an administrative context and is not subject to it, and forcing it off breaks
projects whose published REST/OData services use custom authentication. If a
cleanup step fails the run reports an error and names what was left changed —
the project is modified, so it must not read as a clean pass.

---

## Writing Good Tests

### Test a Single Behavior

Each test block should test one thing:

```sql
/**
 * @test Discount applied for orders over 100
 * @expect $result = 90.0
 */
$result = call microflow Sales.CalculateDiscount(OrderTotal = 100.0);
/
```

### Test Multiple Scenarios

Use separate blocks for different input values:

```sql
/**
 * @test Negative value returns 'negative'
 * @expect $result = 'negative'
 */
$result = call microflow MyModule.Classify(value = -5);
/

/**
 * @test Zero returns 'zero'
 * @expect $result = 'zero'
 */
$result = call microflow MyModule.Classify(value = 0);
/

/**
 * @test Positive value returns 'positive'
 * @expect $result = 'positive'
 */
$result = call microflow MyModule.Classify(value = 42);
/
```

### Test Entity Operations

Tests can create, modify, and verify entities:

```sql
/**
 * @test Create and update product
 * @expect $updated = true
 */
$product = call microflow Sales.CreateProduct(
  Name = 'Widget', Code = 'W-001'
);
commit $product;
$updated = call microflow Sales.UpdateProduct(
  Product = $product, NewName = 'Super Widget'
);
/
```

### Test Error Handling

Use `@throws` to verify that a microflow raises an error:

```sql
/**
 * @test Invalid input throws validation error
 * @throws 'Validation failed'
 */
call microflow Sales.ValidateOrder(Total = -1);
/
```

---

## Test File Organization

Recommended structure:

```
tests/
├── microflows.test.mdl      # business logic tests
├── entities.test.mdl         # entity CRUD tests
├── validation.test.mdl       # validation tests
└── specs/
    └── sales-module.test.md  # Markdown specification
```

---

## Interpreting Failures

| Failure | Cause | Fix |
|---------|-------|-----|
| `Exception during execution` | Microflow threw a runtime error | Check BSON structure, entity references, attribute types |
| `Expected $result = 'X' but got 'Y'` | Wrong return value | Fix microflow logic |
| `Test was not executed` | Runtime crashed before reaching it | Check earlier test failures or runtime logs |
| `after startup microflow should return a boolean` | Generated runner has wrong return type | Report as bug in mxcli |

---

## CI Integration

Use `--junit` to produce JUnit XML for CI systems:

```bash
mxcli test tests/ -p app.mpr --junit test-results.xml
```

The JUnit XML works with GitHub Actions, Jenkins, Azure DevOps, GitLab CI, etc.

```yaml
# GitHub actions example
- name: run microflow tests
  run: mxcli test tests/ -p app.mpr --junit test-results.xml
- name: publish test results
  uses: dorny/test-reporter@v1
  with:
    name: microflow Tests
    path: test-results.xml
    reporter: java-junit
```

## Related Skills

- [test-app.md](test-app.md) — Playwright UI tests (pages, widgets, browser interactions)
- [write-microflows.md](write-microflows.md) — Microflow syntax reference
- [docker-workflow.md](docker-workflow.md) — Docker build and runtime workflow
- [verify-with-oql.md](verify-with-oql.md) — OQL queries for data verification
