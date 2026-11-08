/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * hummer (OnePlus Ace 5 Pro / LineageOS 24) build profile.
 *
 * The upstream project only accepts its recorded GKI releases.  This fork is
 * built against one exact vendor kernel, so the build pins the complete
 * uname -r string and lets the loader pass gki=1.
 *
 * The actual release is supplied by the Makefile as -DDS_HUMMER_RELEASE=...
 * (HUMMER_RELEASE=...), so OTA builds can target a new kernel without editing
 * this file.  Compiling with HUMMER=1 always supplies a default.
 */
#ifndef DS_HUMMER_H
#define DS_HUMMER_H

#define DS_HUMMER 1

#endif
