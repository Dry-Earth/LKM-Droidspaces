/* SPDX-License-Identifier: GPL-2.0-only */
/* FUSE request credential mapping for the hummer 6.6 tree.
 * Recompiled from fs/fuse/dev.c so from_kuid()/from_kgid() perform real
 * user-namespace conversion instead of the CONFIG_USER_NS=n stubs.
 */
#include "fs/fuse/fuse_i.h"
#include <linux/file.h>
#include <linux/slab.h>
#include <linux/user_namespace.h>
#include <linux/sched/signal.h>
#include "live-fuse.h"

extern struct kmem_cache *fuse_req_cachep;

#define fuse_get_req ds_userns_fuse_get_req
#define fuse_force_creds ds_userns_fuse_force_creds

static void ds_fuse_request_init(struct fuse_mount *fm, struct fuse_req *req)
{
	INIT_LIST_HEAD(&req->list);
	INIT_LIST_HEAD(&req->intr_entry);
	init_waitqueue_head(&req->waitq);
	refcount_set(&req->count, 1);
	__set_bit(FR_PENDING, &req->flags);
	req->fm = fm;
}

static struct fuse_req *ds_fuse_request_alloc(struct fuse_mount *fm, gfp_t flags)
{
	struct fuse_req *req = kmem_cache_zalloc(fuse_req_cachep, flags);

	if (req)
		ds_fuse_request_init(fm, req);
	return req;
}

static void ds_fuse_request_free(struct fuse_req *req)
{
	kmem_cache_free(fuse_req_cachep, req);
}

static bool ds_fuse_block_alloc(struct fuse_conn *fc, bool for_background)
{
	return !fc->initialized || (for_background && fc->blocked);
}

static void ds_fuse_drop_waiting(struct fuse_conn *fc)
{
	if (atomic_dec_and_test(&fc->num_waiting) &&
	    !READ_ONCE(fc->connected)) {
		wake_up_all(&fc->blocked_waitq);
	}
}

static void ds_fuse_put_request(struct fuse_req *req)
{
	struct fuse_conn *fc = req->fm->fc;

	if (refcount_dec_and_test(&req->count)) {
		if (test_bit(FR_BACKGROUND, &req->flags)) {
			spin_lock(&fc->bg_lock);
			if (!fc->blocked)
				wake_up(&fc->blocked_waitq);
			spin_unlock(&fc->bg_lock);
		}

		if (test_bit(FR_WAITING, &req->flags)) {
			__clear_bit(FR_WAITING, &req->flags);
			ds_fuse_drop_waiting(fc);
		}

		ds_fuse_request_free(req);
	}
}

struct fuse_req *fuse_get_req(struct fuse_mount *fm, bool for_background)
{
	struct fuse_conn *fc = fm->fc;
	struct fuse_req *req;
	int err;

	atomic_inc(&fc->num_waiting);

	if (ds_fuse_block_alloc(fc, for_background)) {
		err = -EINTR;
		if (wait_event_killable_exclusive(fc->blocked_waitq,
				!ds_fuse_block_alloc(fc, for_background)))
			goto out;
	}
	/* Matches smp_wmb() in fuse_set_initialized() */
	smp_rmb();

	err = -ENOTCONN;
	if (!fc->connected)
		goto out;

	err = -ECONNREFUSED;
	if (fc->conn_error)
		goto out;

	req = ds_fuse_request_alloc(fm, GFP_KERNEL);
	err = -ENOMEM;
	if (!req) {
		if (for_background)
			wake_up(&fc->blocked_waitq);
		goto out;
	}

	req->in.h.uid = from_kuid(fc->user_ns, current_fsuid());
	req->in.h.gid = from_kgid(fc->user_ns, current_fsgid());
	req->in.h.pid = pid_nr_ns(task_pid(current), fc->pid_ns);

	__set_bit(FR_WAITING, &req->flags);
	if (for_background)
		__set_bit(FR_BACKGROUND, &req->flags);

	if (unlikely(req->in.h.uid == ((uid_t)-1) ||
		     req->in.h.gid == ((gid_t)-1))) {
		ds_fuse_put_request(req);
		return ERR_PTR(-EOVERFLOW);
	}
	return req;

out:
	ds_fuse_drop_waiting(fc);
	return ERR_PTR(err);
}

void fuse_force_creds(struct fuse_req *req)
{
	struct fuse_conn *fc = req->fm->fc;

	req->in.h.uid = from_kuid_munged(fc->user_ns, current_fsuid());
	req->in.h.gid = from_kgid_munged(fc->user_ns, current_fsgid());
	req->in.h.pid = pid_nr_ns(task_pid(current), fc->pid_ns);
}
