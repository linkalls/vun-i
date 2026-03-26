module main

import os
import runtime
import sync

struct InstallJob {
	installed_pkg InstalledPackage
	providers     map[string]ResolvedPackage
	cache_dir     string
}

// collect_install_jobs performs a BFS over the dependency graph and returns a
// deduplicated, flat list of all packages that need to be hardlinked.
fn collect_install_jobs(ctx &InstallContext, cache_dir string, root_deps map[string]ResolvedPackage) []InstallJob {
	mut jobs := []InstallJob{}
	mut visited := map[string]bool{}
	mut queue := []InstallJob{}

	for _, pkg in root_deps {
		root_peers := select_matching_peers(pkg.peer_dependencies, root_deps)
		installed := InstalledPackage{pkg, root_peers}
		key := store_key_for(installed)
		if key in visited {
			continue
		}
		visited[key] = true
		providers := providers_for_child(root_deps, installed)
		queue << InstallJob{installed, providers, cache_dir}
	}

	for queue.len > 0 {
		job := queue[0]
		queue = queue[1..]
		jobs << job

		child_providers := providers_for_child(job.providers, job.installed_pkg)
		for dep_name, dep_spec in job.installed_pkg.pkg.dependencies {
			dep := resolved_by_exact_key(*ctx, dep_name, dep_spec) or {
				first_resolved_for_name(*ctx, dep_name) or { continue }
			}
			dep_peers := select_matching_peers(dep.peer_dependencies, child_providers)
			child := InstalledPackage{dep, dep_peers}
			child_key := store_key_for(child)
			if child_key in visited {
				continue
			}
			visited[child_key] = true
			queue << InstallJob{child, child_providers, cache_dir}
		}
	}
	return jobs
}

// install_all_jobs processes all hardlink jobs using a single global worker pool.
// Hardlink tasks from all packages are drained by one shared pool of workers,
// eliminating the per-package thread create/destroy overhead.
// Bin linking is deferred to a second pass after all hardlinks complete.
fn install_all_jobs(mut ctx InstallContext, jobs []InstallJob) ! {
	if jobs.len == 0 {
		return
	}

	// Single global hardlink worker pool shared across all packages.
	// Buffer sized to ~64 files per package to avoid blocking collectors.
	task_ch := chan HardlinkTask{cap: jobs.len * 64 + 256}
	num_link_workers := runtime.nr_cpus() * 2
	mut link_wg := sync.new_waitgroup()
	link_wg.add(num_link_workers)
	for _ in 0 .. num_link_workers {
		spawn fn (task_ch chan HardlinkTask, wg_ptr &sync.WaitGroup) {
			mut wg := unsafe { &sync.WaitGroup(wg_ptr) }
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
		}(task_ch, link_wg)
	}

	job_ch := chan InstallJob{cap: jobs.len + 1}
	for job in jobs {
		job_ch <- job
	}
	job_ch.close()

	// Collect packages that need bin linking after hardlinks complete.
	bin_ch := chan InstalledPackage{cap: jobs.len}

	num_workers := runtime.nr_cpus() * 2
	mut wg := sync.new_waitgroup()
	wg.add(num_workers)

	for _ in 0 .. num_workers {
		spawn fn (job_ch chan InstallJob, install_ctx_ptr &InstallContext, task_ch chan HardlinkTask, bin_ch chan InstalledPackage, mut wg sync.WaitGroup) {
			mut lctx := unsafe { &InstallContext(install_ctx_ptr) }
			for {
				job := <-job_ch or { break }
				source_dir := package_cache_dir(job.cache_dir, job.installed_pkg.pkg)
				dest_dir := os.join_path('node_modules', job.installed_pkg.pkg.name)

				lctx.mu.@lock()
				key := store_key_for(job.installed_pkg)
				already := key in lctx.installed
				if !already {
					lctx.installed[key] = true
				}
				lctx.mu.unlock()
				if already {
					continue
				}

				if !os.exists(dest_dir) {
					hardlink_tree(source_dir, dest_dir, task_ch) or {
						eprintln('⚠️ hardlink failed for ${job.installed_pkg.pkg.name}: ${err.msg()}')
						continue
					}
				}
				bin_ch <- job.installed_pkg
			}
			wg.done()
		}(job_ch, &ctx, task_ch, bin_ch, mut wg)
	}
	wg.wait()

	// All hardlink tasks are now enqueued; drain the pool before linking bins.
	task_ch.close()
	link_wg.wait()

	// Second pass: link bins now that all hardlinks are in place.
	bin_ch.close()
	for {
		installed_pkg := <-bin_ch or { break }
		link_root_bins(installed_pkg) or {}
	}
}

fn select_matching_peers(peer_specs map[string]string, providers map[string]ResolvedPackage) map[string]ResolvedPackage {
	mut peers := map[string]ResolvedPackage{}
	for peer_name, peer_spec in peer_specs {
		if peer_name !in providers {
			continue
		}
		provider := providers[peer_name]
		if version_matches_spec(provider.version, peer_spec) || peer_spec.trim_space() == '*' {
			peers[peer_name] = provider
		}
	}
	return peers
}

fn providers_for_child(parent_providers map[string]ResolvedPackage, installed_pkg InstalledPackage) map[string]ResolvedPackage {
	mut providers := parent_providers.clone()
	providers[installed_pkg.pkg.name] = installed_pkg.pkg
	for peer_name, peer_pkg in installed_pkg.peers {
		providers[peer_name] = peer_pkg
	}
	return providers
}

fn resolved_by_exact_key(ctx InstallContext, name string, spec string) !ResolvedPackage {
	key := package_key(name, spec)
	if key !in ctx.resolved {
		return error('missing resolved package ${key}')
	}
	return ctx.resolved[key]
}

fn first_resolved_for_name(ctx InstallContext, name string) !ResolvedPackage {
	for _, pkg in ctx.resolved {
		if pkg.name == name {
			return pkg
		}
	}
	return error('package not resolved: ${name}')
}

fn package_key(name string, spec string) string {
	return '${name}@${spec}'
}
