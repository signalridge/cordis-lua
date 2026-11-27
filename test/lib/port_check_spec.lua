-- Library-own tests: test/kit/port_check.lua case matching.
local P = require("kit.port_check")

describe("port_check", function()
  it("finds a case whose name follows it( on the same line", function()
    expect(P.hasCase('it("dispose manually", function()', "dispose manually")).to.equal(true)
    expect(P.hasCase("it('dispose manually', function()", "dispose manually")).to.equal(true)
  end)

  it("finds a case wrapped over several lines by stylua", function()
    local spec = 'describe("x", function()\n  it(\n    "async return 1",\n    withTimers(function(root)\n'
    expect(P.hasCase(spec, "async return 1")).to.equal(true)
  end)

  it("matches names literally and only after it(", function()
    expect(P.hasCase('it("a.b (c)", f)', "a.b (c)")).to.equal(true)
    expect(P.hasCase('it("axb (c)", f)', "a.b (c)")).to.equal(false)
    expect(P.hasCase('fit("name", f)', "name")).to.equal(false)
    expect(P.hasCase('describe("name", f)', "name")).to.equal(false)
    expect(P.hasCase('it("name with %s", f)', "name with %s")).to.equal(true)
    expect(P.hasCase('it("say \\"hi\\"", f)', 'say "hi"')).to.equal(true)
    expect(P.hasCase(nil, "name")).to.equal(false)
  end)

  it("counts multiple occurrences of the same case name", function()
    local spec = table.concat({
      'it("basic support", function() end)',
      "it('basic support', function() end)",
      'it(\n  "basic support",\n  function() end\n)',
      'fit("basic support", function() end)',
      'describe("basic support", function() end)',
    }, "\n")
    expect(P.countCases(spec, "basic support")).to.equal(3)
    expect(P.countCases(spec, "missing")).to.equal(0)
    expect(P.countCases(nil, "basic support")).to.equal(0)
  end)

  it("rejects todo status rows in port-status tables", function()
    local status = table.concat({
      "| core/tests/a.spec.ts:1 | done case | ported |",
      "| core/tests/a.spec.ts:2 | pending case | todo |",
    }, "\n")
    local errs = P.checkStatus(status, function()
      return 'it("done case", function() end)'
    end, { core = 2 })
    expect(#errs).to.equal(1)
    expect(errs[1]:find("todo", 1, true) ~= nil).to.equal(true)
  end)

  it("fails when a spec file has fewer occurrences than duplicate ported rows", function()
    local status = table.concat({
      "| timer/tests/index.spec.ts:22 | basic support | ported |",
      "| timer/tests/index.spec.ts:59 | basic support | ported |",
      "| timer/tests/index.spec.ts:257 | basic support | ported |",
      "| timer/tests/index.spec.ts:387 | basic support | ported |",
    }, "\n")
    local three = table.concat({
      'it("basic support", f)',
      'it("basic support", f)',
      'it("basic support", f)',
    }, "\n")
    local errs = P.checkStatus(status, function()
      return three
    end, { timer = 4 })
    expect(#errs).to.equal(1)
    expect(errs[1]:find("basic support", 1, true) ~= nil).to.equal(true)

    local four = three .. '\nit("basic support", f)'
    local okErrs = P.checkStatus(status, function()
      return four
    end, { timer = 4 })
    expect(okErrs).to.deep.equal({})
  end)
end)
