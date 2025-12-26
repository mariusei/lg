# Archive - Legacy C Implementation

This folder contains the deprecated C implementation of `lg`.

## Contents

- **`lg`** - Compiled C binary (deprecated)
- **`lg_v2.c`** - C source code (final version before Zig migration)
- **`lg_v2.c.old`** - Earlier C version
- **`Makefile`** - Build configuration for C version
- **`c-version-legacy/`** - Workspace files from migration period

## Why Deprecated?

The C version has been replaced with a modern Zig implementation that offers:

- ✅ **Better Unicode support** - Full UTF-8 normalization via utf8proc
- ✅ **Memory safety** - Zig's compile-time safety guarantees
- ✅ **Maintainability** - Cleaner, more modular codebase
- ✅ **Type safety** - Strong type system prevents common C bugs
- ✅ **Better error handling** - Explicit error propagation
- ✅ **Modern build system** - Zig build system vs. Makefile

## Building the C Version (Not Recommended)

If you need to build the legacy C version:

```bash
cd archive
make
```

**Note**: The C version has known limitations:
- Limited Unicode normalization (manual hardcoded table)
- No NFD/NFC handling for non-Latin scripts
- Manual memory management prone to leaks
- Less comprehensive error handling

## Migration Date

The C version was deprecated on **November 21, 2024** in favor of the Zig implementation with utf8proc integration.

For the current, maintained version, see the root directory.
