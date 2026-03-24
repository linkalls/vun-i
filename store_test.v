module main

fn test_relative_path_basic() {
	got := relative_path('node_modules/.bun/react@1.0.0/node_modules', 'node_modules/.bun/scheduler@1.0.0/node_modules/scheduler')
	assert normalize_sep(got) == '../../scheduler@1.0.0/node_modules/scheduler'
}

fn test_relative_path_scoped_package() {
	got := relative_path('node_modules/.bun/@scope+pkg@1.0.0/node_modules/@scope', 'node_modules/.bun/@scope+dep@2.0.0/node_modules/@scope/dep')
	assert normalize_sep(got) == '../../../@scope+dep@2.0.0/node_modules/@scope/dep'
}

fn test_peer_hash_suffix_is_stable() {
	peers := {
		'react': ResolvedPackage{name: 'react', version: '19.0.0'}
		'zod':   ResolvedPackage{name: 'zod', version: '4.0.0'}
	}
	first := peer_hash_suffix(peers)
	second := peer_hash_suffix(peers)
	assert first == second
	assert first.len > 1
	assert first.starts_with('+')
}

fn test_store_folder_name_includes_peer_suffix() {
	installed := InstalledPackage{
		pkg: ResolvedPackage{name: 'react-dom', version: '19.0.0'}
		peers: {
			'react': ResolvedPackage{name: 'react', version: '19.0.0'}
		}
	}
	got := store_folder_name(installed)
	assert got.starts_with('react-dom@19.0.0+')
}

fn test_store_folder_name_without_peers() {
	installed := InstalledPackage{
		pkg: ResolvedPackage{name: '@expo/vector-icons', version: '1.2.3'}
		peers: map[string]ResolvedPackage{}
	}
	got := store_folder_name(installed)
	assert got == '@expo+vector-icons@1.2.3'
}
