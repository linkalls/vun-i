module main

import os
import time
import flag

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

	for name, spec in root_manifest.dependencies {
		resolved := resolve_dependency(mut ctx, name, spec) or {
			eprintln('❌ failed to resolve ${name}@${spec}: ${err.msg()}')
			return
		}
		ctx.root_dependencies[name] = resolved
	}

	println('📦 resolved ${ctx.resolved.len} packages')
	
	// Create a channel to signal when a package is ready (downloaded and extracted)
	ready_chan := chan ResolvedPackage{cap: 100}
	
	// Start prefetching in the background
	spawn prefetch_all_streaming(ctx.resolved.values(), cache_dir, ready_chan)
	
	mut ready_count := 0
	total_to_install := ctx.resolved.len
	
	// Installation loop that waits for packages to be ready
	for ready_count < total_to_install {
		_ = <-ready_chan
		ready_count++
	}

	mut link_threads := []thread !{}
	for name, spec in root_manifest.dependencies {
		pkg := resolved_by_exact_key(ctx, name, spec) or {
			first_resolved_for_name(ctx, name) or {
				eprintln('❌ missing resolved package for ${name}@${spec}')
				return
			}
		}
		root_peers := select_matching_peers(pkg.peer_dependencies, ctx.root_dependencies)
		installed_pkg := InstalledPackage{
			pkg:   pkg
			peers: root_peers
		}
		providers := providers_for_child(ctx.root_dependencies, installed_pkg)
		
		link_threads << spawn fn (ctx &InstallContext, cache_dir string, installed_pkg InstalledPackage, providers map[string]ResolvedPackage) ! {
			mut mut_ctx := unsafe { &InstallContext(ctx) }
			install_store_package(mut mut_ctx, cache_dir, installed_pkg, providers) or {
				return error('failed to install ${installed_pkg.pkg.name}: ${err.msg()}')
			}
			link_root_dependency(installed_pkg) or {
				return error('failed to link root dependency ${installed_pkg.pkg.name}: ${err.msg()}')
			}
			link_root_bins(installed_pkg) or {
				return error('failed to link root bins for ${installed_pkg.pkg.name}: ${err.msg()}')
			}
		}(&ctx, cache_dir, installed_pkg, providers)
	}

	for t in link_threads {
		t.wait() or {
			eprintln('❌ link thread failed: ${err.msg()}')
			return
		}
	}

	if opts.sync_bun_lock {
		sync_bun_lockfile()
	}
	if opts.sync_npm_lock {
		sync_npm_lockfile()
	}

	elapsed_ms := time.since(start).milliseconds()

	println('✅ vun-i finished in ${elapsed_ms}ms')
}

fn prepare_node_modules() ! {
	os.mkdir_all('node_modules')!
	os.mkdir_all(os.join_path('node_modules', bun_store_dir))!
	os.mkdir_all(hidden_store_node_modules_dir())!
	os.mkdir_all(os.join_path('node_modules', '.bin'))!
}
