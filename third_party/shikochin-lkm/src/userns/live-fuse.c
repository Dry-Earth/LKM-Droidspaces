/* SPDX-License-Identifier: GPL-2.0-only */
/* FUSE user-namespace option parsing for the hummer 6.6 tree.
 * Recompiled from fs/fuse/inode.c so make_kuid()/from_kuid_munged()
 * perform real user-namespace mapping instead of the USER_NS=n stubs.
 */
#include "fs/fuse/fuse_i.h"
#include <linux/file.h>
#include <linux/slab.h>
#include <linux/user_namespace.h>
#include "live-fuse.h"

#include <linux/fs_context.h>
#include <linux/fs_parser.h>
#include <linux/seq_file.h>
#include <linux/filter.h>
#include <linux/cred.h>
#include <linux/bpf.h>
#include <uapi/linux/magic.h>

#define FUSE_DEFAULT_BLKSIZE 512

enum {
	OPT_SOURCE,
	OPT_SUBTYPE,
	OPT_FD,
	OPT_ROOTMODE,
	OPT_USER_ID,
	OPT_GROUP_ID,
	OPT_DEFAULT_PERMISSIONS,
	OPT_ALLOW_OTHER,
	OPT_MAX_READ,
	OPT_BLKSIZE,
	OPT_ROOT_BPF,
	OPT_ROOT_DIR,
	OPT_NO_DAEMON,
	OPT_ERR
};

static const struct fs_parameter_spec fuse_fs_parameters[] = {
	fsparam_string	("source",		OPT_SOURCE),
	fsparam_u32	("fd",			OPT_FD),
	fsparam_u32oct	("rootmode",		OPT_ROOTMODE),
	fsparam_u32	("user_id",		OPT_USER_ID),
	fsparam_u32	("group_id",		OPT_GROUP_ID),
	fsparam_flag	("default_permissions",	OPT_DEFAULT_PERMISSIONS),
	fsparam_flag	("allow_other",		OPT_ALLOW_OTHER),
	fsparam_u32	("max_read",		OPT_MAX_READ),
	fsparam_u32	("blksize",		OPT_BLKSIZE),
	fsparam_string	("subtype",		OPT_SUBTYPE),
	fsparam_u32	("root_bpf",		OPT_ROOT_BPF),
	fsparam_u32	("root_dir",		OPT_ROOT_DIR),
	fsparam_flag	("no_daemon",		OPT_NO_DAEMON),
	{}
};

