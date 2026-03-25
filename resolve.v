module main

import os

fn install_package_direct(mut ctx InstallContext, cache_dir string, installed_pkg InstalledPackage, providers map[string]ResolvedPackage) ! {
	store_key := store_key_for(installed_pkg)
	ctx.mu.@lock()
	if store_key in ctx.installed {
		ctx.mu.unlock()
		return
	}
	ctx.installed[store_key] = true
	ctx.mu.unlock()

	source_dir := package_cache_dir(cache_dir, installed_pkg.pkg)
	dest_dir := os.join_path('node_modules', installed_pkg.pkg.name)

	hardlink_dir_parallel(source_dir, dest_dir)!
	link_root_bins(installed_pkg)!

	child_providers := providers_for_child(providers, installed_pkg)
	mut threads := []thread !{}
	for dep_name, dep_spec in installed_pkg.pkg.dependencies {
		dep := resolved_by_exact_key(ctx, dep_name, dep_spec) or {
			first_resolved_for_name(ctx, dep_name)!
		}
		dep_peers := select_matching_peers(dep.peer_dependencies, child_providers)
		child := InstalledPackage{dep, dep_peers}
		threads << spawn install_package_direct(mut ctx, cache_dir, child, child_providers)
	}
	for t in threads {
		t.wait()!
	}
}

fn select_matching_peers(peer_specs map[string]string, providers map[string]ResolvedPackage) map[string]ResolvedPackage {
	mut peers := map[string]ResolvedPackage{}
	for peer_name, peer_spec in peer_specs {
		if peer_name !in providers {
			continue
		}
		provider := providers[peer_name]
		if version_matches_spec(provider.version, peer_spec) || peer_spec.trim_space() == '*' {
			peers[peer_name] = provider
		}
	}
	return peers
}

fn providers_for_child(parent_providers map[string]ResolvedPackage, installed_pkg InstalledPackage) map[string]ResolvedPackage {
	mut providers := parent_providers.clone()
	providers[installed_pkg.pkg.name] = installed_pkg.pkg
	for peer_name, peer_pkg in installed_pkg.peers {
		providers[peer_name] = peer_pkg
	}
	return providers
}

fn resolved_by_exact_key(ctx InstallContext, name string, spec string) !ResolvedPackage {
	key := package_key(name, spec)
	if key !in ctx.resolved {
		return error('missing resolved package ${key}')
	}
	return ctx.resolved[key]
}

fn first_resolved_for_name(ctx InstallContext, name string) !ResolvedPackage {
	for _, pkg in ctx.resolved {
		if pkg.name == name {
			return pkg
		}
	}
	return error('package not resolved: ${name}')
}

fn package_key(name string, spec string) string {
	return '${name}@${spec}'
}
