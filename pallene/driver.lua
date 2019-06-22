local c_compiler = require "pallene.c_compiler"
local checker = require "pallene.checker"
local coder = require "pallene.coder"
local parser = require "pallene.parser"
local scope_analysis = require "pallene.scope_analysis"
local util = require "pallene.util"

local driver = {}

local function step_index(steps, name)
    for i, step in ipairs(steps) do
        if name == step.name then
            return i
        end
    end
    error("invalid step name " .. name)
end

local ast_passes = {
    { name = "scope_analysis", f = scope_analysis.bind_names },
    { name = "checker",        f = checker.check },
}

driver.last_ast_pass = ast_passes[#ast_passes].name

local function compile_pallene_to_ast(pallene_filename, stop_after)
    local err, errs

    local input
    input, err = util.get_file_contents(pallene_filename)
    if not input then return false, {err} end

    local prog_ast
    prog_ast, errs = parser.parse(pallene_filename, input)
    if stop_after == "parser" or not prog_ast then return prog_ast, errs end

    local stop_i = step_index(ast_passes, stop_after)

    for i = 1, stop_i do
        local pass = ast_passes[i]
        prog_ast, errs = pass.f(prog_ast)
        if not prog_ast then break end
    end

    return prog_ast, errs
end

--
-- Emit C code, and save it to a file
--
local function compile_ast_to_c(prog_ast, c_filename, mod_name)
    local ok, err, errs

    local c_code
    c_code, errs = coder.generate(prog_ast, mod_name)
    if not c_code then return c_code, errs end

    ok, err = util.set_file_contents(c_filename, c_code)
    if not ok then return ok, {err} end

    return true, {}
end

local function compile_pallene_to_c(pallene_filename, c_filename, mod_name)
    local ok, errs

    local prog_ast
    prog_ast, errs = compile_pallene_to_ast(pallene_filename,
        driver.last_ast_pass)
    if not prog_ast then return false, errs end

    ok, errs = compile_ast_to_c(prog_ast, c_filename, mod_name)
    if not ok then return false, errs end

    return true, {}
end

local compiler_steps = {
    { name = "pln", f = compile_pallene_to_c },
    { name = "c",   f = c_compiler.compile_c_to_s },
    { name = "s",   f = c_compiler.compile_s_to_o },
    { name = "o",   f = c_compiler.compile_o_to_so},
    { name = "so",  f = false },
}

local function check_source_filename(argv0, file_name, expected_ext)
    local name, ext = util.split_ext(file_name)
    if ext ~= expected_ext then
        local msg = string.format("%s: %s does not have a .%s extension",
            argv0, file_name, expected_ext)
        return false, msg
    end
    if not string.match(name, "^[a-zA-Z0-9_/]+$") then
        local msg = string.format("%s: filename %s is non-alphanumeric",
            argv0, file_name)
        return false, msg
    end
    return name
end

--
-- Compile an input file with extension [input_ext] to an output file of type
-- [output_ext]. Erases any intermediate files that are produced along the way.
--
-- Example:
--    compile("pln", "so", "foo.pln") --> outputs "foo.so"
--    compile("pln", "c", "foo.pln")  --> outputs "foo.c"
--    compile("c", "so", "foo.c)      --> outputs "foo.so"
--
function driver.compile(argv0, input_ext, output_ext, input_file_name)
    local base_name, err = check_source_filename(argv0, input_file_name,
        input_ext)
    if not base_name then return false, {err} end

    local mod_name = string.gsub(base_name, "/", "_")

    local first_step = step_index(compiler_steps, input_ext)
    local last_step  = step_index(compiler_steps, output_ext)
    assert(first_step < last_step, "impossible order")

    local file_names = {}
    for i, step in ipairs(compiler_steps) do
        file_names[i] = base_name .. "." .. step.name
    end

    local ok, errs
    for i = first_step, last_step-1 do
        local f = compiler_steps[i].f
        local src = file_names[i]
        local out = file_names[i+1]
        ok, errs = f(src, out, mod_name)
        if not ok then break end
    end

    for i = first_step+1, last_step-1 do
        os.remove(file_names[i])
    end

    return ok, errs
end

--
-- Run AST passes, up-to and including the specified pass.
-- This is meant for unit tests.
--
function driver.test_ast(stop_after, input_filename)
    local base_name, err =
        check_source_filename("pallenec test", input_filename, "pln")
    if not base_name then return false, {err} end

    return compile_pallene_to_ast(input_filename, stop_after)
end


return driver
