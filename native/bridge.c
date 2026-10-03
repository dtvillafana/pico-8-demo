#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <openssl/evp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#if !defined(__linux__) || !defined(__x86_64__)
#error "This bridge supports only the inspected Linux x86-64 executable"
#endif

/* Verified against the hash below, not a system liblua ABI. No numeric Lua
 * values cross this boundary: PICO-8 uses a modified fixed-point Lua runtime.
 */
typedef struct lua_State lua_State;
typedef int (*lua_callback)(lua_State *);
static void (*const push_closure)(lua_State *, lua_callback,
                                  int) = (void *)0x41f8e0;
static void (*const set_global)(lua_State *, const char *) = (void *)0x426880;
static const char *(*const to_string)(lua_State *, int,
                                      size_t *) = (void *)0x420ae0;
static const char *(*const push_string)(lua_State *, const char *,
                                        size_t) = (void *)0x420680;
static void (*const push_nil)(lua_State *) = (void *)0x4188e0;
static void (*const push_value)(lua_State *, int) = (void *)0x4184b0;
static int (*const value_type)(lua_State *, int) = (void *)0x4184e0;
static int (*const load_buffer)(lua_State *, const char *, size_t, const char *,
                                const char *) = (void *)0x420220;
static lua_callback const protected_call = (void *)0x4359b0;
static volatile int *const compiling = (void *)0xb6dab0;

static const char supported_hash[] =
    "ca4e55eda8933a83315d9012de268c4d7dc3d204ba65d19905dccdb882b7a416";
enum { MAX_SOURCE = 65536, LUA_TSTRING = 4 };
static char watched_path[PATH_MAX];
static void (*original_registration)(lua_State *);

static _Noreturn void die(const char *message) {
  fprintf(stderr, "[hot-reload] %s\n", message);
  _exit(78);
}

static void hex_digest(const unsigned char digest[32], char revision[65]) {
  static const char hex[] = "0123456789abcdef";
  for (size_t i = 0; i < 32; ++i) {
    revision[i * 2] = hex[digest[i] >> 4];
    revision[i * 2 + 1] = hex[digest[i] & 15];
  }
  revision[64] = '\0';
}

static void verify_executable(void) {
  FILE *file = fopen("/proc/self/exe", "rb");
  EVP_MD_CTX *context = EVP_MD_CTX_new();
  if (!file || !context || EVP_DigestInit_ex(context, EVP_sha256(), NULL) != 1)
    die("Cannot fingerprint executable");
  unsigned char buffer[16384], digest[32];
  size_t count;
  while ((count = fread(buffer, 1, sizeof(buffer), file)) != 0) {
    if (EVP_DigestUpdate(context, buffer, count) != 1)
      die("Cannot fingerprint executable");
  }
  if (ferror(file) || EVP_DigestFinal_ex(context, digest, NULL) != 1)
    die("Cannot fingerprint executable");
  fclose(file);
  EVP_MD_CTX_free(context);
  char hash[65];
  hex_digest(digest, hash);
  if (strcmp(hash, supported_hash) != 0)
    die("Unsupported PICO-8 binary SHA-256; refusing native hooks");
}

static int read_error(lua_State *state, const char *message) {
  push_nil(state);
  push_nil(state);
  push_string(state, message, strlen(message));
  return 3;
}

static int source_error(lua_State *state, const char *message) {
  push_nil(state);
  push_string(state, message, strlen(message));
  return 2;
}

static int same_file(const struct stat *before, const struct stat *after) {
  return before->st_dev == after->st_dev && before->st_ino == after->st_ino &&
         before->st_size == after->st_size &&
         before->st_mtim.tv_sec == after->st_mtim.tv_sec &&
         before->st_mtim.tv_nsec == after->st_mtim.tv_nsec &&
         before->st_ctim.tv_sec == after->st_ctim.tv_sec &&
         before->st_ctim.tv_nsec == after->st_ctim.tv_nsec;
}

/* Only the explicitly configured module can be read, never arbitrary paths.
 * All native resources are closed before entering potentially longjmp-ing Lua
 * allocation routines. File contents and revisions are Lua strings. */
