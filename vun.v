module main

import json
import net.http
import os
import sync
import time

const registry_url = 'https://registry.npmjs.org'
const bun_cache_suffix = '.bun/install/cache'

struct PackageJson {
	dependencies map[string]string
}

struct NpmRegistry {
	versions  map[string]NpmVersion
	dist_tags map[string]string @[json: 'dist-tags']
}

struct NpmVersion {
	name         string
	version      string
	dist         NpmDist
	dependencies map[string]string
}

struct NpmDist {
	tarball string
}

struct ResolvedPackage {
	name         string
	version      string
	tarball      string
	dependencies map[string]string
}

struct InstallContext {
mut:
	resolved map[string]ResolvedPackage
}

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

	mut ctx := InstallContext{
		resolved: map[string]ResolvedPackage{}
	}

	for name, spec in root_manifest.dependencies {
		resolve_dependency(mut ctx, name, spec) or {
			eprintln('❌ failed to resolve ${name}@${spec}: ${err.msg()}')
			return
		}
	}

	println('📦 resolved ${ctx.resolved.len} packages')
	prefetch_all(ctx.resolved.values(), cache_dir)

	os.mkdir_all('node_modules') or {
		eprintln('❌ failed to create node_modules: ${err.msg()}')
		return
	}

	for name, _ in root_manifest.dependencies {
		install_package_tree(ctx, cache_dir, name, 'node_modules') or {
			eprintln('❌ failed to install ${name}: ${err.msg()}')
			return
		}
	}

	sync_bun_lockfile()

	elapsed_ms := time.since(start).milliseconds()
	println('✅ vun-i finished in ${elapsed_ms}ms')
}

fn read_package_json(path string) !PackageJson {
	data := os.read_file(path)!
	return json.decode(PackageJson, data)!
}

fn resolve_dependency(mut ctx InstallContext, name string, spec string) !ResolvedPackage {
	key := package_key(name, spec)
	if key in ctx.resolved {
		return ctx.resolved[key]
	}

	registry := fetch_registry(name)!
	version := pick_version(registry, spec)!
	version_meta := registry.versions[version]
	if version_meta.dist.tarball == '' {
		return error('missing tarball for ${name}@${version}')
	}

	resolved := ResolvedPackage{
		name:         name
		version:      version
		tarball:      version_meta.dist.tarball
		dependencies: version_meta.dependencies.clone()
	}
	ctx.resolved[key] = resolved

	for dep_name, dep_spec in resolved.dependencies {
		resolve_dependency(mut ctx, dep_name, dep_spec)!
	}

	return resolved
}

fn fetch_registry(name string) !NpmRegistry {
	url := '${registry_url}/${name}'
	resp := http.get(url)!
	if resp.status_code != 200 {
		return error('registry lookup failed for ${name}: HTTP ${resp.status_code}')
	}
	return json.decode(NpmRegistry, resp.body)!
}

fn pick_version(registry NpmRegistry, spec string) !string {
	trimmed := spec.trim_space()
	if trimmed == '' {
		return error('empty version spec')
	}
	if trimmed in registry.versions {
		return trimmed
	}
	if trimmed in registry.dist_tags {
		return registry.dist_tags[trimmed]
	}

	mut candidates := []string{}
	for version, _ in registry.versions {
		if version_matches_spec(version, trimmed) {
			candidates << version
		}
	}
	if candidates.len == 0 {
		return error('no version matched spec ${spec}')
	}
	candidates.sort_with_compare(fn (a &string, b &string) int {
		return compare_semver_desc(*a, *b)
	})
	return candidates[0]
}

fn version_matches_spec(version string, spec string) bool {
	trimmed := spec.trim_space()
	if trimmed == '*' || trimmed == 'latest' {
		return true
	}
	if trimmed.starts_with('^') {
		base := trimmed[1..]
		v := parse_semver(version) or { return false }
		b := parse_semver(base) or { return false }
		if v.major != b.major {
			return false
		}
		return compare_semver(version, base) >= 0
	}
	if trimmed.starts_with('~') {
		base := trimmed[1..]
		v := parse_semver(version) or { return false }
		b := parse_semver(base) or { return false }
		if v.major != b.major || v.minor != b.minor {
			return false
		}
		return compare_semver(version, base) >= 0
	}
	if trimmed.starts_with('>=') {
		base := trimmed[2..]
		return compare_semver(version, base) >= 0
	}
	if trimmed.starts_with('<=') {
		base := trimmed[2..]
		return compare_semver(version, base) <= 0
	}
	return version == trimmed
}

