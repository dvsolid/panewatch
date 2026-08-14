# Deep Modules

From John Ousterhout's *A Philosophy of Software Design*.

A **deep module** has a small interface and lots of implementation behind it.

```
┌─────────────────────┐
│   Small Interface   │  <- Few methods, simple params, few error modes
├─────────────────────┤
│                     │
│  Deep Implementation│  <- Complex logic hidden behind the seam
│                     │
└─────────────────────┘
```

A **shallow module** has an interface nearly as complex as the implementation. It's a pass-through — change its callers and you change it. **Reject shallow modules.**

## The deletion test

For each candidate module, imagine deleting it:

- **Complexity reappears across many callers** → the module was earning its keep. Keep it.
- **Complexity vanishes** → the module was a pass-through. Reject it.

Most "service" and "manager" layers fail the deletion test. So do most "utility" modules that just rename existing functions.

## Symptoms of shallow modules

- The interface has roughly the same number of concepts as the implementation.
- Most methods do one thing each, forwarding to a single underlying call.
- Tests for the module are mostly "did it call the dependency correctly?" — testing collaborators, not behavior.
- Refactoring the implementation forces the interface to change too.

## Symptoms of deep modules

- Many callers, one interface.
- The implementation hides a non-trivial algorithm, state machine, or invariant.
- The interface stays stable across multiple internal refactors.
- Tests exercise externally observable behavior through the public surface.

## When designing interfaces, ask:

- Can I reduce the number of methods?
- Can I simplify the parameters?
- Can I hide more state behind the seam?
- Can I express invariants the caller would otherwise need to enforce?

## When in doubt: defer the module.

It's easier to extract a deep module from concrete code later than to design one up front. If you can't show the deletion-test reasoning convincingly, write the inline code and revisit.
