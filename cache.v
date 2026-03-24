module main

import net.http
import os
import sync

fn bun_cache_dir() string {
	custom_cache := os.getenv('BUN_INSTALL_CACHE_DIR')
	if custom_cache != '' {
		return custom_cache
	}
	return os.join_path(os.home_dir(), '.bun', 'install', 'cache')
}

fn package_cache_dir(cache_dir string, pkg ResolvedPackage) string {
	return os.join_path(cache_dir, bun_cache_folder_name(pkg))
}

fn bun_cache_folder_name(pkg ResolvedPackage) string {
	if pkg.name.starts_with('@') {
		parts := pkg.name.split('/')
		if parts.len == 2 {
			return os.join_path(parts[0], '${parts[1]}@${pkg.version}@@@1')
		}
	}
	return '${pkg.name}@${pkg.version}@@@1'
}

fn prefetch_all_streaming(packages []ResolvedPackage, cache_dir string, ready_chan chan ResolvedPackage) {
	if packages.len == 0 {
		return
	}

	mut wg := sync.new_waitgroup()
	for pkg in packages {
		wg.add(1)
		spawn prefetch_package_streaming(pkg, cache_dir, ready_chan, mut wg)
	}
	wg.wait()
}

fn prefetch_package_streaming(pkg ResolvedPackage, cache_dir string, ready_chan chan ResolvedPackage, mut wg sync.WaitGroup) {
	defer {
		wg.done()
		ready_chan <- pkg
	}

	cache_pkg_dir := package_cache_dir(cache_dir, pkg)
	if os.exists(os.join_path(cache_pkg_dir, 'package.json')) {
		return
	}

	os.mkdir_all(cache_pkg_dir) or {
		eprintln('failed to create cache dir for ${pkg.name}@${pkg.version}: ${err.msg()}')
		return
	}

	tar_path := os.join_path(cache_pkg_dir, 'package.tgz')
	http.download_file(pkg.tarball, tar_path) or {
		eprintln('failed to download ${pkg.name}@${pkg.version}: ${err.msg()}')
		return
	}

	// Use native V tar extraction if possible for Windows, but stick to command for now
	cmd := 'tar -xzf "${tar_path}" --strip-components=1 -C "${cache_pkg_dir}"'
	result := os.execute(cmd)
	if result.exit_code != 0 {
		eprintln('failed to extract ${pkg.name}@${pkg.version}: ${result.output}')
		return
	}

	os.rm(tar_path) or {}
}

fn prefetch_all(packages []ResolvedPackage, cache_dir string) {
	if packages.len == 0 {
		return
	}

	mut wg := sync.new_waitgroup()
	for pkg in packages {
		wg.add(1)
		spawn prefetch_package(pkg, cache_dir, mut wg)
	}
	wg.wait()
}

fn prefetch_package(pkg ResolvedPackage, cache_dir string, mut wg sync.WaitGroup) {
	defer {
		wg.done()
	}

	cache_pkg_dir := package_cache_dir(cache_dir, pkg)
	if os.exists(os.join_path(cache_pkg_dir, 'package.json')) {
		return
	}

	os.mkdir_all(cache_pkg_dir) or {
		eprintln('failed to create cache dir for ${pkg.name}@${pkg.version}: ${err.msg()}')
		return
	}

	tar_path := os.join_path(cache_pkg_dir, 'package.tgz')
	http.download_file(pkg.tarball, tar_path) or {
		eprintln('failed to download ${pkg.name}@${pkg.version}: ${err.msg()}')
		return
	}

	cmd := 'tar -xzf "${tar_path}" --strip-components=1 -C "${cache_pkg_dir}"'
	result := os.execute(cmd)
	if result.exit_code != 0 {
		eprintln('failed to extract ${pkg.name}@${pkg.version}: ${result.output}')
		return
	}

	os.rm(tar_path) or {}
}

