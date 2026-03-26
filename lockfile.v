module main

import os

fn sync_bun_lockfile(root_manifest PackageJson, ctx InstallContext, cache_dir string) {
	write_bun_lock(root_manifest, ctx, cache_dir) or {
		eprintln('⚠️ failed to write bun.lock: ${err.msg()}')
	}
}

fn sync_npm_lockfile() {
	npm_path := os.find_abs_path_of_executable('npm') or { '' }
	if npm_path == '' {
		println('⚠️ npm not found; skipped package-lock.json generation')
		return
	}
	println('🧾 syncing package-lock.json via npm install --package-lock-only')
	mut p := os.new_process(npm_path)
	p.set_args(['install', '--package-lock-only'])
	p.set_redirect_stdio()
	p.run()
	p.wait()
	if p.code == 0 {
		println('🟢 package-lock.json synced')
	} else {
		eprintln('⚠️ npm lockfile sync failed')
	}
	p.close()
}

