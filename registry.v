module main

import json
import net.http
import os
import runtime
import sync
import x.json2

struct ResolvablePackage {
	name string
	spec string
}

// NpmRegistryMeta holds only the lightweight per-package data needed to resolve
// a spec to a concrete version: the dist-tags map and a sorted list of all
// published version strings (newest-first). Individual NpmVersion metadata is
// loaded separately via fetch_version_meta so warm runs never parse the full
// 500 KB+ registry JSON.
struct NpmRegistryMeta {
	dist_tags    map[string]string
	version_keys []string
}

struct ResolveSharedState {
mut:
	resolved      map[string]ResolvedPackage
	meta_cache    map[string]NpmRegistryMeta // keyed by package name
	version_cache map[string]NpmVersion      // keyed by "name@version"
	pending       int
	mu            &sync.Mutex = sync.new_mutex()
}

// done decrements the pending counter and closes the channel when all work is finished.
fn (mut s ResolveSharedState) done(work_ch chan ResolvablePackage) {
	s.mu.@lock()
	s.pending--
	should_close := s.pending == 0
	s.mu.unlock()
	if should_close {
		work_ch.close()
	}
}

fn read_package_json(path string) !PackageJson {
	data := os.read_file(path)!
	return json.decode(PackageJson, data)!
}

fn resolve_all_dependencies(mut ctx InstallContext, root_deps map[string]string, cache_dir string) ! {
	if root_deps.len == 0 {
		return
	}

	// Buffer sized to hold a large dependency graph without blocking producers.
	work_ch := chan ResolvablePackage{cap: root_deps.len * 64 + 1024}

	mut state := ResolveSharedState{
		resolved: ctx.resolved.clone()
		pending:  root_deps.len
	}

	for name, spec in root_deps {
		work_ch <- ResolvablePackage{name, spec}
	}

	// Use more workers than CPUs for network I/O-bound resolution.
	num_workers := runtime.nr_cpus() * 4
	mut wg := sync.new_waitgroup()
	wg.add(num_workers)

	for _ in 0 .. num_workers {
		spawn fn (work_ch chan ResolvablePackage, state_ptr &ResolveSharedState, cache_dir string, mut wg sync.WaitGroup) {
			mut state := unsafe { &ResolveSharedState(state_ptr) }
			for {
				item := <-work_ch or { break }
				key := package_key(item.name, item.spec)

				state.mu.@lock()
				already_resolved := key in state.resolved
				state.mu.unlock()
				if already_resolved {
					state.done(work_ch)
					continue
				}

				// Check in-memory meta cache (dist-tags + version list) before
				// hitting disk/network.
				state.mu.@lock()
				has_meta := item.name in state.meta_cache
				mut meta := if has_meta { state.meta_cache[item.name] } else { NpmRegistryMeta{} }
				state.mu.unlock()
				if !has_meta {
					meta = fetch_registry_meta(item.name, cache_dir) or {
						state.done(work_ch)
						continue
					}
					state.mu.@lock()
					state.meta_cache[item.name] = meta
					state.mu.unlock()
				}

				version := pick_version_from_meta(meta, item.spec) or {
					state.done(work_ch)
					continue
				}

				// Check in-memory version metadata cache.
				ver_key := '${item.name}@${version}'
				state.mu.@lock()
				has_ver := ver_key in state.version_cache
				mut version_meta := if has_ver { state.version_cache[ver_key] } else { NpmVersion{} }
				state.mu.unlock()
				if !has_ver {
					version_meta = fetch_version_meta(item.name, version, cache_dir) or {
						state.done(work_ch)
						continue
					}
					state.mu.@lock()
					state.version_cache[ver_key] = version_meta
					state.mu.unlock()
				}

				if version_meta.dist.tarball == '' {
					state.done(work_ch)
					continue
				}

				resolved := ResolvedPackage{
					name:              item.name
					version:           version
					tarball:           version_meta.dist.tarball
					dependencies:      version_meta.dependencies.clone()
					peer_dependencies: version_meta.peer_dependencies.clone()
					bin:               version_meta.bin.clone()
				}

				mut new_deps := []ResolvablePackage{}
				state.mu.@lock()
				if key !in state.resolved {
					state.resolved[key] = resolved
					for dep_name, dep_spec in resolved.dependencies {
						dep_key := package_key(dep_name, dep_spec)
						if dep_key !in state.resolved {
							// Increment before enqueue so done() can't close prematurely.
							state.pending++
							new_deps << ResolvablePackage{dep_name, dep_spec}
						}
					}
				}
				state.pending--
				should_close := state.pending == 0
				state.mu.unlock()

				for dep in new_deps {
					work_ch <- dep
				}

				if should_close {
					work_ch.close()
				}
			}
			wg.done()
		}(work_ch, &state, cache_dir, mut wg)
	}
	wg.wait()

	ctx.resolved = state.resolved.clone()
}

