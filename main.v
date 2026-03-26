module main

import os
import time
import flag

// Built with -gc none: vun-i is a short-lived process; GC pauses are pure overhead.

struct Options {
	sync_bun_lock bool
	sync_npm_lock bool
	bun_compat    bool
}


fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('vun-i')

	fp.version('0.2.0')
	fp.description('blazing-fast hardlink-based node_modules installer')
	fp.skip_executable()

	sync_bun_lock := fp.bool('sync-bun-lock', 0, false, 'sync bun.lock after install')
	bun_compat := fp.bool('bun-compat', 0, false, 'alias for --sync-bun-lock')
	sync_npm_lock := fp.bool('sync-npm-lock', 0, false, 'sync package-lock.json after install')

	fp.finalize() or {
		eprintln('❌ ${err}')
		return
	}

	opts := Options{
		sync_bun_lock: sync_bun_lock || bun_compat
		sync_npm_lock: sync_npm_lock
		bun_compat:    bun_compat
	}


	start := time.now()
	println('🚀 vun-i starting...')

	root_manifest := read_package_json('package.json') or {
		eprintln('❌ failed to read package.json: ${err.msg()}')
		return
	}

	cache_dir := bun_cache_dir()
	os.mkdir_all(cache_dir) or {
		eprintln('❌ failed to create cache dir ${cache_dir}: ${err.msg()}')
		return
	}

	prepare_node_modules() or {
		eprintln('❌ failed to prepare node_modules: ${err.msg()}')
		return
	}

	mut ctx := InstallContext{
		resolved:          map[string]ResolvedPackage{}
		root_dependencies: map[string]ResolvedPackage{}
		installed:         map[string]bool{}
	}

	resolve_all_dependencies(mut ctx, root_manifest.dependencies, cache_dir) or {
		eprintln('❌ failed to resolve dependencies: ${err.msg()}')
		return
	}

	for name, _ in root_manifest.dependencies {
		pkg := first_resolved_for_name(ctx, name) or {
			eprintln('❌ missing resolved package for ${name}')
			return
		}
		ctx.root_dependencies[name] = pkg
	}

	println('📦 resolved ${ctx.resolved.len} packages')

	// Phase 1: parallel download + extract
	prefetch_all(ctx.resolved.values(), cache_dir)

	// Phase 2: flat BFS collect + bounded worker pool hardlink
	jobs := collect_install_jobs(&ctx, cache_dir, ctx.root_dependencies)
	install_all_jobs(mut ctx, jobs) or {
		eprintln('❌ install failed: ${err.msg()}')
		return
	}

	if opts.sync_bun_lock {
		sync_bun_lockfile(root_manifest, ctx, cache_dir)
	}
	if opts.sync_npm_lock {
		sync_npm_lockfile()
	}

	elapsed_ms := time.since(start).milliseconds()

	println('✅ vun-i finished in ${elapsed_ms}ms')
}

fn prepare_node_modules() ! {
	os.mkdir_all('node_modules')!
	os.mkdir_all(os.join_path('node_modules', '.bin'))!
}
