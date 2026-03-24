module main

import archive.tar
import net.http
import os
import sync

struct PackageReader {
mut:
	target_dir   string
	current_file &os.File = unsafe { nil }
}

fn (mut r PackageReader) dir_block(mut read tar.Read, size u64) {
	path := read.get_path()
	parts := path.split('/')
	if parts.len <= 1 {
		return
	}

	target_path := os.join_path(r.target_dir, parts[1..].join('/'))
	if target_path != '' {
		os.mkdir_all(target_path) or {}
	}
}

fn (mut r PackageReader) file_block(mut read tar.Read, size u64) {
	path := read.get_path()
	parts := path.split('/')
	if parts.len <= 1 {
		r.current_file = unsafe { nil }
		return
	}

	target_path := os.join_path(r.target_dir, parts[1..].join('/'))
	parent := os.dir(target_path)
	if !os.exists(parent) {
		os.mkdir_all(parent) or {}
	}

	f := os.create(target_path) or {
		r.current_file = unsafe { nil }
		return
	}
	r.current_file = &f
}

fn (mut r PackageReader) data_block(mut read tar.Read, data []u8, pending int) {
	if r.current_file != unsafe { nil } {
		r.current_file.write(data) or {}
		if pending == 0 {
			r.current_file.close()
			r.current_file = unsafe { nil }
		}
	}
}

fn (mut r PackageReader) other_block(mut read tar.Read, details string) {}

fn extract_tgz_native(tgz_data []u8, dest string) ! {
	mut reader := &PackageReader{
		target_dir: dest
	}
	mut untar := tar.new_untar(reader)
	mut decompressor := tar.new_decompressor(untar)

	decompressor.read_chunks(tgz_data)!
}

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

	// We still download to memory for now as http.download_file doesn't expose a stream easily in high-level V
	// But we use native extraction to avoid 'tar' process overhead
	resp := http.get(pkg.tarball) or {
		eprintln('failed to download ${pkg.name}@${pkg.version}: ${err.msg()}')
		return
	}

	if resp.status_code != 200 {
		eprintln('failed to download ${pkg.name}@${pkg.version}: status ${resp.status_code}')
		return
	}

	extract_tgz_native(resp.body.bytes(), cache_pkg_dir) or {
		eprintln('failed to extract ${pkg.name}@${pkg.version} (native): ${err.msg()}')
		return
	}
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

	resp := http.get(pkg.tarball) or {
		eprintln('failed to download ${pkg.name}@${pkg.version}: ${err.msg()}')
		return
	}

	if resp.status_code != 200 {
		eprintln('failed to download ${pkg.name}@${pkg.version}: status ${resp.status_code}')
		return
	}

	extract_tgz_native(resp.body.bytes(), cache_pkg_dir) or {
		eprintln('failed to extract ${pkg.name}@${pkg.version} (native): ${err.msg()}')
		return
	}
}

