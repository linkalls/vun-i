module main

import os
import time

fn main() {
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
	}

	for name, spec in root_manifest.dependencies {
		resolved := resolve_dependency(mut ctx, name, spec) or {
			eprintln('❌ failed to resolve ${name}@${spec}: ${err.msg()}')
			return
		}
		ctx.root_dependencies[name] = resolved
	}

	println('📦 resolved ${ctx.resolved.len} packages')
	prefetch_all(ctx.resolved.values(), cache_dir)
	ctx = hydrate_all_package_metadata(ctx, cache_dir)

	mut installed := map[string]bool{}
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
		install_store_package(mut ctx, cache_dir, installed_pkg, providers, mut installed) or {
			eprintln('❌ failed to install ${name}: ${err.msg()}')
			return
		}
		link_root_dependency(installed_pkg) or {
			eprintln('❌ failed to link root dependency ${name}: ${err.msg()}')
			return
		}
		link_root_bins(installed_pkg) or {
			eprintln('❌ failed to link root bins for ${name}: ${err.msg()}')
			return
		}
	}

	sync_bun_lockfile()

	elapsed_ms := time.since(start).milliseconds()
	println('✅ vun-i finished in ${elapsed_ms}ms')
}

fn prepare_node_modules() ! {
	os.mkdir_all('node_modules')!
	os.mkdir_all(os.join_path('node_modules', bun_store_dir))!
	os.mkdir_all(hidden_store_node_modules_dir())!
	os.mkdir_all(os.join_path('node_modules', '.bin'))!
}
