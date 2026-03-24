import os
import net.http
import json
import time
import sync

struct PackageJson {
	dependencies map[string]string
}

struct NpmRegistry {
	versions  map[string]NpmVersion
	dist_tags map[string]string @[json: 'dist-tags']
}

struct NpmVersion {
	dist NpmDist
}

struct NpmDist {
	tarball string
}

fn main() {
	start := time.now()
	println('🚀 vun-i: Ultra-fast Vlang package manager starting...')

	if !os.exists('package.json') {
		eprintln('❌ package.json not found')
		return
	}

	data := os.read_file('package.json') or { panic(err) }
	pj := json.decode(PackageJson, data) or { panic(err) }

	cache_dir := os.join_path(os.home_dir(), '.vun-cache')
	os.mkdir_all(cache_dir) or { panic(err) }

	mut wg := sync.new_waitgroup()
	for name, version in pj.dependencies {
		wg.add(1)
		spawn fetch_and_extract(name, version, cache_dir, mut wg)
	}
	wg.wait()

	println('🔗 Hardlinking dependencies to node_modules...')
	os.mkdir_all('node_modules') or { panic(err) }
	for name, _ in pj.dependencies {
		src := os.join_path(cache_dir, name, 'package')
		dest := os.join_path('node_modules', name)

		if os.exists(dest) {
			os.rmdir_all(dest) or {}
		}
		os.mkdir_all(os.dir(dest)) or { panic(err) }

		// V's os.link(src, dest) might not be recursive for directories.
		// We need to walk the src and link each file.
		files := os.walk_ext(src, '')
		for file in files {
			rel := os.relative_path(file, src)
			target := os.join_path(dest, rel)
			if os.is_dir(file) {
				os.mkdir_all(target) or {}
			} else {
				os.mkdir_all(os.dir(target)) or {}
				os.link(file, target) or {
					// Fallback to copy if hardlink fails
					os.cp(file, target) or {}
				}
			}
		}
	}

	elapsed := time.since(start)
	println('✅ Finished in ${elapsed.milliseconds()}ms')
}

fn fetch_and_extract(name string, version string, cache_dir string, mut wg sync.WaitGroup) {
	defer {
		wg.done()
	}

	pkg_cache := os.join_path(cache_dir, name)
	if os.exists(os.join_path(pkg_cache, 'package')) {
		return
	}
	os.mkdir_all(pkg_cache) or { return }

	url := 'https://registry.npmjs.org/${name}'
	resp := http.get(url) or { return }
	reg := json.decode(NpmRegistry, resp.body) or { return }

	target_version := if version == 'latest' { reg.dist_tags['latest'] } else { version }
	tarball_url := reg.versions[target_version].dist.tarball
	if tarball_url == '' {
		return
	}

	tar_path := os.join_path(pkg_cache, 'package.tgz')
	http.download_file(tarball_url, tar_path) or { return }

	os.execute('tar -xzf ${tar_path} -C ${pkg_cache}')
	os.rm(tar_path) or {}
}
