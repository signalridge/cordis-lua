# Contributing to cordis-lua

Thank you for contributing to `cordis-lua`.

## Requirements

- Lua 5.5 (`mise install` uses `mise.toml`)
- `stylua` for formatting checks

## Development & Checks

Run the full verification suite before opening a pull request:

```sh
just check
```

This runs:
- `stylua --check lua test`
- `luac -p` syntax checks across `lua/` and `test/`
- `lua test/kit/port_check.lua` parity checks against `docs/port-status.md`
- All four runtime test modes (`deferred`, `--eager`, `--contexts`, `--eager --contexts`)

## Guidelines

- Keep `lua/cordis/*.lua` dependency-free and compatible with Lua 5.5 and embedder hosts (`mlua`, custom coroutine schedulers).
- Update `docs/deviations.md` and `docs/port-status.md` alongside any behavioral or spec-parity changes.
- Preserve existing upstream attribution headers and follow the formatting in `stylua.toml`.
