module main

import sync

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
	installed         map[string]bool
	mu                &sync.Mutex = sync.new_mutex()
}

struct InstalledPackage {
	pkg   ResolvedPackage
	peers map[string]ResolvedPackage
}

struct Semver {
	major int
	minor int
	patch int
}
