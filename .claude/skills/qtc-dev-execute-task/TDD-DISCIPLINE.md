# TDD Discipline

The rules that make TDD work, distilled.

## Tests verify behavior through public interfaces, not implementation

Good test: "user can check out with a valid cart" — exercises the checkout module's public API end-to-end.

Bad test: "checkout module called payment processor with these arguments" — couples to implementation. The test breaks when you refactor without behavior changing.

**Warning sign**: tests fail when you rename an internal function, but no behavior changed -> those tests are testing implementation, not behavior.

## Anti-pattern: horizontal slicing

Do **not** write all tests first, then all implementation. That produces:

- Tests written in bulk that test *imagined* behavior, not *actual* behavior.
- Tests insensitive to real changes — pass when behavior breaks, fail when behavior is fine.

Correct approach: **vertical slices via tracer bullets**. One test -> one impl -> repeat.

## The cycle

```
RED:    write test for behavior N -> it fails for the right reason
GREEN:  minimal code so test passes; run all tests; everything still green
REPEAT: behavior N+1
```

## Rules per cycle

- One test at a time.
- Only enough code to pass the current test.
- Don't anticipate future tests.
- Tests focus on observable behavior, not internals.
- Never refactor while RED — get to GREEN first.

## Failure recognition

When a test fails after GREEN for an unrelated reason:

1. Stop. Don't reflexively retry or fiddle.
2. Read the failure carefully. Is it a real regression, or a flaky test?
3. If real: this is a finding. Investigate the root cause before continuing.
4. If flaky: file it (failure-patterns.md), then stabilize the test before continuing.

## Mocking

Mock at the boundary of the system under test, not inside it.

- OK: Mock external HTTP, databases, filesystems, time.
- NOT OK: Mock collaborators of the module under test that are also under test.
- NOT OK: Mock to test that a function "called another function with these arguments" — that's testing implementation.

## What "minimal implementation" means

Write the smallest amount of code that makes the test pass. If returning a hardcoded value passes the test, return a hardcoded value. The next test will force you to generalize. This is not laziness; it's discipline against speculative complexity.