static int read_changed(lua_State *state) {
  size_t name_size = 0;
  const char *name = value_type(state, 1) == LUA_TSTRING
                         ? to_string(state, 1, &name_size)
                         : NULL;
  if (!name || name_size != 8 || memcmp(name, "game.lua", 8) != 0)
    return read_error(state, "only the configured game.lua module may be read");

  int fd = open(watched_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0)
    return read_error(state, strerror(errno));
  struct stat before, after, current;
  if (fstat(fd, &before) != 0 || !S_ISREG(before.st_mode) ||
      before.st_size > MAX_SOURCE) {
    close(fd);
    return read_error(state,
                      "module must be a regular file of at most 65536 bytes");
  }
  char source[MAX_SOURCE + 1];
  size_t size = 0;
  while (size < sizeof(source)) {
    ssize_t count = read(fd, source + size, sizeof(source) - size);
    if (count < 0) {
      if (errno == EINTR)
        continue;
      int error = errno;
      close(fd);
      return read_error(state, strerror(error));
    }
    if (count == 0)
      break;
    size += (size_t)count;
  }
  int stable = fstat(fd, &after) == 0 && stat(watched_path, &current) == 0 &&
               same_file(&before, &after) && same_file(&after, &current);
  close(fd);
  if (!stable)
    return read_error(state, "module changed while being read; retrying");
  if (size > MAX_SOURCE)
    return read_error(state, "source exceeds 65536 bytes");
  for (size_t i = 0; i < size; ++i) {
    if ((unsigned char)source[i] == 0)
      return read_error(state, "NUL bytes are not allowed in Lua source");
    if ((unsigned char)source[i] > 127)
      return read_error(state, "requires ASCII Lua source");
  }
  unsigned char digest[32];
  if (EVP_Digest(source, size, digest, NULL, EVP_sha256(), NULL) != 1)
    return read_error(state, "cannot hash module");
  char revision[65];
  hex_digest(digest, revision);
  size_t previous_size = 0;
  const char *previous = value_type(state, 2) == LUA_TSTRING
                             ? to_string(state, 2, &previous_size)
                             : NULL;
  if (previous && previous_size == 64 && memcmp(previous, revision, 64) == 0)
    push_nil(state);
  else
    push_string(state, source, size);
  push_string(state, revision, 64);
  return 2;
}

static int compile_source(lua_State *state) {
  size_t size = 0;
  const char *source =
      value_type(state, 1) == LUA_TSTRING ? to_string(state, 1, &size) : NULL;
  if (!source || size > MAX_SOURCE)
    return source_error(state,
                        "expected a source string of at most 65536 bytes");
  for (size_t i = 0; i < size; ++i) {
    if ((unsigned char)source[i] == 0)
      return source_error(state, "NUL bytes are not allowed in Lua source");
    if ((unsigned char)source[i] > 127)
      return source_error(state, "requires ASCII Lua source");
  }
  int saved = *compiling;
  *compiling = 1;
  int status = load_buffer(state, source, size, "@hot/game.lua", "t");
  *compiling = saved;
  if (status == 0)
    return 1;
  /* Keep the protected parser's error, returning nil, error to Lua. */
  push_nil(state);
  push_value(state, -2);
  return 2;
}

static void register_bridge(lua_State *state) {
  original_registration(state);
  push_closure(state, read_changed, 0);
  set_global(state, "dev_read_changed");
  push_closure(state, compile_source, 0);
  set_global(state, "dev_compile");
  push_closure(state, protected_call, 0);
  set_global(state, "dev_pcall");
}

static void absolute_jump(unsigned char *destination, uintptr_t target) {
  /* jmp qword ptr [rip]; embedded 64-bit address, without clobbering registers.
   */
  const unsigned char instruction[] = {0xff, 0x25, 0, 0, 0, 0};
  memcpy(destination, instruction, sizeof(instruction));
  memcpy(destination + sizeof(instruction), &target, sizeof(target));
}

