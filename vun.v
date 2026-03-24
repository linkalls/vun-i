module main

// Entry point and implementation were split across:
// - main.v
// - types.v
// - registry.v
// - cache.v
// - resolve.v
// - store.v
// - linker.v
// - binlink.v
// - lockfile.v
//
// Keep this file so existing references to `vun.v` still make sense in the repo,
// but compile the whole directory (`v -prod -o vun.exe .`).
