local ast = require "titan-compiler.ast"
local checker = require "titan-compiler.checker"
local util = require "titan-compiler.util"
local pretty = require "titan-compiler.pretty"
local typedecl = require "titan-compiler.typedecl"
local types = require "titan-compiler.types"

local coder = {}

local generate_program
local generate_stat
local generate_var
local generate_exp

function coder.generate(filename, input, modname)
    local prog, errors = checker.check(filename, input)
    if not prog then return false, errors end
    local code = generate_program(prog, modname)
    return code, errors
end


-- While generating code we set some extra fields in the AST.
-- In theory we could have stored this info another way, since these fields
-- don't need to be passed to a following pass.
--
-- _global_index:
--     In Toplevel value nodes (Var and Func).
--     Describes where in the variable is stored in the upvalue table.
--
-- _lua_entry_point
-- _titan_entry_point
--     In Toplevel.Func nodes.
--     Names of the C functions that we generate for each titan function

local whole_file_template = [[
/* This file was generated by the Titan compiler. Do not edit by hand */
/* Indentation and formatting courtesy of titan-compiler/pretty.lua */

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lapi.h"
#include "lfunc.h"
#include "lgc.h"
#include "lobject.h"
#include "lstate.h"
#include "ltable.h"
#include "lvm.h"

#include "math.h"

/* This pragma is used to ignore noisy warnings caused by clang's -Wall */
#ifdef __clang__
#pragma clang diagnostic ignored "-Wparentheses-equality"
#endif

${DEFINE_FUNCTIONS}

int init_${MODNAME}(lua_State *L)
{
    ${INITIALIZE_TOPLEVEL}
    return 0;
}

int luaopen_${MODNAME}(lua_State *L)
{
    Table *titan_globals = luaH_new(L);
    luaH_resizearray(L, titan_globals, ${N_TOPLEVEL});

    {
        CClosure *func = luaF_newCclosure(L, 1);
        func->f = init_${MODNAME};
        sethvalue(L, &func->upvalue[0], titan_globals);
        setclCvalue(L, s2v(L->top), func);
        api_incr_top(L);

        lua_call(L, 0, 0);
    }

    ${CREATE_MODULE_TABLE}
    return 1;
}
]]

--
-- C syntax
--

-- Technically, we only need to escape the quote and backslash
-- But quoting some extra things helps readability...
local some_c_escape_sequences = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\a"] = "\\a",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
    ["\v"] = "\\v",
}

local function c_string(s)
    return '"' .. (s:gsub('.', some_c_escape_sequences)) .. '"'
end

local function c_integer(n)
    return string.format("%i", n)
end

local function c_boolean(b)
    if b then
        return c_integer(1)
    else
        return c_integer(0)
    end
end

local function c_float(n)
    -- Use hexadecimal float literals (%a) to avoid losing any precision.
    -- This feature is part of the C99 and C++17 standards. An alternative
    -- C89-compatiple solution might be to refactor the Titan compiler to
    -- represent float literals as strings instead of as numbers.
    return string.format("%a /*%f*/", n, n)
end

-- @param ctype: (string) C datatype, as produced by ctype()
-- @param varname: (string) C variable name
-- @returns A syntactically valid variable declaration
local function c_declaration(ctyp, varname)
    -- This would be harder if we also allowed array or function pointers...
    return ctyp .. " " .. varname
end

--
--
--

-- This name-mangling scheme is designed to avoid clashes between the function
-- names created in separate models.
local function mangle_function_name(_modname, funcname, kind)
    return string.format("function_%s_%s", funcname, kind)
end

local function local_name(varname)
    return string.format("local_%s", varname)
end

-- Name for a new temporary variable
local tmp_name
do
    local i = 0
    tmp_name = function()
        i = i + 1
        return string.format("tmp_%d", i)
    end
end