static void patch_executable(unsigned char *address,
                             const unsigned char *expected,
                             const unsigned char *replacement, size_t size) {
  if (memcmp(address, expected, size) != 0)
    die("Executable patch signature mismatch; refusing native patches");
  long page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0)
    die("Cannot determine page size");
  uintptr_t mask = (uintptr_t)page_size - 1;
  uintptr_t first = (uintptr_t)address & ~mask;
  uintptr_t last = ((uintptr_t)address + size - 1) & ~mask;
  size_t span = last - first + (size_t)page_size;
  if (mprotect((void *)first, span, PROT_READ | PROT_WRITE | PROT_EXEC) != 0)
    die("Cannot make executable patch writable");
  memcpy(address, replacement, size);
  __builtin___clear_cache((char *)address, (char *)address + size);
  if (mprotect((void *)first, span, PROT_READ | PROT_EXEC) != 0)
    die("Cannot restore executable page protection");
}

static void disable_token_limit(void) {
  /* run_program: count_tokens(); cmp eax,8192; jg "program too large".
   * Remove only the rejection branch, preserving the actual token count
   * subsequently used for memory accounting. Other resource limits remain. */
  const unsigned char expected[] = {0x0f, 0x8f, 0x0a, 0xf8, 0xff, 0xff};
  const unsigned char replacement[] = {0x90, 0x90, 0x90, 0x90, 0x90, 0x90};
  patch_executable((void *)0x442717, expected, replacement, sizeof(expected));
}

static void install_registration_hook(void) {
  unsigned char *entry = (void *)0x46ad10;
  /* Five whole, position-independent prologue instructions (11 bytes).
   * This is not a general-purpose detour/relocator. Fail closed on mismatch. */
  const unsigned char prologue[] = {0x55, 0x53, 0x31, 0xc0, 0x48, 0x89,
                                    0xfb, 0x48, 0x83, 0xec, 0x08};
  if (memcmp(entry, prologue, sizeof(prologue)) != 0)
    die("Registration prologue mismatch; refusing native hook");
  long page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0)
    die("Cannot determine page size");
  unsigned char *trampoline =
      mmap(NULL, (size_t)page_size, PROT_READ | PROT_WRITE,
           MAP_PRIVATE | MAP_ANONYMOUS | MAP_32BIT, -1, 0);
  if (trampoline == MAP_FAILED)
    die("Cannot allocate native hook trampoline");
  memcpy(trampoline, prologue, sizeof(prologue));
  absolute_jump(trampoline + sizeof(prologue),
                (uintptr_t)(entry + sizeof(prologue)));
  unsigned char *relay = trampoline + 32;
  absolute_jump(relay, (uintptr_t)register_bridge);
  intptr_t distance = (intptr_t)relay - (intptr_t)(entry + 5);
  if (distance < INT32_MIN || distance > INT32_MAX)
    die("Native hook relay is out of range");
  if (mprotect(trampoline, (size_t)page_size, PROT_READ | PROT_EXEC) != 0)
    die("Cannot protect native hook trampoline");
  original_registration = (void *)trampoline;
  int32_t relative = (int32_t)distance;
  unsigned char patch[sizeof(prologue)];
  memset(patch, 0x90, sizeof(patch));
  patch[0] = 0xe9;
  memcpy(patch + 1, &relative, sizeof(relative));
  patch_executable(entry, prologue, patch, sizeof(patch));
}

__attribute__((constructor)) static void initialize_bridge(void) {
  const char *enabled = getenv("PICO8_NATIVE_BRIDGE");
  if (!enabled || strcmp(enabled, "1") != 0)
    return;
  /* Child processes can inherit LD_PRELOAD, but must never receive hooks. */
  unsetenv("PICO8_NATIVE_BRIDGE");
  verify_executable();
  const char *source = getenv("PICO8_HOT_SOURCE");
  const char *root = getenv("PICO8_PROJECT_ROOT");
  int length;
  if (source)
    length = snprintf(watched_path, sizeof(watched_path), "%s", source);
  else if (root)
    length =
        snprintf(watched_path, sizeof(watched_path), "%s/carts/game.lua", root);
  else
    die("PICO8_PROJECT_ROOT is required");
  if (length < 0 || (size_t)length >= sizeof(watched_path) ||
      watched_path[0] != '/')
    die("Module path must be absolute and fit PATH_MAX");
  install_registration_hook();
  disable_token_limit();
  fprintf(stderr, "[hot-reload] Native Lua bridge enabled; token limit "
                  "disabled; no debugger\n");
}
