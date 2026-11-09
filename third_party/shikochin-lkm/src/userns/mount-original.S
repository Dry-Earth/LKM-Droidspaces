/* SPDX-License-Identifier: GPL-2.0-only */
/* Only a checked, position-independent native prologue is copied here. */
.text
.balign 16
.global ds_userns_alloc_mnt_ns_original
.type ds_userns_alloc_mnt_ns_original, %function
ds_userns_alloc_mnt_ns_original:
.rept 8
brk #0
.endr
.size ds_userns_alloc_mnt_ns_original, .-ds_userns_alloc_mnt_ns_original
