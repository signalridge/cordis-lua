lua := env("LUA", "lua")

# run the test suite in both spawn modes (and with host.capture)
test *args:
    {{lua}} test/run.lua {{args}}
    {{lua}} test/run.lua --eager {{args}}
    {{lua}} test/run.lua --contexts {{args}}
    {{lua}} test/run.lua --eager --contexts {{args}}

fmt:
    stylua lua test

lint:
    stylua --check lua test
    for f in $(find lua test -name '*.lua'); do luac -p "$f" || exit 1; done
    {{lua}} test/kit/port_check.lua

check: lint test
