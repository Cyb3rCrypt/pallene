local util = require "pallene.util"

local function compile(pallene_code)
    assert(util.set_file_contents("__test__.pln", pallene_code))
    local ok, _, _, error_message = util.outputs_of_execute("./pallenec __test__.pln --emit-lua")
    if not ok then
        error(error_message)
    end
end

local function assert_translation(pallene_code, expected)
    compile(pallene_code)
    local contents = util.get_file_contents("__test__.lua")
    assert.are.same(expected, contents)
end

local function assert_translation_error(pallene_code, expected)
    assert(util.set_file_contents("__test__.pln", pallene_code))
    local ok, _, _, actual = util.outputs_of_execute("./pallenec __test__.pln --emit-lua")
    assert.is_false(ok)
    assert.match(expected, actual, 1, true)
end

local function cleanup()
    os.remove("__test__.pln")
    os.remove("__test__.lua")
end

describe("Pallene to Lua translator", function ()
    teardown(cleanup)

    it("Missing end keyword in function definition (syntax error)", function ()
        assert_translation_error([[
            local function f() : integer
        ]],
        "Expected 'end' to close the function body.")
    end)

    it("Unknown type (semantic error)", function ()
        assert_translation_error([[
            local function f() : unknown
            end
        ]],
        "type 'unknown' is not declared")
    end)

    it("empty input should result in an empty result", function ()
        assert_translation("", "")
    end)

    it("copy the program as is when there are no type annotations", function ()
        assert_translation([[
            local i = 10
            local function print_hello()
                -- This is a comment.
                -- This is another line comment.
                io.write("Hello, world!")
            end
        ]],
        [[
            local i = 10
            local function print_hello()
                -- This is a comment.
                -- This is another line comment.
                io.write("Hello, world!")
            end
        ]])
    end)

    it("Remove type annotations from a top-level variable", function ()
        assert_translation([[
            local xs: integer = 10
        ]],
        [[
            local xs          = 10
        ]])
    end)

    it("Remove type annotations from top-level variables", function ()
        assert_translation([[
            local a: integer, b: integer, c: string = 5, 3, 'Marshall Mathers'
        ]],
        [[
            local a         , b         , c         = 5, 3, 'Marshall Mathers'
        ]])
    end)

    it("Keep newlines that appear after the colon in a top-level variable type annotation", function ()
        assert_translation([[
            local xs:
                integer = 10
        ]],
        [[
            local xs 
                        = 10
        ]])
    end)

    pending("Keep newlines that appear inside a top-level variable type annotation", function ()
        assert_translation([[
            local xs: {
                integer
            } = 10
        ]],
        [[
            local xs

              = 10
        ]])
    end)

    pending("Keep tabs that appear in a top-level variable type annotation", function ()
        assert_translation(
            "    local xs:\t\n" ..
            "    \t    integer = 10\n",

            "    local xs \t\n" ..
            "    \t            = 10\n")
    end)

    pending("Keep return carriages that appear in a top-level variable type annotation", function ()
        assert_translation(
            "    local xs:\r\n" ..
            "    \r    integer = 10\n",

            "    local xs \r\n" ..
            "    \r            = 10\n")
    end)

    it("Keep newlines that appear inside a top-level variable type annotations", function ()
        assert_translation([[
            local a:
                integer, b:
                    string, c:
                        integer = 53, 'Madyanam', 19
        ]],
        [[
            local a 
                       , b 
                          , c 
                                = 53, 'Madyanam', 19
        ]])
    end)

    pending("Keep comments that appear inside a top-level variable type annotation", function ()
        assert_translation([[
            local xs: -- This is a comment.
                integer = 10
        ]],
        [[
            local xs  -- This is a comment.
                        = 10
        ]])
    end)

    pending("Mutually recursive functions (infinite)", function ()
        assert_translation([[
            local function a()
                b()
            end

            local function b()
                a()
            end
        ]],
        [[
            local a, b

            local function a()
                b()
            end

            local function b()
                a()
            end
        ]])
    end)

    pending("Remove type annotations", function ()
        assert_translation([[
            local xs: {any} = {10, "hello", 3.14}

            function f(x: any, y: any): integer
                return (x as integer) + (y as integer)
            end
        ]],
        [[
            local xs = { 10, "hello", 3.14 }

            function f(x, y)
                return x + y
            end
        ]])
    end)

    pending("Remove function shapes", function ()
        assert_translation([[
            local function invoke(x: (integer, integer) -> (float, float)): (float, float)
                return x(1, 2)
            end
        ]],
        [[
            local function invoke(x)
                return x(1, 2)
            end
        ]])
    end)

    pending("Remove casts", function ()
        assert_translation([[
            local function print_string(value:any)
                io.write(value as string)
            end
        ]],
        [[
            local function print_string(value)
                io.write(value)
            end
        ]])
    end)

    pending("Remove type aliases", function ()
        assert_translation([[
            typealias point = {
                x: integer,
                y: integer
            }
            local p: point = { x = 10, y = 20 }
        ]],
        [[
            local p = { x = 10, y = 20 }
        ]])
    end)

    pending("Keep the strings quotes as is", function ()
        assert_translation([[
            local function print_hello()
                io.write('Hello, ')
                io.write("world!")
            end
        ]],
        [[
            local function print_hello()
                io.write('Hello, ')
                io.write("world!")
            end
        ]])
    end)

    pending("Remove return type annotations", function ()
        assert_translation([[
            local function get_numbers() : { integer, integer }
                return 53, 519
            end
        ]],
        [[
            local function get_numbers()
                return 53, 519
            end
        ]])
    end)

    pending("Remove parameter and return type annotations", function ()
        assert_translation([[
            local function add(x: integer, y: integer) : integer
                return x + y
            end
        ]],
        [[
            local function add(x, y)
                return x + y
            end
        ]])
    end)

    pending("Remove local variable type annotations.", function ()
        assert_translation([[
            local function add()
                local x: integer = 10
                local y: integer = 20
                local z: integer = x + y
            end
        ]],
        [[
            local function add()
                local x = 10
                local y = 20
                local z = x + y
            end
        ]])
    end)

    pending("Exported functions will be made local, but added to the table returned.", function ()
        assert_translation([[
            export function add(x: integer, y: integer) : integer
                return x + y
            end
        ]],
        [[
            --
            local function add(x, y)
                return x + y
            end

            return {
                add = add
            }
        ]])
    end)

    pending("Exported variables will be made local, but added to the table returned.", function ()
        assert_translation([[
            export x : integer = 83
        ]],
        [[
            local x = 83

            return {
                x = x
            }
        ]])
    end)

    pending("Expressions are copied as is", function ()
        assert_translation([[
            export function expression()
                local x = (1 + 2) * (100 / 30) or true
            end
        ]],
        [[
            local function expression()
                local x = (1 + 2) * (100 / 30) or true
            end

            return {
                expression = expression
            }
        ]])
    end)

    pending("While statements", function ()
        assert_translation([[
            local function count()
                local i : integer = 1
                while i <= 10 do
                    i = i + 1
                end
            end
        ]],
        [[
            local function count()
                local i = 1
                while i <= 10 do
                    i = i + 1
                end
            end
        ]])
    end)

    pending("Do Statement", function ()
        assert_translation([[
            local function example()
                local i : integer = 10
                do
                    local i : integer = 20
                end
                return i
            end
        ]],
        [[
            local function example()
                local i = 10
                do
                    local i = 20
                end
                return i
            end
        ]])
    end)

    pending("If statement", function ()
        assert_translation([[
            local function is_even(n: integer): boolean
                if (n % 2) == 0 then
                    return true
                else
                    return false
                end
            end
        ]],
        [[
            local function is_even(n)
                if (n % 2) == 0 then
                    return true
                else
                    return false
                end
            end
        ]])
    end)

    pending("For statement", function ()
        assert_translation([[
            local function print_strings(strings: {string})
                for s : string in strings do
                    io.write(s .. '\n')
                end
            end
        ]],
        [[
            local function print_strings(strings)
                for s in strings do
                    io.write(s .. '\n')
                end
            end
        ]])
    end)
end)
