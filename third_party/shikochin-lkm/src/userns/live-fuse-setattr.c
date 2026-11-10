/* SPDX-License-Identifier: GPL-2.0-only */
/* FUSE setattr/chown mapping for the hummer 6.6 tree.
 * Recompiled from fs/fuse/dir.c so iattr_to_fattr() uses real
 * from_kuid()/from_kgid() conversion instead of the USER_NS=n stubs.
 */
#include "fs/fuse/fuse_i.h"
#include <linux/file.h>
#include <linux/slab.h>
#include <linux/user_namespace.h>
#include <linux/pagemap.h>
#include <linux/writeback.h>
#include <linux/capability.h>
#include "live-fuse.h"

#define fuse_do_setattr ds_userns_fuse_do_setattr

static void __fuse_release_nowrite(struct inode *inode)
{
	struct fuse_inode *fi = get_fuse_inode(inode);

	BUG_ON(fi->writectr != FUSE_NOWRITE);
	fi->writectr = 0;
	fuse_flush_writepages(inode);
}

static void fuse_setattr_fill(struct fuse_conn *fc, struct fuse_args *args,
			      struct inode *inode,
			      struct fuse_setattr_in *inarg_p,
			      struct fuse_attr_out *outarg_p)
{
	args->opcode = FUSE_SETATTR;
	args->nodeid = get_node_id(inode);
	args->in_numargs = 1;
	args->in_args[0].size = sizeof(*inarg_p);
	args->in_args[0].value = inarg_p;
	args->out_numargs = 1;
	args->out_args[0].size = sizeof(*outarg_p);
	args->out_args[0].value = outarg_p;
}

int fuse_do_setattr(struct dentry *dentry, struct iattr *attr,
		    struct file *file)
{
	struct inode *inode = d_inode(dentry);
	struct fuse_mount *fm = get_fuse_mount(inode);
	struct fuse_conn *fc = fm->fc;
	struct fuse_inode *fi = get_fuse_inode(inode);
	struct address_space *mapping = inode->i_mapping;
	FUSE_ARGS(args);
	struct fuse_setattr_in inarg;
	struct fuse_attr_out outarg;
	bool is_truncate = false;
	bool is_wb = fc->writeback_cache && S_ISREG(inode->i_mode);
	loff_t oldsize;
	int err;
	bool trust_local_cmtime = is_wb;
	bool fault_blocked = false;
	u64 attr_version;

	if (!fc->default_permissions)
		attr->ia_valid |= ATTR_FORCE;

	err = setattr_prepare(&nop_mnt_idmap, dentry, attr);
	if (err)
		return err;

	if (attr->ia_valid & ATTR_SIZE) {
		if (WARN_ON(!S_ISREG(inode->i_mode)))
			return -EIO;
		is_truncate = true;
	}

	if (FUSE_IS_DAX(inode) && is_truncate) {
		filemap_invalidate_lock(mapping);
		fault_blocked = true;
		err = fuse_dax_break_layouts(inode, 0, -1);
		if (err) {
			filemap_invalidate_unlock(mapping);
			return err;
		}
	}

	if (attr->ia_valid & ATTR_OPEN) {
		/* This is coming from open(..., ... | O_TRUNC); */
		WARN_ON(!(attr->ia_valid & ATTR_SIZE));
		WARN_ON(attr->ia_size != 0);
		if (fc->atomic_o_trunc) {
			/*
			 * No need to send request to userspace, since actual
			 * truncation has already been done by OPEN.  But still
			 * need to truncate page cache.
			 */
			i_size_write(inode, 0);
			truncate_pagecache(inode, 0);
			goto out;
		}
		file = NULL;
	}

	/* Flush dirty data/metadata before non-truncate SETATTR */
	if (is_wb &&
	    attr->ia_valid &
			(ATTR_MODE | ATTR_UID | ATTR_GID | ATTR_MTIME_SET |
			 ATTR_TIMES_SET)) {
		err = write_inode_now(inode, true);
		if (err)
			return err;

		fuse_set_nowrite(inode);
		fuse_release_nowrite(inode);
	}

