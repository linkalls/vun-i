module main

import os

fn link_root_bins(installed_pkg InstalledPackage) ! {
	for bin_name, bin_target in installed_pkg.pkg.bin {
		dest := os.join_path('node_modules', '.bin', bin_name)
		target_path := os.join_path('node_modules', installed_pkg.pkg.name, bin_target)
		target := relative_path(os.dir(dest), target_path)
		ensure_file_link(target, target_path, dest)!
	}
}
