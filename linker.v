module main

import os

struct HardlinkTask {
	src  string
	dest string
}

fn hardlink_tree(src_dir string, dest_dir string, task_ch chan HardlinkTask) ! {
	os.mkdir_all(dest_dir)!
	collect_hardlink_tasks(src_dir, dest_dir, task_ch)
}

fn collect_hardlink_tasks(src_dir string, dest_dir string, task_ch chan HardlinkTask) {
	entries := os.ls(src_dir) or { return }
	for entry in entries {
		if entry == 'node_modules' {
			continue
		}
		src := os.join_path(src_dir, entry)
		dest := os.join_path(dest_dir, entry)
		if os.is_dir(src) {
			os.mkdir_all(dest) or {}
			collect_hardlink_tasks(src, dest, task_ch)
		} else {
			task_ch <- HardlinkTask{src, dest}
		}
	}
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