int ds_userns_fuse_parse_param(struct fs_context *fsc, struct fs_parameter *param)
{
	struct fs_parse_result result;
	struct fuse_fs_context *ctx = fsc->fs_private;
	int opt;
	kuid_t kuid;
	kgid_t kgid;

	if (fsc->purpose == FS_CONTEXT_FOR_RECONFIGURE) {
		if (fsc->oldapi)
			return 0;
		return invalfc(fsc, "No changes allowed in reconfigure");
	}

	opt = fs_parse(fsc, fuse_fs_parameters, param, &result);
	if (opt < 0)
		return opt;

	/* Android BPF backing / daemonless mounts cannot be owned by a child
	 * user namespace; reject them before touching those objects. */
	if (fsc->user_ns != &init_user_ns &&
	    (opt == OPT_ROOT_BPF || opt == OPT_ROOT_DIR || opt == OPT_NO_DAEMON))
		return -EOPNOTSUPP;

	switch (opt) {
	case OPT_SOURCE:
		if (fsc->source)
			return invalfc(fsc, "Multiple sources specified");
		fsc->source = param->string;
		param->string = NULL;
		break;

	case OPT_SUBTYPE:
		if (ctx->subtype)
			return invalfc(fsc, "Multiple subtypes specified");
		ctx->subtype = param->string;
		param->string = NULL;
		return 0;

	case OPT_FD:
		ctx->fd = result.uint_32;
		ctx->fd_present = true;
		break;

	case OPT_ROOTMODE:
		if (!fuse_valid_type(result.uint_32))
			return invalfc(fsc, "Invalid rootmode");
		ctx->rootmode = result.uint_32;
		ctx->rootmode_present = true;
		break;

	case OPT_USER_ID:
		kuid = make_kuid(fsc->user_ns, result.uint_32);
		if (!uid_valid(kuid))
			return invalfc(fsc, "Invalid user_id");
		if (!kuid_has_mapping(fsc->user_ns, kuid))
			return invalfc(fsc, "Invalid user_id");
		ctx->user_id = kuid;
		ctx->user_id_present = true;
		break;

	case OPT_GROUP_ID:
		kgid = make_kgid(fsc->user_ns, result.uint_32);
		if (!gid_valid(kgid))
			return invalfc(fsc, "Invalid group_id");
		if (!kgid_has_mapping(fsc->user_ns, kgid))
			return invalfc(fsc, "Invalid group_id");
		ctx->group_id = kgid;
		ctx->group_id_present = true;
		break;

	case OPT_DEFAULT_PERMISSIONS:
		ctx->default_permissions = true;
		break;

	case OPT_ALLOW_OTHER:
		ctx->allow_other = true;
		break;

	case OPT_MAX_READ:
		ctx->max_read = result.uint_32;
		break;

	case OPT_BLKSIZE:
		if (!ctx->is_bdev)
			return invalfc(fsc, "blksize only supported for fuseblk");
		ctx->blksize = result.uint_32;
		break;

	case OPT_ROOT_BPF:
		ctx->root_bpf = bpf_prog_get_type_dev(result.uint_32,
						BPF_PROG_TYPE_FUSE, false);
		if (IS_ERR(ctx->root_bpf)) {
			ctx->root_bpf = NULL;
			return invalfc(fsc, "Unable to open bpf program");
		}
		break;

	case OPT_ROOT_DIR: {
		struct file *rd = fget(result.uint_32);

		if (!rd)
			return invalfc(fsc, "Unable to open root directory");
		if (rd->f_inode->i_sb->s_magic == FUSE_SUPER_MAGIC ||
		    rd->f_inode->i_sb->s_stack_depth >= FILESYSTEM_MAX_STACK_DEPTH) {
			fput(rd);
			return invalfc(fsc, "Invalid root directory (FUSE or too deep)");
		}
		ctx->root_dir = rd;
		break;
	}

	case OPT_NO_DAEMON:
		ctx->no_daemon = true;
		ctx->fd_present = true;
		break;

	default:
		return -EINVAL;
	}

	return 0;
}

int ds_userns_fuse_show_options(struct seq_file *m, struct dentry *root)
{
	struct super_block *sb = root->d_sb;
	struct fuse_conn *fc = get_fuse_conn_super(sb);

	if (fc->legacy_opts_show) {
		seq_printf(m, ",user_id=%u",
			   from_kuid_munged(fc->user_ns, fc->user_id));
		seq_printf(m, ",group_id=%u",
			   from_kgid_munged(fc->user_ns, fc->group_id));
		if (fc->default_permissions)
			seq_puts(m, ",default_permissions");
		if (fc->allow_other)
			seq_puts(m, ",allow_other");
		if (fc->max_read != ~0)
			seq_printf(m, ",max_read=%u", fc->max_read);
		if (sb->s_bdev && sb->s_blocksize != FUSE_DEFAULT_BLKSIZE)
			seq_printf(m, ",blksize=%lu", sb->s_blocksize);
	}
#ifdef CONFIG_FUSE_DAX
	if (fc->dax_mode == FUSE_DAX_ALWAYS)
		seq_puts(m, ",dax=always");
	else if (fc->dax_mode == FUSE_DAX_NEVER)
		seq_puts(m, ",dax=never");
	else if (fc->dax_mode == FUSE_DAX_INODE_USER)
		seq_puts(m, ",dax=inode");
#endif

	return 0;
}

static bool fuse_permissible_uidgid(struct fuse_conn *fc)
{
	const struct cred *cred = current_cred();

	return (uid_eq(cred->euid, fc->user_id) &&
		uid_eq(cred->suid, fc->user_id) &&
		uid_eq(cred->uid,  fc->user_id) &&
		gid_eq(cred->egid, fc->group_id) &&
		gid_eq(cred->sgid, fc->group_id) &&
		gid_eq(cred->gid,  fc->group_id));
}

bool ds_userns_fuse_allow_current_process(struct fuse_conn *fc)
{
	bool allow;

	if (fc->allow_other)
		allow = current_in_userns(fc->user_ns);
	else
		allow = fuse_permissible_uidgid(fc);

	/* The native CAP_SYS_ADMIN bypass targets the initial namespace only;
	 * leave it off for the LKM so a child namespace cannot gain it. */
	return allow;
}
