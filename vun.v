module main

import json
import net.http
import os
import sync
import time
import x.json2

const registry_url = 'https://registry.npmjs.org'
const bun_store_dir = '.bun'

struct PackageJson {
	dependencies map[string]string
}

struct NpmRegistry {
	versions  map[string]NpmVersion
	dist_tags map[string]string @[json: 'dist-tags']
}

struct NpmVersion {
	name              string
	version           string
	dist              NpmDist
	dependencies      map[string]string
	peer_dependencies map[string]string @[json: 'peerDependencies']
	bin               map[string]string
}

struct NpmDist {
	tarball string
}

struct ResolvedPackage {
	name              string
	version           string
	tarball           string
	dependencies      map[string]string
	peer_dependencies map[string]string
	bin               map[string]string
}

struct InstallContext {
mut:
	root_dependencies map[string]ResolvedPackage
	resolved          map[string]ResolvedPackage
}

struct InstalledPackage {
	pkg   ResolvedPackage
	peers map[string]ResolvedPackage
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
		name:              name
		version:           version
		tarball:           version_meta.dist.tarball
		dependencies:      version_meta.dependencies.clone()
		peer_dependencies: version_meta.peer_dependencies.clone()
		bin:               version_meta.bin.clone()
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
	if trimmed.contains('||') {
		for part in trimmed.split('||') {
			if version_matches_spec(version, part.trim_space()) {
				return true
			}
		}
		return false
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
	if trimmed.starts_with('>') {
		base := trimmed[1..]
		return compare_semver(version, base) > 0
	}
	if trimmed.starts_with('<') {
		base := trimmed[1..]
		return compare_semver(version, base) < 0
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
	if parts.len == 0 || parts[0] == '' {
		return error('invalid semver ${input}')
	}
	major := parts[0].int()
	minor := if parts.len > 1 { parts[1].int() } else { 0 }
	patch := if parts.len > 2 { parts[2].int() } else { 0 }
	return Semver{
		major: major
		minor: minor
		patch: patch
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

fn hydrate_all_package_metadata(ctx InstallContext, cache_dir string) InstallContext {
	mut next := ctx
	for key, pkg in ctx.resolved {
		next.resolved[key] = hydrate_package_metadata(pkg, cache_dir)
	}
	for name, pkg in ctx.root_dependencies {
		next.root_dependencies[name] = hydrate_package_metadata(pkg, cache_dir)
	}
	return next
}

fn hydrate_package_metadata(pkg ResolvedPackage, cache_dir string) ResolvedPackage {
	manifest_path := os.join_path(package_cache_dir(cache_dir, pkg), 'package.json')
	if !os.exists(manifest_path) {
		return pkg
	}
	data := os.read_file(manifest_path) or { return pkg }
	manifest := json2.decode[json2.Any](data) or { return pkg }
	peer_dependencies := json_map_string(manifest, 'peerDependencies')
	bin := json_map_string(manifest, 'bin')
	return ResolvedPackage{
		...pkg
		peer_dependencies: if peer_dependencies.len > 0 {
			peer_dependencies
		} else {
			pkg.peer_dependencies
		}
		bin:               if bin.len > 0 { bin } else { pkg.bin }
	}
}

fn json_map_string(value json2.Any, key string) map[string]string {
	obj := value.as_map()
	if key !in obj {
		return map[string]string{}
	}
	entry := obj[key] or { return map[string]string{} }
	mut out := map[string]string{}
	if entry is string {
		out[key] = entry
		return out
	}
	entry_map := entry.as_map()
	for entry_key, entry_value in entry_map {
		if entry_value is string {
			out[entry_key] = entry_value
		}
	}
	return out
}

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
		child := InstalledPackage{
			pkg:   dep
			peers: dep_peers
		}
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

fn link_store_dependency(parent InstalledPackage, child InstalledPackage) ! {
	mut dest := os.join_path(store_node_modules_dir(parent), child.pkg.name)
	if child.pkg.name == parent.pkg.name {
		dest = os.join_path(store_node_modules_dir(parent), 'node_modules', child.pkg.name)
	}
	target := relative_path(os.dir(dest), store_package_target(child))
	ensure_package_link(target, store_package_target(child), dest)!
}

fn link_hidden_store_dependency(installed_pkg InstalledPackage) ! {
	dest := os.join_path(hidden_store_node_modules_dir(), installed_pkg.pkg.name)
	target := relative_path(os.dir(dest), store_package_target(installed_pkg))
	ensure_package_link(target, store_package_target(installed_pkg), dest)!
}

fn link_root_dependency(installed_pkg InstalledPackage) ! {
	dest := os.join_path('node_modules', installed_pkg.pkg.name)
	target := relative_path(os.dir(dest), store_package_target(installed_pkg))
	ensure_package_link(target, store_package_target(installed_pkg), dest)!
}

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

fn ensure_package_link(target string, fallback_target string, dest string) ! {
	if os.exists(dest) || os.is_link(dest) {
		os.rm(dest) or { os.rmdir_all(dest) or {} }
	}
	os.mkdir_all(os.dir(dest))!
	if try_symlink_or_junction(target, fallback_target, dest) {
		return
	}
	link_path_recursive(fallback_target, dest)!
}

fn ensure_file_link(target string, fallback_target string, dest string) ! {
	if os.exists(dest) || os.is_link(dest) {
		os.rm(dest) or { os.rmdir_all(dest) or {} }
	}
	os.mkdir_all(os.dir(dest))!
	if try_symlink_or_junction(target, fallback_target, dest) {
		return
	}
	os.link(fallback_target, dest) or { os.cp(fallback_target, dest)! }
}

fn try_symlink_or_junction(target string, fallback_target string, dest string) bool {
	os.symlink(target, dest) or {
		if os.user_os() == 'windows' {
			junction_cmd := 'cmd /c mklink /J "${dest}" "${windows_abs_path(fallback_target)}"'
			junction_result := os.execute(junction_cmd)
			if junction_result.exit_code == 0 {
				return true
			}
		}
		return false
	}
	return true
}

fn windows_abs_path(path string) string {
	if os.is_abs_path(path) {
		return path
	}
	base := os.getwd()
	return os.join_path(base, path)
}

fn link_package_dir(src_dir string, dest_dir string) ! {
	if !os.exists(src_dir) {
		return error('source package dir not found: ${src_dir}')
	}
	if os.exists(dest_dir) {
		os.rmdir_all(dest_dir)!
	}
	os.mkdir_all(dest_dir)!

	for entry in os.ls(src_dir)! {
		if entry == 'node_modules' {
			continue
		}
		link_path_recursive(os.join_path(src_dir, entry), os.join_path(dest_dir, entry))!
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

fn relative_path(from string, to string) string {
	from_norm := normalize_sep(from)
	to_norm := normalize_sep(to)
	from_parts := split_non_empty(from_norm)
	to_parts := split_non_empty(to_norm)

	mut i := 0
	for i < from_parts.len && i < to_parts.len && from_parts[i] == to_parts[i] {
		i++
	}

	mut out := []string{}
	for _ in i .. from_parts.len {
		out << '..'
	}
	for j in i .. to_parts.len {
		out << to_parts[j]
	}
	if out.len == 0 {
		return '.'
	}
	return out.join(os.path_separator.str())
}

fn normalize_sep(path string) string {
	return path.replace('\\', '/').trim_right('/')
}

fn split_non_empty(path string) []string {
	mut out := []string{}
	for part in path.split('/') {
		if part != '' && part != '.' {
			out << part
		}
	}
	return out
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

fn store_key_for(installed_pkg InstalledPackage) string {
	return store_folder_name(installed_pkg)
}

fn store_folder_name(installed_pkg InstalledPackage) string {
	peer_suffix := peer_hash_suffix(installed_pkg.peers)
	base_name := installed_pkg.pkg.name.replace('/', '+').replace('@', '@')
	return '${base_name}@${installed_pkg.pkg.version}${peer_suffix}'
}

fn peer_hash_suffix(peers map[string]ResolvedPackage) string {
	if peers.len == 0 {
		return ''
	}
	mut keys := peers.keys()
	keys.sort()
	mut parts := []string{}
	for key in keys {
		peer_pkg := peers[key]
		parts << '${peer_pkg.name}@${peer_pkg.version}'
	}
	hash := fnv1a64(parts.join('|'))
	return '+${hash}'
}

fn fnv1a64(input string) string {
	mut hash := u64(14695981039346656037)
	for ch in input.bytes() {
		hash = (hash ^ u64(ch)) * u64(1099511628211)
	}
	return '${hash:016x}'
}

fn hidden_store_node_modules_dir() string {
	return os.join_path('node_modules', bun_store_dir, 'node_modules')
}

fn store_package_root(installed_pkg InstalledPackage) string {
	return os.join_path('node_modules', bun_store_dir, store_folder_name(installed_pkg))
}

fn store_node_modules_dir(installed_pkg InstalledPackage) string {
	return os.join_path(store_package_root(installed_pkg), 'node_modules')
}

fn store_package_target(installed_pkg InstalledPackage) string {
	return os.join_path(store_node_modules_dir(installed_pkg), installed_pkg.pkg.name)
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
