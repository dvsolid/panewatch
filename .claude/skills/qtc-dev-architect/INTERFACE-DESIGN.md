# Interface Design

Interfaces communicate everything a caller must know to use the module. Not just the type signature — also invariants, error modes, ordering constraints, lifecycle, and configuration.

## Principles

### 1. Narrow the interface

Every method, every parameter, every error mode costs the caller cognitive load. Add only what the caller actually needs.

### 2. Express invariants in types when possible

A function that takes a `NonEmptyList<Order>` is better than one that takes `List<Order>` and throws on empty. The first is enforced by the compiler; the second is enforced by reading the docs.

### 3. Error modes are part of the interface

If a function can throw three different exceptions, the caller has to know all three. List them. Better: collapse them or let one of them not happen.

### 4. Side effects belong in the interface

If a function writes to a file, sends a request, mutates a shared cache — that's part of the contract, not an implementation detail.

### 5. Stable interfaces tolerate internal change

If renaming a private helper forces an interface change, the interface was leaking implementation. Push more behind the seam.

## Testability follows from good interfaces

A deep module with a narrow interface is **inherently testable** — you can exercise its behavior through the public surface without mocking internals.

If you find yourself wanting to mock collaborators of a module under test, ask: should those collaborators be hidden behind the module's seam? Often yes.

## Checklist when sketching

- [ ] Can a new caller use this module without reading internals?
- [ ] Are all error modes listed?
- [ ] Are side effects explicit?
- [ ] Does the interface name match a glossary term?
- [ ] Is the module **deep** by the deletion test?
