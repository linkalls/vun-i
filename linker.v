module main

import os

fn link_store_dependency(parent InstalledPackage, child InstalledPackage) ! {
	mut dest := os.join_path(store_node_modules_dir(parent), child.pkg.name)
	if child.pkg.name == parent.pkg.name {
		dest = os.join_path(store_node_modules_dir(parent), 'node_modules', child.pkg.name)
	}
	target := relative_path(os.dir(dest), store_package_target(child))
	ensure_package_link(target, store_package_target(child), dest)!
}

fn link_hidden_store_dependency(installed_pkg InstalledPackage) ! {
	dest := os.join_path(hidden_store_node_modules_dir(), installed_pkg.pkg.name)
	target := relative_path(os.dir(dest), store_package_target(installed_pkg))
	ensure_package_link(target, store_package_target(installed_pkg), dest)!
}

fn link_root_dependency(installed_pkg InstalledPackage) ! {
	dest := os.join_path('node_modules', installed_pkg.pkg.name)
	target := relative_path(os.dir(dest), store_package_target(installed_pkg))
	ensure_package_link(target, store_package_target(installed_pkg), dest)!
}

fn ensure_package_link(target string, fallback_target string, dest string) ! {
	if os.exists(dest) || os.is_link(dest) {
		os.rm(dest) or { os.rmdir_all(dest) or {} }
	}
	os.mkdir_all(os.dir(dest))!
	if try_symlink_or_junction(target, fallback_target, dest) {
		return
	}
	link_path_recursive(fallback_target, dest)!
}

fn ensure_file_link(target string, fallback_target string, dest string) ! {
	if os.exists(dest) || os.is_link(dest) {
		os.rm(dest) or { os.rmdir_all(dest) or {} }
	}
	os.mkdir_all(os.dir(dest))!
	if try_symlink_or_junction(target, fallback_target, dest) {
		return
	}
	os.link(fallback_target, dest) or { os.cp(fallback_target, dest)! }
}

fn try_symlink_or_junction(target string, fallback_target string, dest string) bool {
	os.symlink(target, dest) or {
		if os.user_os() == 'windows' {
			junction_cmd := 'cmd /c mklink /J "${dest}" "${windows_abs_path(fallback_target)}"'
			junction_result := os.execute(junction_cmd)
			if junction_result.exit_code == 0 {
				return true
			}
		}
		return false
	}
	return true
}

fn windows_abs_path(path string) string {
	if os.is_abs_path(path) {
		return path
	}
	return os.join_path(os.getwd(), path)
}

fn link_package_dir(src_dir string, dest_dir string) ! {
	if !os.exists(src_dir) {
		return error('source package dir not found: ${src_dir}')
	}
	if os.exists(dest_dir) {
		os.rmdir_all(dest_dir)!
	}
	os.mkdir_all(dest_dir)!

	for entry in os.ls(src_dir)! {
		if entry == 'node_modules' {
			continue
		}
		link_path_recursive(os.join_path(src_dir, entry), os.join_path(dest_dir, entry))!
	}
}

fn link_path_recursive(src string, dest string) ! {
	if os.is_dir(src) {
		os.mkdir_all(dest)!
		for entry in os.ls(src)! {
			link_path_recursive(os.join_path(src, entry), os.join_path(dest, entry))!
		}
		return
	}

	os.mkdir_all(os.dir(dest))!
	os.link(src, dest) or { os.cp(src, dest)! }
}
