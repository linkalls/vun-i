module main

import os

fn install_store_package(mut ctx InstallContext, cache_dir string, installed_pkg InstalledPackage, providers map[string]ResolvedPackage, mut installed map[string]bool) ! {
	store_key := store_key_for(installed_pkg)
	if store_key in installed {
		return
	}

	package_root := store_package_root(installed_pkg)
	target_dir := store_package_target(installed_pkg)
	source_dir := package_cache_dir(cache_dir, installed_pkg.pkg)

	if !os.exists(target_dir) {
		os.mkdir_all(os.join_path(package_root, 'node_modules'))!
		link_package_dir(source_dir, target_dir)!
	}

	link_hidden_store_dependency(installed_pkg)!
	link_bins_for_package(installed_pkg, providers)!
	installed[store_key] = true

	child_providers := providers_for_child(providers, installed_pkg)
	for dep_name, dep_spec in installed_pkg.pkg.dependencies {
		dep := resolved_by_exact_key(ctx, dep_name, dep_spec) or {
			first_resolved_for_name(ctx, dep_name)!
		}
		dep_peers := select_matching_peers(dep.peer_dependencies, child_providers)
		child := InstalledPackage{dep, dep_peers}
		install_store_package(mut ctx, cache_dir, child, child_providers, mut installed)!
		link_store_dependency(installed_pkg, child)!
	}

	for peer_name, peer_pkg in installed_pkg.peers {
		if peer_name == installed_pkg.pkg.name {
			continue
		}
		link_store_dependency(installed_pkg, InstalledPackage{
			pkg:   peer_pkg
			peers: select_matching_peers(peer_pkg.peer_dependencies, child_providers)
		})!
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
