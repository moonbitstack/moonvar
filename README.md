# CHANGE-ME

One sentence saying what this is.

```moonbit
@lib.greet("moonbit")
```

Run `moon run examples/tour` for the whole surface in one go.

## Starting from this template

1. `gh repo create moonbitstack/<name> --template moonbitstack/moonkit --public`
2. Replace `CHANGE-ME` everywhere: `moon.mod` (name and repository), the two
   `moon.pkg` files that import `lib`, and this file's title.
3. Delete `bin/` if the repository ships no binary; delete `lib/` if it ships
   only a binary. Most repositories here keep `lib/` and rename it to whatever
   the package actually is — `base64/`, `sha2/`, `jwt/` — because a package is
   named after what it does, not after its role.
4. Fill in `keywords` and `description` in `moon.mod`. The description is what
   mooncakes shows, so it says what the package is and what it is not.
5. Write the specification link into every `moon.pkg`.

## What is here and what is not

| Carried | Why |
|:--|:--|
| `.github/workflows/` | GitHub does not inherit workflows; every repository needs its own copy |
| `moon.mod`, `lib/`, `bin/`, `examples/tour/` | The module layout, with the library and the binary separated the way cargo separates them |
| `.gitignore`, `.moonignore` | The second one exists because `.gitignore`'s `!.git*` would otherwise pull the whole object database into a published tarball |
| `LICENSE` | Apache-2.0, the same across the organisation |

**Issue and pull-request templates are not here.** The organisation's `.github`
repository supplies them to every repository that has none of its own; a copy
here would shadow that one and then drift from it. A repository adds its own
only when it needs something the organisation's does not cover.

## The gate

Every commit passes this, with each exit code seen to be zero:

```bash
moon clean && moon fmt && moon check --target all --deny-warn \
  && moon build --target all && moon test --target all
```

Before a release, `moon info --target all && git diff --exit-code` as well: the
generated interface is checked in, and a difference means the interface moved
without anyone saying so.

## Releasing

Push a signed tag `v<version>`. `release.yml` runs the tests first and publishes
only if they pass and the organisation variable `MOONCAKES_PUBLISH` is `true`.
The major version stays at 0.

## Licence

Apache-2.0.
