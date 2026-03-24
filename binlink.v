module main

import os

fn link_root_bins(installed_pkg InstalledPackage) ! {
	for bin_name, bin_target in installed_pkg.pkg.bin {
		dest := os.join_path('node_modules', '.bin', bin_name)
		target_path := os.join_path('node_modules', installed_pkg.pkg.name, bin_target)
		target := relative_path(os.dir(dest), target_path)
		ensure_file_link(target, os.join_path(store_package_target(installed_pkg), bin_target),
			dest)!
	}
}

fn link_bins_for_package(installed_pkg InstalledPackage, providers map[string]ResolvedPackage) ! {
	bin_dir := os.join_path(store_node_modules_dir(installed_pkg), '.bin')
	if !os.exists(bin_dir) {
		os.mkdir_all(bin_dir)!
	}

	mut visible := map[string]InstalledPackage{}
	visible[installed_pkg.pkg.name] = installed_pkg
	child_providers := providers_for_child(providers, installed_pkg)
	for dep_name, dep_spec in installed_pkg.pkg.dependencies {
		if dep_name !in providers {
			continue
		}
		dep_pkg := providers[dep_name]
		if !version_matches_spec(dep_pkg.version, dep_spec) {
			continue
		}
		visible[dep_name] = InstalledPackage{
			pkg:   dep_pkg
			peers: select_matching_peers(dep_pkg.peer_dependencies, child_providers)
		}
	}
	for peer_name, peer_pkg in installed_pkg.peers {
		visible[peer_name] = InstalledPackage{
			pkg:   peer_pkg
			peers: select_matching_peers(peer_pkg.peer_dependencies, child_providers)
		}
	}

	for _, target_pkg in visible {
		for bin_name, bin_target in target_pkg.pkg.bin {
			dest := os.join_path(bin_dir, bin_name)
			target_path := os.join_path(store_package_target(target_pkg), bin_target)
			target := relative_path(os.dir(dest), target_path)
			ensure_file_link(target, target_path, dest)!
		}
	}
}
