module main

import archive.tar
import net.http
import os
import sync

struct WriteOp {
	path    string
	data    []u8
	is_last bool
}

struct PackageReader {
mut:
	target_dir   string
	current_path string
	write_chan   chan WriteOp
	buffer       []u8
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
		r.current_path = ''
		return
	}

	r.current_path = os.join_path(r.target_dir, parts[1..].join('/'))
	r.buffer.clear()
}

fn (mut r PackageReader) data_block(mut read tar.Read, data []u8, pending int) {
	if r.current_path != '' {
		r.buffer << data
		// Buffer size: 64KB
		if r.buffer.len >= 64 * 1024 || pending == 0 {
			r.write_chan <- WriteOp{
				path: r.current_path
				data: r.buffer.clone()
				is_last: pending == 0
			}
			r.buffer.clear()
		}
	}
}

fn (mut r PackageReader) other_block(mut read tar.Read, details string) {}

fn io_worker(write_chan chan WriteOp) {
	mut files := map[string]os.File{}
	for {
		op := <-write_chan or { break }
		if op.path !in files {
			parent := os.dir(op.path)
			if !os.exists(parent) {
				os.mkdir_all(parent) or { continue }
			}
			f := os.create(op.path) or { continue }
			files[op.path] = f
		}
		mut f := files[op.path] or { continue }
		f.write(op.data) or {}
		if op.is_last {
			f.close()
			files.delete(op.path)
		}
	}
	for _, mut f in files {
		f.close()
	}
}

fn extract_tgz_native(tgz_data []u8, dest string) ! {
	write_chan := chan WriteOp{cap: 100}
	mut wg := sync.new_waitgroup()
	wg.add(1)
	spawn fn (write_chan chan WriteOp, mut wg sync.WaitGroup) {
		io_worker(write_chan)
		wg.done()
	}(write_chan, mut wg)

	mut reader := PackageReader{
		target_dir: dest
		write_chan: write_chan
		buffer: []u8{cap: 64 * 1024}
	}
	mut untar := tar.new_untar(reader)
	mut decompressor := tar.new_decompressor(untar)

	decompressor.read_chunks(tgz_data)!
	write_chan.close()
	wg.wait()
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

