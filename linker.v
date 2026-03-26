module main

import os
import runtime
import sync

struct HardlinkTask {
	src  string
	dest string
}

fn hardlink_tree(src_dir string, dest_dir string) ! {
	os.mkdir_all(dest_dir)!
	// Buffer sized to hold files from a large package without blocking the collector.
	task_ch := chan HardlinkTask{cap: 4096}

	collect_hardlink_tasks(src_dir, dest_dir, task_ch)
	task_ch.close()

	num_workers := runtime.nr_cpus()
	mut wg := sync.new_waitgroup()
	wg.add(num_workers)
	for _ in 0 .. num_workers {
		spawn fn (task_ch chan HardlinkTask, mut wg sync.WaitGroup) {
			for {
				task := <-task_ch or { break }
				os.mkdir_all(os.dir(task.dest)) or {}
				os.link(task.src, task.dest) or {
					os.cp(task.src, task.dest) or {
						eprintln('⚠️ failed to link or copy ${task.src}: ${err.msg()}')
					}
				}
			}
			wg.done()
		}(task_ch, mut wg)
	}
	wg.wait()
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
