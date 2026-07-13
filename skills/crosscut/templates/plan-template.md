---
repo: <repo-name-from-config>
status: draft
depends_on: []
feature_id: <optional shared id for a cross-repo feature>
---
# <Feature / task title>

**Goal:** <one sentence>

**Context:** <affected modules / data stores / queues / external services; links to
prior decisions or docs>

### Task 1: <first step>

<What to do. Code-first. Exact files and changes. Reuse existing utilities/services.
Code comments in English. No forward references to later tasks.>

### Task 2: <next step>

<...>

### Task N: Tests

<If tests are needed, as a dedicated task section: the executor runs only
`### Task N:` sections; plain `## ...` prose is not executed. Positive/negative
cases, boundary values. Do not introduce a new test framework.>
