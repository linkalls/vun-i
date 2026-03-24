module main

import os

fn hidden_store_node_modules_dir() string {
	return os.join_path('node_modules', bun_store_dir, 'node_modules')
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

fn store_package_root(installed_pkg InstalledPackage) string {
	return os.join_path('node_modules', bun_store_dir, store_folder_name(installed_pkg))
}

fn store_node_modules_dir(installed_pkg InstalledPackage) string {
	return os.join_path(store_package_root(installed_pkg), 'node_modules')
}

fn store_package_target(installed_pkg InstalledPackage) string {
	return os.join_path(store_node_modules_dir(installed_pkg), installed_pkg.pkg.name)
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