	if (is_truncate) {
		fuse_set_nowrite(inode);
		set_bit(FUSE_I_SIZE_UNSTABLE, &fi->state);
		if (trust_local_cmtime && attr->ia_size != inode->i_size)
			attr->ia_valid |= ATTR_MTIME | ATTR_CTIME;
	}

	memset(&inarg, 0, sizeof(inarg));
	memset(&outarg, 0, sizeof(outarg));
	iattr_to_fattr(fc, attr, &inarg, trust_local_cmtime);
	if (file) {
		struct fuse_file *ff = file->private_data;
		inarg.valid |= FATTR_FH;
		inarg.fh = ff->fh;
	}

	/* Kill suid/sgid for non-directory chown unconditionally */
	if (fc->handle_killpriv_v2 && !S_ISDIR(inode->i_mode) &&
	    attr->ia_valid & (ATTR_UID | ATTR_GID))
		inarg.valid |= FATTR_KILL_SUIDGID;

	if (attr->ia_valid & ATTR_SIZE) {
		/* For mandatory locking in truncate */
		inarg.valid |= FATTR_LOCKOWNER;
		inarg.lock_owner = fuse_lock_owner_id(fc, current->files);

		/* Kill suid/sgid for truncate only if no CAP_FSETID */
		if (fc->handle_killpriv_v2 && !capable(CAP_FSETID))
			inarg.valid |= FATTR_KILL_SUIDGID;
	}

	attr_version = fuse_get_attr_version(fm->fc);
	fuse_setattr_fill(fc, &args, inode, &inarg, &outarg);
	err = fuse_simple_request(fm, &args);
	if (err) {
		if (err == -EINTR)
			fuse_invalidate_attr(inode);
		goto error;
	}

	if (fuse_invalid_attr(&outarg.attr) ||
	    inode_wrong_type(inode, outarg.attr.mode)) {
		fuse_make_bad(inode);
		err = -EIO;
		goto error;
	}

	spin_lock(&fi->lock);
	/* the kernel maintains i_mtime locally */
	if (trust_local_cmtime) {
		if (attr->ia_valid & ATTR_MTIME)
			inode->i_mtime = attr->ia_mtime;
		if (attr->ia_valid & ATTR_CTIME)
			inode_set_ctime_to_ts(inode, attr->ia_ctime);
		/* FIXME: clear I_DIRTY_SYNC? */
	}

	if (fi->attr_version > attr_version) {
		/*
		 * Apply attributes, for example for fsnotify_change(), but set
		 * attribute timeout to zero.
		 */
		outarg.attr_valid = outarg.attr_valid_nsec = 0;
	}

	fuse_change_attributes_common(inode, &outarg.attr, NULL,
				      ATTR_TIMEOUT(&outarg),
				      fuse_get_cache_mask(inode));
	oldsize = inode->i_size;
	/* see the comment in fuse_change_attributes() */
	if (!is_wb || is_truncate)
		i_size_write(inode, outarg.attr.size);

	if (is_truncate) {
		/* NOTE: this may release/reacquire fi->lock */
		__fuse_release_nowrite(inode);
	}
	spin_unlock(&fi->lock);

	/*
	 * Only call invalidate_inode_pages2() after removing
	 * FUSE_NOWRITE, otherwise fuse_launder_folio() would deadlock.
	 */
	if ((is_truncate || !is_wb) &&
	    S_ISREG(inode->i_mode) && oldsize != outarg.attr.size) {
		truncate_pagecache(inode, outarg.attr.size);
		invalidate_inode_pages2(mapping);
	}

	clear_bit(FUSE_I_SIZE_UNSTABLE, &fi->state);
out:
	if (fault_blocked)
		filemap_invalidate_unlock(mapping);

	return 0;

error:
	if (is_truncate)
		fuse_release_nowrite(inode);

	clear_bit(FUSE_I_SIZE_UNSTABLE, &fi->state);

	if (fault_blocked)
		filemap_invalidate_unlock(mapping);
	return err;
}