fn resolve_dependency(mut ctx InstallContext, name string, spec string, cache_dir string) !ResolvedPackage {
	key := package_key(name, spec)
	if key in ctx.resolved {
		return ctx.resolved[key]
	}

	meta := fetch_registry_meta(name, cache_dir)!
	version := pick_version_from_meta(meta, spec)!
	version_meta := fetch_version_meta(name, version, cache_dir)!
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
		resolve_dependency(mut ctx, dep_name, dep_spec, cache_dir)!
	}

	return resolved
}

// registry_cache_dir returns the per-package directory inside the registry
// cache: `{cache_dir}/registry/{safe_name}` where safe_name replaces `/` with
// `+` so that scoped packages (`@scope/pkg`) don't create nested dirs.
fn registry_cache_dir(cache_dir string, name string) string {
	safe_name := name.replace('/', '+')
	return os.join_path(cache_dir, 'registry', safe_name)
}

// fetch_registry_meta returns the lightweight NpmRegistryMeta for a package
// (dist-tags and the sorted list of all published version strings).
//
// Disk cache layout (new format):
//   {cache_dir}/registry/{safe_name}/dist-tags.json  — map[string]string
//   {cache_dir}/registry/{safe_name}/versions.json   — []string (newest-first)
//
// Migration: if the old single-file cache
//   {cache_dir}/registry/{safe_name}.json
// is present it is parsed and the new split files are written from it, so
// users upgrading do not trigger an extra network round-trip.
fn fetch_registry_meta(name string, cache_dir string) !NpmRegistryMeta {
	reg_dir := registry_cache_dir(cache_dir, name)
	dt_path := os.join_path(reg_dir, 'dist-tags.json')
	ver_path := os.join_path(reg_dir, 'versions.json')

	// 1. Fast path: both slim files already exist.
	if os.exists(dt_path) && os.exists(ver_path) {
		dt_data := os.read_file(dt_path) or { '' }
		ver_data := os.read_file(ver_path) or { '' }
		if dt_data != '' && ver_data != '' {
			dist_tags := json.decode(map[string]string, dt_data) or { map[string]string{} }
			version_keys := json.decode([]string, ver_data) or { []string{} }
			if version_keys.len > 0 {
				return NpmRegistryMeta{
					dist_tags:    dist_tags
					version_keys: version_keys
				}
			}
		}
	}

	// 2. Migration path: old single-file cache exists — split it without a
	//    network request.
	safe_name := name.replace('/', '+')
	old_path := os.join_path(cache_dir, 'registry', '${safe_name}.json')
	if os.exists(old_path) {
		if data := os.read_file(old_path) {
			if full_reg := json.decode(NpmRegistry, data) {
				meta := write_split_registry_cache(full_reg, reg_dir)
				if meta.version_keys.len > 0 {
					return meta
				}
			}
		}
	}

	// 3. Cold path: fetch the full packument from npm and persist split files.
	url := '${registry_url}/${name}'
	resp := http.get(url)!
	if resp.status_code != 200 {
		return error('registry lookup failed for ${name}: HTTP ${resp.status_code}')
	}
	full_reg := json.decode(NpmRegistry, resp.body)!
	return write_split_registry_cache(full_reg, reg_dir)
}

