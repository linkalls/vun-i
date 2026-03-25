module main

import os

fn hardlink_dir_parallel(src_dir string, dest_dir string) ! {
	os.mkdir_all(dest_dir)!
	entries := os.ls(src_dir)!
	mut threads := []thread !{}
	for entry in entries {
		if entry == 'node_modules' {
			continue
		}
		src := os.join_path(src_dir, entry)
		dest := os.join_path(dest_dir, entry)
		threads << spawn hardlink_entry(src, dest)
	}
	for t in threads {
		t.wait()!
	}
}

fn hardlink_entry(src string, dest string) ! {
	if os.is_dir(src) {
		hardlink_dir_parallel(src, dest)!
		return
	}
	os.mkdir_all(os.dir(dest))!
	os.link(src, dest) or { os.cp(src, dest)! }
}

fn ensure_file_link(target string, fallback_target string, dest string) ! {
	remove_existing_path(dest)
	os.mkdir_all(os.dir(dest))!
	os.symlink(target, dest) or {
		os.link(fallback_target, dest) or { os.cp(fallback_target, dest)! }
	}
}

fn remove_existing_path(path string) {
	if !(os.exists(path) || os.is_link(path)) {
		return
	}
	os.rm(path) or { os.rmdir_all(path) or {} }
}