-- @param type Type of the titan value
-- @returns type of the corresponding C variable
--
-- We currently represent C types as strings. This suffices for primitive types
-- and pointers to primitive types but we might need to switch to a full ADT if
-- we decide to also support array and function pointer types.
local function ctype(typ)
    local tag = typ._tag
    if     tag == types.T.Nil      then return "int"
    elseif tag == types.T.Boolean  then return "int"
    elseif tag == types.T.Integer  then return "lua_Integer"
    elseif tag == types.T.Float    then return "lua_Number"
    elseif tag == types.T.String   then return "TString *"
    elseif tag == types.T.Function then error("not implemented yet")
    elseif tag == types.T.Array    then return "Table *"
    elseif tag == types.T.Record   then error("not implemented yet")
    else error("impossible")
    end
end

local function get_slot(typ, src_slot_address)
    local tmpl
    local tag = typ._tag
    if     tag == types.T.Nil      then tmpl = "0"
    elseif tag == types.T.Boolean  then tmpl = "bvalue(${SRC})"
    elseif tag == types.T.Integer  then tmpl = "ivalue(${SRC})"
    elseif tag == types.T.Float    then tmpl = "fltvalue(${SRC})"
    elseif tag == types.T.String   then tmpl = "tsvalue(${SRC})"
    elseif tag == types.T.Function then error("not implemented")
    elseif tag == types.T.Array    then tmpl = "hvalue(${SRC})"
    elseif tag == types.T.Record   then error("not implemented")
    else error("impossible")
    end
    return util.render(tmpl, {SRC = src_slot_address})
end


local function set_slot(typ, dst_slot_address, value)
    local tmpl
    local tag = typ._tag
    if     tag == types.T.Nil      then tmpl = "(void) ${SRC}; setnilvalue(${DST});"
    elseif tag == types.T.Boolean  then tmpl = "setbvalue(${DST}, ${SRC});"
    elseif tag == types.T.Integer  then tmpl = "setivalue(${DST}, ${SRC});"
    elseif tag == types.T.Float    then tmpl = "setfltvalue(${DST}, ${SRC});"
    elseif tag == types.T.String   then tmpl = "setsvalue(L, ${DST}, ${SRC});"
    elseif tag == types.T.Function then error("not implemented yet")
    elseif tag == types.T.Array    then tmpl = "sethvalue(L, ${DST}, ${SRC});"
    elseif tag == types.T.Record   then error("not implemented yet")
    else error("impossible")
    end
    return util.render(tmpl, { DST = dst_slot_address, SRC = value })
end

local function check_tag(typ, slot)
    local tmpl
    local tag = typ._tag
    if     tag == types.T.Nil      then tmpl = "ttisnil(${SLOT})"
    elseif tag == types.T.Boolean  then tmpl = "ttisboolean(${SLOT})"
    elseif tag == types.T.Integer  then tmpl = "ttisinteger(${SLOT})"
    elseif tag == types.T.Float    then tmpl = "ttisfloat(${SLOT})"
    elseif tag == types.T.String   then tmpl = "ttisstring(${SLOT})"
    elseif tag == types.T.Function then error("not implemented")
    elseif tag == types.T.Array    then tmpl = "ttistable(${SLOT})"
    elseif tag == types.T.Record   then error("not implemented")
    else error("impossible")
    end
    return util.render(tmpl, {SLOT = slot})
end

local function toplevel_is_value_declaration(tl_node)
    local tag = tl_node._tag
    if     tag == ast.Toplevel.Func then
        return true
    elseif tag == ast.Toplevel.Var then
        return true
    elseif tag == ast.Toplevel.Record then
        return false
    elseif tag == ast.Toplevel.Import then
        return false
    else
        error("impossible")
    end
end