struct Semver {
	major int
	minor int
	patch int
}

fn parse_semver(input string) !Semver {
	core := input.split('-')[0]
	parts := core.split('.')
	if parts.len < 3 {
		return error('invalid semver ${input}')
	}
	return Semver{
		major: parts[0].int()
		minor: parts[1].int()
		patch: parts[2].int()
	}
}

fn compare_semver(a string, b string) int {
	sa := parse_semver(a) or { return 0 }
	sb := parse_semver(b) or { return 0 }
	if sa.major != sb.major {
		return sa.major - sb.major
	}
	if sa.minor != sb.minor {
		return sa.minor - sb.minor
	}
	return sa.patch - sb.patch
}

fn compare_semver_desc(a string, b string) int {
	return compare_semver(b, a)
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
		println('♻️ cache hit ${pkg.name}@${pkg.version}')
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
	println('⬇️ cached ${pkg.name}@${pkg.version}')
}

fn install_package_tree(ctx InstallContext, cache_dir string, name string, target_node_modules string) ! {
	root_pkg := first_resolved_for_name(ctx, name)!
	mut seen := map[string]bool{}
	install_package_recursive(ctx, cache_dir, root_pkg, target_node_modules, mut seen)!
}

fn install_package_recursive(ctx InstallContext, cache_dir string, pkg ResolvedPackage, target_node_modules string, mut seen map[string]bool) ! {
	seen_key := '${target_node_modules}::${pkg.name}@${pkg.version}'
	if seen_key in seen {
		return
	}
	seen[seen_key] = true

	src_dir := package_cache_dir(cache_dir, pkg)
	dest_dir := os.join_path(target_node_modules, pkg.name)
	link_package_dir(src_dir, dest_dir)!

	child_node_modules := os.join_path(dest_dir, 'node_modules')
	for dep_name, dep_spec in pkg.dependencies {
		dep := resolved_by_exact_key(ctx, dep_name, dep_spec) or {
			first_resolved_for_name(ctx, dep_name)!
		}
		install_package_recursive(ctx, cache_dir, dep, child_node_modules, mut seen)!
	}
}

fn link_package_dir(src_dir string, dest_dir string) ! {
	if !os.exists(src_dir) {
		return error('source package dir not found: ${src_dir}')
	}
	if os.exists(dest_dir) {
		os.rmdir_all(dest_dir)!
	}
	os.mkdir_all(dest_dir)!

	entries := os.ls(src_dir)!
	for entry in entries {
		src_path := os.join_path(src_dir, entry)
		dest_path := os.join_path(dest_dir, entry)
		link_path_recursive(src_path, dest_path)!
	}
}

fn link_path_recursive(src string, dest string) ! {
	if os.is_dir(src) {
		os.mkdir_all(dest)!
		for entry in os.ls(src)! {
			link_path_recursive(os.join_path(src, entry), os.join_path(dest, entry))!
		}
		return
	}

	os.mkdir_all(os.dir(dest))!
	os.link(src, dest) or { os.cp(src, dest)! }
}

fn sync_bun_lockfile() {
	bun_path := os.find_abs_path_of_executable('bun') or { '' }
	if bun_path == '' {
		println('⚠️ bun not found; skipped bun.lock generation')
		return
	}
	println('🧾 syncing bun.lock via bun install --lockfile-only')
	result := os.execute('bun install --lockfile-only')
	if result.exit_code == 0 {
		println('🟢 bun.lock synced')
	} else {
		eprintln('⚠️ bun lockfile sync failed: ${result.output}')
	}
}

fn package_key(name string, spec string) string {
	return '${name}@${spec}'
}

fn bun_cache_dir() string {
	custom_cache := os.getenv('BUN_INSTALL_CACHE_DIR')
	if custom_cache != '' {
		return custom_cache
	}
	return os.join_path(os.home_dir(), bun_cache_suffix)
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
