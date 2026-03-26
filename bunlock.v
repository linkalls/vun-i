module main

import crypto.sha512
import encoding.base64
import os

// sha512_integrity computes the sha512 integrity hash of tarball data in the
// format expected by bun.lock: "sha512-<base64>".
fn sha512_integrity(data []u8) string {
	digest := sha512.sum512(data)
	return 'sha512-' + base64.encode(digest)
}

// write_bun_lock generates a bun.lock file directly from the resolved package
// graph, without requiring the bun binary to be installed.
fn write_bun_lock(root_manifest PackageJson, ctx InstallContext, cache_dir string) ! {
	// Root workspace dependencies
	mut dep_parts := []string{}
	for name, spec in root_manifest.dependencies {
		dep_parts << '        "${name}": "${spec}"'
	}
	dep_block := if dep_parts.len > 0 {
		dep_parts.join(',\n')
	} else {
		''
	}

	// Package entries
	mut pkg_parts := []string{}
	for _, pkg in ctx.resolved {
		mut fields := []string{}

		fields << '      "resolved": "${pkg.tarball}"'

		// integrity: read from cache if saved during prefetch
		integrity_path := os.join_path(package_cache_dir(cache_dir, pkg), '.integrity')
		if os.exists(integrity_path) {
			integrity := os.read_file(integrity_path) or { '' }
			trimmed := integrity.trim_space()
			if trimmed != '' {
				fields << '      "integrity": "${trimmed}"'
			}
		}

		if pkg.dependencies.len > 0 {
			mut inner := []string{}
			for dep_name, dep_spec in pkg.dependencies {
				inner << '        "${dep_name}": "${dep_spec}"'
			}
			fields << '      "dependencies": {\n${inner.join(",\n")}\n      }'
		}

		if pkg.peer_dependencies.len > 0 {
			mut inner := []string{}
			for p_name, p_spec in pkg.peer_dependencies {
				inner << '        "${p_name}": "${p_spec}"'
			}
			fields << '      "peerDependencies": {\n${inner.join(",\n")}\n      }'
		}

		pkg_parts << '    "${pkg.name}@${pkg.version}": {\n${fields.join(",\n")}\n    }'
	}

	pkg_name := root_manifest.name
	content := '{
  "lockfileVersion": 0,
  "workspaces": {
    "": {
      "name": "${pkg_name}",
      "dependencies": {
${dep_block}
      }
    }
  },
  "packages": {
${pkg_parts.join(",\n")}
  }
}'

	os.write_file('bun.lock', content)!
	println('🔒 bun.lock written (${ctx.resolved.len} packages)')
}