-- @param prog: (ast) Annotated AST for the whole module
-- @param modname: (string) Lua module name (for luaopen)
-- @return (string) C code for the whole module
generate_program = function(prog, modname)

    -- Find where each global variable gets stored in the global table
    local n_toplevel = 0
    do
        for _, tl_node in ipairs(prog) do
            if toplevel_is_value_declaration(tl_node) then
                tl_node._global_index = n_toplevel
                n_toplevel = n_toplevel + 1
            end
        end
    end

    -- Name all the function entry points
    for _, tl_node in ipairs(prog) do
        if tl_node._tag == ast.Toplevel.Func then
            tl_node._titan_entry_point =
                mangle_function_name(modname, tl_node.name, "titan")
            tl_node._lua_entry_point =
                mangle_function_name(modname, tl_node.name, "lua")
        end
    end

    -- Create toplevel function declarations
    local define_functions
    do
        local function_definitions = {}
        for _, tl_node in ipairs(prog) do
            if tl_node._tag == ast.Toplevel.Func then
                -- Titan entry point
                assert(#tl_node._type.rettypes == 1)
                local ret_ctype = ctype(tl_node._type.rettypes[1])

                local titan_params = {}
                table.insert(titan_params, [[lua_State * L]])
                for _, param in ipairs(tl_node.params) do
                    local name = param.name
                    local typ  = param._type
                    table.insert(titan_params,
                        c_declaration(ctype(typ), local_name(name)))
                end

                table.insert(function_definitions,
                    util.render([[
                        static ${RET} ${NAME}(${PARAMS})
                        ${BODY}
                    ]], {
                        RET = ret_ctype,
                        NAME = tl_node._titan_entry_point,
                        PARAMS = table.concat(titan_params, ", "),
                        BODY = generate_stat(tl_node.block)
                    })
                )

                -- Lua entry point
                assert(#tl_node._type.rettypes == 1)
                local ret_typ = tl_node._type.rettypes[1]

                local args_decl = {}
                local args = {}
                table.insert(args, [[L]])
                for i, param in ipairs(tl_node.params) do
                    local slot_name = tmp_name()
                    local arg_name = tmp_name()
                    -- TODO: fix: the error message is not able specify if the
                    -- given type is float or integer (it prints "number")
                    local decl = util.render([[
                        ${SLOT_DECL} = s2v(L->ci->func + ${I});
                        if (!${CHECK_TAG}) {
                            luaL_error(L,
                                "wrong type for argument %s at line %d, "
                                "expected %s but found %s",
                                ${ARG_NAME}, ${LINE}, ${EXP_TYPE},
                                lua_typename(L, ttype(${SLOT_NAME})));
                        }
                        ${ARG_DECL} = ${SLOT_VALUE};
                    ]], {
                        SLOT_DECL = c_declaration("TValue*", slot_name),
                        I = c_integer(i),
                        CHECK_TAG = check_tag(param._type, slot_name),
                        ARG_NAME = c_string(param.name),
                        LINE = c_integer(param.loc.line),
                        EXP_TYPE = c_string(types.tostring(param._type)),
                        SLOT_NAME = slot_name,
                        ARG_DECL = c_declaration(ctype(param._type), arg_name),
                        SLOT_VALUE = get_slot(param._type, slot_name),
                    })
                    table.insert(args_decl, decl)
                    table.insert(args, arg_name)
                end

                table.insert(function_definitions,
                    util.render([[
                        static int ${LUA_ENTRY_POINT}(lua_State *L)
                        {
                            ${ARGS_DECL}
                            ${RET_DECL} = ${TITAN_ENTRY_POINT}(${ARGS});
                            ${SET_RET}
                            api_incr_top(L);
                            return 1;
                        }
                    ]], {
                        LUA_ENTRY_POINT = tl_node._lua_entry_point,
                        TITAN_ENTRY_POINT = tl_node._titan_entry_point,
                        RET_DECL = c_declaration(ctype(ret_typ), "ret"),
                        ARGS_DECL = table.concat(args_decl, "\n"),
                        ARGS = table.concat(args, ", "),
                        SET_RET = set_slot(ret_typ, "s2v(L->top)", "ret"),
                    })
                )
            end
        end
        define_functions = table.concat(function_definitions, "\n")
    end

    -- Construct the values in the toplevel
    -- This needs to happen inside a C closure with all the same upvalues that
    -- a titan function has, because the initializer expressions might rely on
    -- that.
    local initialize_toplevel
    do
        local parts = {}

        if n_toplevel > 0 then
            table.insert(parts,
                [[Table *titan_globals = hvalue(&clCvalue(s2v(L->ci->func))->upvalue[0]);]])
        end

        for _, tl_node in ipairs(prog) do
            if tl_node._global_index then
                local arr_slot = util.render([[ &titan_globals->array[${I}] ]], {
                    I = c_integer(tl_node._global_index)
                })

                local tag = tl_node._tag
                if     tag == ast.Toplevel.Func then
                    table.insert(parts,
                        util.render([[
                            {
                                CClosure *func = luaF_newCclosure(L, 1);
                                func->f = ${LUA_ENTRY_POINT};
                                sethvalue(L, &func->upvalue[0], titan_globals);
                                setclCvalue(L, ${ARR_SLOT}, func);
                            }
                        ]],{
                            LUA_ENTRY_POINT = tl_node._lua_entry_point,
                            TITAN_ENTRY_POINT = tl_node._titan_entry_point,
                            ARR_SLOT = arr_slot,
                        })
                    )
                elseif tag == ast.Toplevel.Var then
                    local exp = tl_node.value
                    local cstats, cvalue = generate_exp(exp)
                    table.insert(parts, cstats)
                    table.insert(parts, set_slot(exp._type, arr_slot, cvalue))
                else
                    error("impossible")
                end
            end
        end

        initialize_toplevel = table.concat(parts, "\n")
    end

    local create_module_table
    do

        local n_exported_functions = 0
        local parts = {}
        for _, tl_node in ipairs(prog) do
            if tl_node._tag == ast.Toplevel.Func and not tl_node.islocal then
                n_exported_functions = n_exported_functions + 1
                table.insert(parts,
                    util.render([[
                        lua_pushstring(L, ${NAME});
                        setobj(L, &L->top->val, &titan_globals->array[${I}]); api_incr_top(L);
                        lua_settable(L, -3);
                    ]], {
                        NAME = c_string(ast.toplevel_name(tl_node)),
                        I = c_integer(tl_node._global_index)
                    })
                )
            end
        end

        create_module_table = util.render([[
            {
                /* Initialize module table */
                lua_createtable(L, 0, ${N});
                ${PARTS}
            }
        ]], {
            N = c_integer(n_exported_functions),
            PARTS = table.concat(parts, "\n")
        })
    end

    local code = util.render(whole_file_template, {
        MODNAME = modname,
        N_TOPLEVEL = c_integer(n_toplevel),
        DEFINE_FUNCTIONS = define_functions,
        INITIALIZE_TOPLEVEL = initialize_toplevel,
        CREATE_MODULE_TABLE = create_module_table,
    })
    return pretty.reindent_c(code)
end

-- @param stat: (ast.Stat)
-- @return (string) C statements
generate_stat = function(stat)
    local tag = stat._tag
    if     tag == ast.Stat.Block then
        local cstatss = {}
        table.insert(cstatss, "{")
        for _, inner_stat in ipairs(stat.stats) do
            local cstats = generate_stat(inner_stat)
            table.insert(cstatss, cstats)
        end
        table.insert(cstatss, "}")
        return table.concat(cstatss, "\n")

    elseif tag == ast.Stat.While then
        local cond_cstats, cond_cvalue = generate_exp(stat.condition)
        local block_cstats = generate_stat(stat.block)
        return util.render([[
            for(;;) {
                ${COND_STATS}
                if (!(${COND})) break;
                ${BLOCK}
            }
        ]], {
            COND_STATS = cond_cstats,
            COND = cond_cvalue,
            BLOCK = block_cstats
        })

    elseif tag == ast.Stat.Repeat then
        local block_cstats = generate_stat(stat.block)
        local cond_cstats, cond_cvalue = generate_exp(stat.condition)
        return util.render([[
            for(;;){
                ${BLOCK}
                ${COND_STATS}
                if (${COND}) break;
            }
        ]], {
            COND_STATS = cond_cstats,
            COND = cond_cvalue,
            BLOCK = block_cstats,
        })

    elseif tag == ast.Stat.If then
        local cstats
        if stat.elsestat then
            cstats = generate_stat(stat.elsestat)
        else
            cstats = nil
        end

        for i = #stat.thens, 1, -1 do
            local then_ = stat.thens[i]
            local cond_cstats, cond_cvalue = generate_exp(then_.condition)
            local block_cstats = generate_stat(then_.block)
            local else_ = (cstats and "else "..cstats or "")

            cstats = util.render(
                [[{
                    ${STATS}
                    if (${COND}) ${BLOCK} ${ELSE}
                }]], {
                STATS = cond_cstats,
                COND = cond_cvalue,
                BLOCK = block_cstats,
                ELSE = else_
            })
        end

        return cstats

    elseif tag == ast.Stat.For then
        local typ = stat.decl._type
        local start_cstats, start_cvalue = generate_exp(stat.start)
        local finish_cstats, finish_cvalue = generate_exp(stat.finish)
        local inc_cstats, inc_cvalue = generate_exp(stat.inc)
        local block_cstats = generate_stat(stat.block)

        -- TODO: remove ternary operator when step is a constant
        local loop_cond = [[(_inc >= 0 ? _start <= _finish : _start >= _finish)]]

        local loop_step
        if typ._tag == types.T.Integer then
            loop_step = [[_start = intop(+, _start, _inc);]]
        elseif typ._tag == types.T.Float then
            loop_step = [[_start = _start + _inc;]]
        else
            error("impossible")
        end

        return util.render([[
            {
                ${START_STAT}
                ${START_DECL} = ${START_VALUE};
                ${FINISH_STAT}
                ${FINISH_DECL} = ${FINISH_VALUE};
                ${INC_STAT}
                ${INC_DECL} = ${INC_VALUE};
                while (${LOOP_COND}) {
                    ${LOOP_DECL} = _start;
                    ${BLOCK}
                    ${LOOP_STEP}
                }
            }
        ]], {
            START_STAT  = start_cstats,
            START_VALUE = start_cvalue,
            START_DECL  = c_declaration(ctype(typ), "_start"),
            FINISH_STAT  = finish_cstats,
            FINISH_VALUE = finish_cvalue,
            FINISH_DECL  = c_declaration(ctype(typ), "_finish"),
            INC_STAT  = inc_cstats,
            INC_VALUE = inc_cvalue,
            INC_DECL  = c_declaration(ctype(typ), "_inc"),
            LOOP_COND = loop_cond,
            LOOP_STEP = loop_step,
            LOOP_DECL = c_declaration(ctype(typ), local_name(stat.decl.name)),
            BLOCK = block_cstats,
        })

    elseif tag == ast.Stat.Assign then
        local var_cstats, var_lvalue = generate_var(stat.var)
        local exp_cstats, exp_cvalue = generate_exp(stat.exp)
        local assign_stat
        if     var_lvalue._tag == coder.Lvalue.CVar then
            assign_stat = var_lvalue.varname.." = "..exp_cvalue..";"
        elseif var_lvalue._tag == coder.Lvalue.Slot then
            assign_stat = set_slot(
                stat.exp._type, var_lvalue.slot_address, exp_cvalue)
        else
            error("impossible")
        end
        return util.render([[
            ${VAR_STATS}
            ${EXP_STATS}
            ${ASSIGN_STAT}
        ]], {
            VAR_STATS = var_cstats,
            EXP_STATS = exp_cstats,
            ASSIGN_STAT = assign_stat,
        })

    elseif tag == ast.Stat.Decl then
        local exp_cstats, exp_cvalue = generate_exp(stat.exp)
        local ctyp = ctype(stat.decl._type)
        local varname = local_name(stat.decl.name)
        local declaration = c_declaration(ctyp, varname)
        return util.render([[
            ${STATS}
            ${DECLARATION} = ${VALUE};
        ]], {
            STATS = exp_cstats,
            VALUE = exp_cvalue,
            DECLARATION = declaration,
        })

    elseif tag == ast.Stat.Call then
        local cstats, cvalue = generate_exp(stat.callexp)
        return util.render([[
            ${STATS}
            (void) ${VALUE};
        ]], {
            STATS = cstats,
            VALUE = cvalue
        })

    elseif tag == ast.Stat.Return then
        local cstats, cvalue = generate_exp(stat.exp)
        return util.render([[
            ${CSTATS}
            return ${CVALUE};
        ]], {
            CSTATS = cstats,
            CVALUE = cvalue
        })

    else
        error("impossible")
    end
end

typedecl.declare(coder, "coder", "Lvalue", {
    CVar = {"varname"},
    Slot = {"slot_address"}
})

-- @param var: (ast.Var)
-- @returns (string, coder.Lvalue) C Statements, and a lvalue
--
-- The lvalue should not not contain side-effects. Anything that could care
-- about evaluation order should be returned as part of the first argument.
generate_var = function(var)
    local tag = var._tag
    if     tag == ast.Var.Name then
        local decl = var._decl
        if    decl._tag == ast.Decl.Decl then
            -- Local variable
            return "", coder.Lvalue.CVar( local_name(decl.name) )

        elseif decl._tag == ast.Toplevel.Var then
            local i = decl._global_index
            local closure = "clCvalue(&L->ci->func->val)"
            local globals = "hvalue(&"..closure.."->upvalue[0])"
            local slot_address = util.render(
                "&${GLOBALS}->array[${I}]",
                { GLOBALS = globals, I = c_integer(i) })
            return "", coder.Lvalue.Slot(slot_address)

        elseif decl._tag == ast.Toplevel.Func then
            -- Toplevel function
            error("not implemented yet")

        else
            error("impossible")
        end

    elseif tag == ast.Var.Bracket then
        error("not implemented yet")

    elseif tag == ast.Var.Dot then
        error("not implemented yet")

    else
        error("impossible")
    end
end

-- @param exp: (ast.Exp)
-- @returns (string, string) C statements, C rvalue
--
-- The rvalue should not not contain side-effects. Anything that could care
-- about evaluation order should be returned as part of the first argument.
generate_exp = function(exp) -- TODO
    local tag = exp._tag
    if     tag == ast.Exp.Nil then
        return "", c_integer(0)

    elseif tag == ast.Exp.Bool then
        return "", c_boolean(exp.value)

    elseif tag == ast.Exp.Integer then
        return "", c_integer(exp.value)

    elseif tag == ast.Exp.Float then
        return "", c_float(exp.value)

    elseif tag == ast.Exp.String then
        error("not implemented yet")

    elseif tag == ast.Exp.Initlist then
        error("not implemented yet")

    elseif tag == ast.Exp.Call then
        if     exp.args._tag == ast.Args.Func then
            local fexp = exp.exp
            local fargs = exp.args
            if fexp._tag == ast.Exp.Var and
                fexp.var._tag == ast.Var.Name and
                fexp.var._decl._tag == ast.Toplevel.Func
            then
                -- Directly calling a toplevel function

                local arg_cstatss = {}
                local arg_cvalues = {"L"}
                for _, arg_exp in ipairs(fargs.args) do
                    local cstats, cvalue = generate_exp(arg_exp)
                    table.insert(arg_cstatss, cstats)
                    table.insert(arg_cvalues, cvalue)
                end

                local tl_node = fexp.var._decl
                assert(#tl_node._type.rettypes == 1)
                local rettype = tl_node._type.rettypes[1]

                local tmp_var = tmp_name()
                local tmp_decl = c_declaration(ctype(rettype), tmp_var)

                local cstats = util.render([[
                    ${ARG_STATS}
                    ${TMP_DECL} = ${FUN_NAME}(${ARGS});
                ]], {
                    FUN_NAME  = tl_node._titan_entry_point,
                    ARG_STATS = table.concat(arg_cstatss, "\n"),
                    ARGS      = table.concat(arg_cvalues, ", "),
                    TMP_DECL = tmp_decl,
                })
                return cstats, tmp_var

            else
                -- First-class functions
                error("not implemented yet")
            end

        elseif exp.args._tag == ast.Args.Method then
            error("not implemented")

        else
            error("impossible")
        end

    elseif tag == ast.Exp.Var then
        local cstats, lvalue = generate_var(exp.var)
        local cvalue
        if     lvalue._tag == coder.Lvalue.CVar then
            cvalue = lvalue.varname
        elseif lvalue._tag == coder.Lvalue.Slot then
            cvalue = get_slot(exp.var._type, lvalue.slot_address)
        else
            error("impossible")
        end
        return cstats, cvalue

    elseif tag == ast.Exp.Unop then
        local cstats, cvalue = generate_exp(exp.exp)

        local op = exp.op
        if op == "#" then
            error("not implemented yet")

        elseif op == "-" then
            return cstats, "(".."-"..cvalue..")"

        elseif op == "~" then
            return cstats, "(".."~"..cvalue..")"

        elseif op == "not" then
            return cstats, "(".."!"..cvalue..")"

        else
            error("impossible")
        end

    elseif tag == ast.Exp.Concat then
        error("not implemented yet")

    elseif tag == ast.Exp.Binop then
        local lhs_cstats, lhs_cvalue = generate_exp(exp.lhs)
        local rhs_cstats, rhs_cvalue = generate_exp(exp.rhs)

        -- Lua's arithmetic and bitwise operations for integers happen with
        -- unsigned integers, to ensure 2's compliment behavior and avoid
        -- undefined behavior.
        local function intop(op)
            local cstats = lhs_cstats..rhs_cstats
            local cvalue = util.render("intop(${OP}, ${LHS}, ${RHS})", {
                OP=op, LHS=lhs_cvalue, RHS=rhs_cvalue })
            return cstats, cvalue
        end

        -- Relational operators, and basic float operations don't convert their
        -- parameters
        local function binop(op)
            local cstats = lhs_cstats..rhs_cstats
            local cvalue = util.render("((${LHS})${OP}(${RHS}))", {
                OP=op, LHS=lhs_cvalue, RHS=rhs_cvalue })
            return cstats, cvalue
        end

        local ltyp = exp.lhs._type._tag
        local rtyp = exp.rhs._type._tag

        local op = exp.op
        if     op == "+" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("+")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("+")
            else
                error("impossible")
            end

        elseif op == "-" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("-")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("-")
            else
                error("impossible")
            end

        elseif op == "*" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("*")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("*")
            else
                error("impossible")
            end

        elseif op == "/" then
            if     ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("/")
            else
                error("impossible")
            end

        elseif op == "&" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("&")
            else
                error("impossible")
            end

        elseif op == "|" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("|")
            else
                error("impossible")
            end

        elseif op == "~" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("^")
            else
                error("impossible")
            end

        elseif op == "<<" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("<<")
            else
                error("impossible")
            end

        elseif op == ">>" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop(">>")
            else
                error("impossible")
            end

        elseif op == "%" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                local cstats = lhs_cstats..rhs_cstats
                local cvalue = util.render("luaV_mod(L, ${LHS}, ${RHS})", {
                    LHS=lhs_cvalue, RHS=rhs_cvalue })
                return cstats, cvalue

            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                -- see luai_nummod
                error("not implemented yet")

            else
                error("impossible")
            end

        elseif op == "//" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                local cstats = lhs_cstats..rhs_cstats
                local cvalue = util.render("luaV_div(L, ${LHS}, ${RHS})", {
                    LHS=lhs_cvalue, RHS=rhs_cvalue })
                return cstats, cvalue

            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                -- see luai_numidiv
                local cstats = lhs_cstats..rhs_cstats
                local cvalue = util.render("floor(${LHS} / ${RHS})", {
                    LHS=lhs_cvalue, RHS=rhs_cvalue })
                return cstats, cvalue

            else
                error("impossible")
            end

        elseif op == "^" then
            if     ltyp == types.T.Float and rtyp == types.T.Float then
                -- see luai_numpow
                local cstats = lhs_cstats..rhs_cstats
                local cvalue = util.render("pow(${LHS}, ${RHS})", {
                    LHS=lhs_cvalue, RHS=rhs_cvalue })
                return cstats, cvalue

            else
                error("impossible")
            end

        elseif op == "==" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop("==")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("==")
            else
                error("not implemented yet")
            end

        elseif op == "~=" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop("!=")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("!=")
            else
                error("not implemented yet")
            end

        elseif op == "<" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop("<")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("<")
            elseif ltyp == types.T.String and rtyp == types.T.String then
                error("not implemented yet")
            elseif ltyp == types.T.Integer and rtyp == types.T.Float then
                error("not implemented yet") -- see LTnum
            elseif ltyp == types.T.Float and rtyp == types.T.Integer then
                error("not implemented yet") -- see LTnum
            else
                error("impossible")
            end

        elseif op == ">" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop(">")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop(">")
            elseif ltyp == types.T.String and rtyp == types.T.String then
                error("not implemented yet")
            elseif ltyp == types.T.Integer and rtyp == types.T.Float then
                error("not implemented yet") -- see LTnum
            elseif ltyp == types.T.Float and rtyp == types.T.Integer then
                error("not implemented yet") -- see LTnum
            else
                error("impossible")
            end

        elseif op == "<=" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop("<=")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("<=")
            elseif ltyp == types.T.String and rtyp == types.T.String then
                error("not implemented yet")
            elseif ltyp == types.T.Integer and rtyp == types.T.Float then
                error("not implemented yet") -- see LTnum
            elseif ltyp == types.T.Float and rtyp == types.T.Integer then
                error("not implemented yet") -- see LTnum
            else
                error("impossible")
            end

        elseif op == ">=" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop(">=")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop(">=")
            elseif ltyp == types.T.String and rtyp == types.T.String then
                error("not implemented yet")
            elseif ltyp == types.T.Integer and rtyp == types.T.Float then
                error("not implemented yet") -- see LTnum
            elseif ltyp == types.T.Float and rtyp == types.T.Integer then
                error("not implemented yet") -- see LTnum
            else
                error("impossible")
            end

        elseif op == "and" then
            if     ltyp == types.T.Boolean and rtyp == types.T.Boolean then
                local l_cstats, l_cvalue = generate_exp(exp.lhs)
                local r_cstats, r_cvalue = generate_exp(exp.rhs)

                local tmp = tmp_name()
                local tmp_decl = c_declaration(ctype(types.T.Boolean()), tmp)
                local cstats = util.render([[
                    ${L_STATS}
                    ${TMP_DECL} = ${L_VALUE};
                    if (${TMP}) {
                      ${R_STATS}
                      ${TMP} = ${R_VALUE};
                    }
                ]], {
                    TMP = tmp,
                    TMP_DECL = tmp_decl,
                    L_STATS = l_cstats,
                    L_VALUE = l_cvalue,
                    R_STATS = r_cstats,
                    R_VALUE = r_cvalue,
                })
                return cstats, tmp

            else
                error("impossible")
            end

        elseif op == "or" then
            if     ltyp == types.T.Boolean and rtyp == types.T.Boolean then
                local l_cstats, l_cvalue = generate_exp(exp.lhs)
                local r_cstats, r_cvalue = generate_exp(exp.rhs)

                local tmp = tmp_name()
                local tmp_decl = c_declaration(ctype(types.T.Boolean()), tmp)
                local cstats = util.render([[
                    ${L_STATS}
                    ${TMP_DECL} = ${L_VALUE};
                    if (!${TMP}) {
                      ${R_STATS}
                      ${TMP} = ${R_VALUE};
                    }
                ]], {
                    TMP = tmp,
                    TMP_DECL = tmp_decl,
                    L_STATS = l_cstats,
                    L_VALUE = l_cvalue,
                    R_STATS = r_cstats,
                    R_VALUE = r_cvalue,
                })
                return cstats, tmp

            else
                error("impossible")
            end

        else
            error("impossible")
        end

    elseif tag == ast.Exp.Cast then
        local cstats, cvalue = generate_exp(exp.exp)

        local src_typ = exp.exp._type
        local dst_typ = exp._type

        if     src_typ._tag == dst_typ._tag then
            return cstats, cvalue

        elseif src_typ._tag == types.T.Integer and dst_typ._tag == types.T.Float then
            return cstats, "((lua_Number)"..cvalue..")"

        elseif src_typ._tag == types.T.Float and dst_typ._tag == types.T.Integer then
            error("not implemented yet")

        else
            error("impossible")
        end

    else
        error("impossible")
    end
end

return coder
