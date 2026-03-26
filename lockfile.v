module main

import os

fn sync_bun_lockfile() {
	bun_path := os.find_abs_path_of_executable('bun') or { '' }
	if bun_path == '' {
		println('⚠️ bun not found; skipped bun.lock generation')
		return
	}
	println('🧾 syncing bun.lock via bun install --lockfile-only')
	mut p := os.new_process(bun_path)
	p.set_args(['install', '--lockfile-only'])
	p.set_redirect_stdio()
	p.run()
	p.wait()
	if p.code == 0 {
		println('🟢 bun.lock synced')
	} else {
		eprintln('⚠️ bun lockfile sync failed')
	}
	p.close()
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

