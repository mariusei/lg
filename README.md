# lg - List with Git Status

A modern, Unicode-aware replacement for `ls` that shows git status alongside file listings.

## Features

- 🎨 **Color-coded git status** - See which files are modified, staged, untracked, or clean
- 🌍 **Full Unicode support** - Handles all scripts correctly (Norwegian, Greek, Cyrillic, CJK, Arabic, etc.)
- 🔄 **NFD/NFC normalization** - Works correctly on macOS with decomposed Unicode
- 😊 **Emoji support** - Even complex multi-codepoint emoji work perfectly
- ⚡ **Fast** - Written in Zig for maximum performance
- 🛡️ **Safe** - Memory-safe with comprehensive error handling
- 🎯 **ls-compatible flags** - Familiar interface with `ls` conventions

## Installation

### Automated Install (Recommended)

```bash
./install.sh
```

The script handles everything: dependency checks, building, and installation to the correct location.

### Via Homebrew

```bash
brew tap mariusei/tap
brew install lg
```

### Manual Build

Requires **Zig 0.16.0+** and the `utf8proc` system library (`brew install utf8proc`).

```bash
make release              # or: zig build -Doptimize=ReleaseFast
./zig-out/bin/lg          # Test the binary
```

See `install.sh` for installation logic details.

## Usage

```bash
# List current directory
lg

# List with all files (including hidden)
lg -a

# List with permissions (standard detail)
lg -l

# List with full details (octal mode, group)
lg -ll

# Sort by size
lg -s

# Sort by time
lg -T

# Reverse order
lg -r

# Group by file type
lg -t

# Calculate directory sizes (slow for large trees)
lg -d

# Show git branch
lg --branch

# Show legend
lg --legend

# Combine flags (like ls)
lg -lan     # all files, alphabetical, standard detail
lg -sr      # sort by size, reversed (largest last)
```

## Git Status Symbols

- `[●]` - Staged changes
- `[○]` - Unstaged changes
- `[?]` - Untracked files
- `[!]` - Ignored files
- `[·]` - Clean/tracked (green dot, no changes)

## Unicode Support

`lg` uses [utf8proc](https://github.com/JuliaStrings/utf8proc) for complete Unicode normalization, supporting:

- **All normalization forms**: NFD, NFC, NFKD, NFKC
- **All scripts**: Latin, Greek, Cyrillic, Arabic, Hebrew, CJK, Thai, etc.
- **Combining characters**: Properly handles diacritics (é, ø, ü, etc.)
- **Emoji**: Full support including complex sequences (👨‍👩‍👧‍👦, 🇳🇴)
- **macOS NFD filenames**: Correctly matches decomposed and composed forms

### Example

```bash
# All of these work correctly, even if macOS stores them differently:
lg Müller.txt
lg café.txt
lg 北京.txt
lg Москва.txt
lg test😊.txt
```

## Architecture

```
lg/
├── src/
│   ├── main.zig          # Entry point
│   ├── cli.zig           # Argument parsing
│   ├── filesystem.zig    # File listing with utf8proc
│   ├── git.zig           # Git status integration
│   ├── display.zig       # Terminal output formatting
│   └── types.zig         # Shared data structures
├── build.zig             # Zig build configuration
├── build.zig.zon         # Dependency manifest
└── archive/              # Legacy C implementation (deprecated)
```

## Design Decisions

### Why Zig?

- **Memory safety** without garbage collection
- **Compile-time guarantees** prevent many bugs
- **C interop** for utf8proc integration
- **Modern tooling** (package manager, build system)
- **Performance** comparable to C

### Why utf8proc?

Considered alternatives:
- ❌ **Manual implementation**: Only covered ~50 Latin characters, brittle
- ❌ **ICU**: 10-30MB overhead, massive overkill
- ❌ **ziglyph/zg**: Not yet compatible with Zig 0.15
- ✅ **utf8proc**:
  - 100% Unicode coverage
  - ~400KB shared library
  - Battle-tested (Julia, PostgreSQL, Apache Arrow)
  - Simple C API
  - MIT licensed

## Performance

Benchmarked on a directory with 1000 files:

```
ls:     ~5ms
lg:     ~8ms (includes git status)
lg -d:  ~250ms (calculating directory sizes)
```

The slight overhead compared to `ls` comes from:
1. Git status querying (~2ms)
2. UTF-8 normalization (~1ms)
3. Enhanced formatting

## Development

### Run Tests

```bash
zig build test
```

### Debug Build

```bash
zig build -Doptimize=Debug
```

### Release Build

```bash
zig build -Doptimize=ReleaseFast
```

## Legacy C Version

The original C implementation has been moved to `archive/`. It is no longer maintained. The Zig version is the canonical implementation going forward.

See `archive/README.md` for details on the C version.

## License

MIT License - see source files for details.

## Contributing

Contributions welcome! Please ensure:
- Code follows Zig style guidelines
- Tests pass (`zig build test`)
- Unicode edge cases are handled
- Documentation is updated

## Credits

- Built with [Zig](https://ziglang.org/)
- Unicode normalization by [utf8proc](https://github.com/JuliaStrings/utf8proc)
- Inspired by `ls`, `exa`, and `eza`
