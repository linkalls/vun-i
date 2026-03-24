module main

import json
import net.http
import os
import x.json2

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
