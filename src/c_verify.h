/* Header set translated for the `verify-cabi` parity check (src/c_verify.zig).
 * module.h pulls in lua.h but not lauxlib.h; include it (resolved from the
 * vendored headers) so the lauxlib subset (luaL_register/luaL_error) is seen. */
#include <module.h>
#include <lauxlib.h>
