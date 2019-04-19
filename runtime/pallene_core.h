#ifndef PALLENE_CORE_H
#define PALLENE_CORE_H

#include "lapi.h"

#define PALLENE_NORETURN __attribute__((noreturn))
#define PALLENE_UNREACHABLE __builtin_unreachable()

#define PALLENE_LIKELY(x)   __builtin_expect(!!(x), 1)
#define PALLENE_UNLIKELY(x) __builtin_expect(!!(x), 0)

#define PALLENE_LUAINTEGER_NBITS  cast_int(sizeof(lua_Integer) * CHAR_BIT)

const char *pallene_tag_name(int raw_tag);

void pallene_runtime_arity_error(
    lua_State *L, int expected, int received)
    PALLENE_NORETURN;

void pallene_runtime_argument_type_error(
    lua_State *L, const char *param_name, int line, int expected_tag,
    TValue *slot)
    PALLENE_NORETURN;

void pallene_runtime_array_type_error(
    lua_State *L, int line, int expected_tag, int received_tag)
    PALLENE_NORETURN;

void pallene_runtime_function_return_error(
    lua_State *L, int line, int expected_tag, int received_tag)
    PALLENE_NORETURN;

void pallene_runtime_divide_by_zero_error(
    lua_State *L, int line)
    PALLENE_NORETURN;

void pallene_runtime_mod_by_zero_error(
    lua_State *L, int line)
    PALLENE_NORETURN;

int pallene_runtime_record_nonstr_error(
    lua_State *L, int received_tag)
    PALLENE_NORETURN;

int pallene_runtime_record_index_error(
    lua_State *L, const char *key)
    PALLENE_NORETURN;

int pallene_runtime_record_type_error(
    lua_State *L, const char *key, int expected_tag, int received_tag)
    PALLENE_NORETURN;

TString *pallene_string_concatN(
    lua_State *L, size_t n, TString **ss);

void pallene_renormalize_array(
    lua_State *L, Table *arr, unsigned int i, int line);

#endif
