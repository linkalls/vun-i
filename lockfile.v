module main

import os

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

fn sync_npm_lockfile() {
	npm_path := os.find_abs_path_of_executable('npm') or { '' }
	if npm_path == '' {
		println('⚠️ npm not found; skipped package-lock.json generation')
		return
	}
	println('🧾 syncing package-lock.json via npm install --package-lock-only')
	result := os.execute('npm install --package-lock-only')
	if result.exit_code == 0 {
		println('🟢 package-lock.json synced')
	} else {
		eprintln('⚠️ npm lockfile sync failed: ${result.output}')
	}
}