// write_split_registry_cache persists the slim files from a full NpmRegistry
// and returns the resulting NpmRegistryMeta.  Individual version JSON files are
// also written here so that subsequent fetch_version_meta calls hit disk only.
// Write failures are silently swallowed — the in-memory meta is always returned.
fn write_split_registry_cache(full_reg NpmRegistry, reg_dir string) NpmRegistryMeta {
	os.mkdir_all(reg_dir) or {}

	// Write dist-tags.
	dt_path := os.join_path(reg_dir, 'dist-tags.json')
	os.write_file(dt_path, json.encode(full_reg.dist_tags)) or {}

	// Build sorted version list (newest first) and write it.
	mut keys := full_reg.versions.keys()
	keys.sort_with_compare(fn (a &string, b &string) int {
		return compare_semver_desc(*a, *b)
	})
	ver_path := os.join_path(reg_dir, 'versions.json')
	os.write_file(ver_path, json.encode(keys)) or {}

	// Write per-version slim files so warm runs never need to re-parse the
	// full packument.
	for ver_str, ver_meta in full_reg.versions {
		vpath := os.join_path(reg_dir, '${ver_str}.json')
		os.write_file(vpath, json.encode(ver_meta)) or {}
	}

	return NpmRegistryMeta{
		dist_tags:    full_reg.dist_tags
		version_keys: keys
	}
}

// fetch_version_meta returns the NpmVersion metadata for a specific resolved
// version.  On warm runs the slim per-version file is read from disk; on cold
// runs (or when the per-version file is absent) the single-version npm endpoint
// is used so only one small JSON response is needed rather than the full
// packument.
fn fetch_version_meta(name string, version string, cache_dir string) !NpmVersion {
	reg_dir := registry_cache_dir(cache_dir, name)
	vpath := os.join_path(reg_dir, '${version}.json')

	// 1. Warm path: slim version file exists on disk.
	if os.exists(vpath) {
		data := os.read_file(vpath) or { '' }
		if data != '' {
			if ver_meta := json.decode(NpmVersion, data) {
				return ver_meta
			}
		}
	}

	// 2. Cold path: fetch the single-version packument.
	url := '${registry_url}/${name}/${version}'
	resp := http.get(url)!
	if resp.status_code != 200 {
		return error('registry version lookup failed for ${name}@${version}: HTTP ${resp.status_code}')
	}
	os.mkdir_all(reg_dir) or {}
	os.write_file(vpath, resp.body) or {}
	return json.decode(NpmVersion, resp.body)!
}

// pick_version_from_meta resolves a dependency spec to a concrete version
// string using only the lightweight NpmRegistryMeta (dist-tags + version list).
fn pick_version_from_meta(meta NpmRegistryMeta, spec string) !string {
	trimmed := spec.trim_space()
	if trimmed == '' {
		return error('empty version spec')
	}
	// Dist-tag match first — O(1) map lookup, handles the common 'latest' case.
	if trimmed in meta.dist_tags {
		return meta.dist_tags[trimmed]
	}
	// Single O(n) pass through version_keys (pre-sorted newest-first).  An
	// exact version match (vk == trimmed) is caught by version_matches_spec
	// too, so no separate loop is needed.  The first match is the best one.
	for vk in meta.version_keys {
		if version_matches_spec(vk, trimmed) {
			return vk
		}
	}
	return error('no version matched spec ${spec}')
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
		return compare_semver(version, trimmed[2..]) >= 0
	}
	if trimmed.starts_with('<=') {
		return compare_semver(version, trimmed[2..]) <= 0
	}
	if trimmed.starts_with('>') {
		return compare_semver(version, trimmed[1..]) > 0
	}
	if trimmed.starts_with('<') {
		return compare_semver(version, trimmed[1..]) < 0
	}
	return version == trimmed
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
	return Semver{major, minor, patch}
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
