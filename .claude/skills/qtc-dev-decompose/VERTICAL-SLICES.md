# Vertical Slices (Tracer Bullets)

A **tracer bullet** is a thin vertical slice that proves the path through all layers. It's demoable on its own — even if the surrounding system isn't done.

## Vertical vs horizontal

```
HORIZONTAL (bad):
  Slice 1: build all the data models
  Slice 2: build all the APIs
  Slice 3: build all the UI
  -> Each slice on its own is dead code until the others land.

VERTICAL (good):
  Slice 1: one user can create one record end-to-end (1 model, 1 endpoint, 1 page)
  Slice 2: same flow for a second record type
  Slice 3: list view
  -> Each slice on its own is demoable.
```

## Rules

1. **End-to-end** — schema, API, UI (or CLI), test, all in one slice.
2. **Demoable** — when the slice is done, a user can do *something* useful.
3. **Narrow** — slice does one thing. If the description has "and," consider splitting.
4. **Independently mergeable** — completing a slice doesn't break unrelated work.

## Sizing

A good slice is ~½ day for a focused engineer. Smaller is better than larger:

- A slice that takes 2 days is two slices that haven't been split yet.
- A slice that takes 30 minutes is probably correctly sized (assuming it's vertical).

## Dependencies

Some slices genuinely depend on others (the second user can't sign up before the first table exists). Capture that in `depends_on`. But:

- Don't manufacture dependencies for ordering preference — if two slices can land in either order, mark them independent.
- Never circular. If A depends on B and B depends on A, you have two slices that should be one (or three slices, with the shared part extracted).

## Anti-patterns

- **Horizontal phases** masquerading as slices — "Phase 1: backend; Phase 2: frontend."
- **All-up integration test** as the final slice — the integration should fall out of the other slices being demoable.
- **Refactoring slices** before any behavior is built — defer refactoring until you have concrete code to refactor.
