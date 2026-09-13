// HerdrEmbed is a pure static-library module: the machine code lives in
// HerdrEmbed.xcframework (built by scripts/herdr-embed-core.sh); this unit
// exists only so the target produces a linkable archive for the clang module
// that declares the embed C ABI in include/HerdrEmbed.h (cbindgen-
// generated, never hand-edited).
