const std = @import("std");
const Translator = @import("translate_c").Translator;
const build_zig_zon = @import("build.zig.zon");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
};

pub fn build(b: *std.Build) !void {
    const version: std.SemanticVersion = try .parse(build_zig_zon.version);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.dependency("translate_c", .{});
    const hdf5_dep = b.dependency("hdf5", .{});
    const libhdf5 = buildHdf5(b, target, optimize);
    const trans_libhdf5: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/hdf5/hdf5lib.c"),
        .target = target,
        .optimize = optimize,
    });
    trans_libhdf5.linkLibrary(libhdf5);

    const exe = b.addExecutable(.{
        .name = "metro2hdf",
        .version = version,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("libhdf5", trans_libhdf5.mod);
    b.installArtifact(exe);

    // Convenience step for building and running metro2hdf
    const run_step = b.step("run", "Run metro2hdf");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // Build binary releases
    const release_step = b.step("release", "Build binary release");

    for (targets) |t| {
        const triple = try t.zigTriple(b.allocator);
        const release_target = b.resolveTargetQuery(t);
        const is_windows = release_target.result.os.tag == .windows;

        const libhdf5_rel = buildHdf5(b, release_target, .ReleaseFast);
        const trans_libhdf5_rel: Translator = .init(translate_c, .{
            .c_source_file = b.path("src/hdf5/hdf5lib.c"),
            .target = release_target,
            .optimize = .ReleaseFast,
        });
        trans_libhdf5_rel.linkLibrary(libhdf5_rel);

        const release = b.addExecutable(.{
            .name = "metro2hdf",
            .version = version,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .link_libc = true,
                .target = release_target,
                .optimize = .ReleaseFast,
            }),
        });

        release.root_module.addImport("libhdf5", trans_libhdf5_rel.mod);

        const target_output = b.addInstallArtifact(release, .{});

        const staging = b.addWriteFiles();
        staging.step.dependOn(&target_output.step);
        // Add the build binary
        const exe_path = if (is_windows) "bin/metro2hdf.exe" else "bin/metro2hdf";
        _ = staging.addCopyFile(release.getEmittedBin(), exe_path);
        // Add the metro2hdf README
        _ = staging.addCopyFile(b.path("README.md"), "README.md");
        // Add the metro2hdf license
        _ = staging.addCopyFile(b.path("LICENSE"), "LICENSE");
        // Add the hdf5 license
        _ = staging.addCopyFile(hdf5_dep.path("LICENSE"), "vendor/LICENSE");

        const cmd = if (is_windows) "zip" else "tar";
        const archive = b.addSystemCommand(&.{ cmd });
        archive.step.dependOn(&staging.step);

        const ext = if (is_windows) "zip" else "tar.gz";
        const sub_path = b.fmt("metro2hdf-{f}-{s}.{s}", .{version, triple, ext});
        var archive_output: std.Build.LazyPath = undefined;

        if (is_windows) {
            archive.addArg("-qr");
            archive_output = archive.addOutputFileArg(sub_path);
            archive.setCwd(staging.getDirectory());
            archive.addArg(".");
        } else {
            archive.addArg("-czf");
            archive_output = archive.addOutputFileArg(sub_path);
            archive.addArg("-C");
            archive.addDirectoryArg(staging.getDirectory());
            archive.addArg(".");
        }

        const install_archive = b.addInstallFile(archive_output, sub_path);
        install_archive.step.dependOn(&archive.step);

        release_step.dependOn(&install_archive.step);
    }
}

fn buildHdf5(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const hdf5_dep = b.dependency("hdf5", .{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addCSourceFiles(.{
        .root = hdf5_dep.path("src"),
        .files = &hdf5_c_sources,
        .flags = &c_flags,
    });
    mod.addCSourceFile(.{
        .file = b.path("hdf5_config/H5build_settings.c"),
        .flags = &c_flags,
    });
    if (target.result.os.tag == .linux) {
        mod.addCMacro("_GNU_SOURCE", "");
    }
    mod.addIncludePath(hdf5_dep.path("src"));
    mod.addIncludePath(hdf5_dep.path("src/H5FDsubfiling"));

    const lib = b.addLibrary(.{
        .name = "hdf5",
        .version = .{ .major = 2, .minor = 1, .patch = 1 },
        .root_module = mod,
        .linkage = .static,
    });
    lib.installHeadersDirectory(hdf5_dep.path("src"), "", .{});
    lib.installHeadersDirectory(hdf5_dep.path("src/H5FDsubfiling"), "", .{});

    const config_header = hdf5ConfigHeader(b, lib.version.?, target);
    mod.addConfigHeader(config_header);
    lib.installConfigHeader(config_header);
    return lib;
}

fn hdf5ConfigHeader(
    b: *std.Build,
    version: std.SemanticVersion,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.ConfigHeader {
    const t = target.result;
    if (t.ptrBitWidth() != 64) {
        @panic("only 64-bit targets are supported");
    }

    const long_double_size = t.cTypeByteSize(.longdouble).?;

    // Maximum decimal precision of the largest enabled native real type.
    //  8-byte long double: IEEE binary64       -> 17
    // 16-byte x86 long double: padded x87      -> 21
    // 16-byte AArch64 long double: IEEE binary128 -> 36
    const max_real_precision: u8 =
        if (long_double_size == 8)
            17
        else if (t.cpu.arch == .aarch64)
            36
        else
            21;

    const header = b.addConfigHeader(
        .{
            .style = .blank,
            .include_path = "H5pubconf.h",
        },
        .{
            .H5_PACKAGE = "hdf5",
            .H5_PACKAGE_NAME = "HDF5",
            .H5_PACKAGE_TARNAME = "hdf5",
            .H5_PACKAGE_VERSION = b.fmt("{f}", .{version}),
            .H5_PACKAGE_STRING = b.fmt("HDF5 {f}", .{version}),
            .H5_PACKAGE_BUGREPORT = "help@hdfgroup.org",
            .H5_PACKAGE_URL = "https://www.hdfgroup.org",
            .H5_VERSION = b.fmt("{f}", .{version}),
            .H5_SIZEOF_BOOL = 1,
            .H5_SIZEOF_CHAR = 1,
            .H5_SIZEOF_SHORT = t.cTypeByteSize(.short).?,
            .H5_SIZEOF_INT = t.cTypeByteSize(.int).?,
            .H5_SIZEOF_UNSIGNED = t.cTypeByteSize(.uint).?,
            .H5_SIZEOF_LONG = t.cTypeByteSize(.long).?,
            .H5_SIZEOF_LONG_LONG = t.cTypeByteSize(.longlong).?,
            .H5_SIZEOF_FLOAT = t.cTypeByteSize(.float).?,
            .H5_SIZEOF_DOUBLE = t.cTypeByteSize(.double).?,
            .H5_SIZEOF_LONG_DOUBLE = long_double_size,
            .H5_SIZEOF_SIZE_T = 8,
            .H5_SIZEOF_PTRDIFF_T = 8,
            .H5_SIZEOF_INT8_T = 1,
            .H5_SIZEOF_UINT8_T = 1,
            .H5_SIZEOF_INT16_T = 2,
            .H5_SIZEOF_UINT16_T = 2,
            .H5_SIZEOF_INT32_T = 4,
            .H5_SIZEOF_UINT32_T = 4,
            .H5_SIZEOF_INT64_T = 8,
            .H5_SIZEOF_UINT64_T = 8,
            .H5_SIZEOF__FLOAT16 = 0,
            .H5_PAC_C_MAX_REAL_PRECISION = max_real_precision,
            .H5_PAC_FC_MAX_REAL_PRECISION = 0,
            .H5_WANT_DATA_ACCURACY = true,
            .H5_WANT_DCONV_EXCEPTION = true,
            .H5_USE_200_API_DEFAULT = true,
            .H5_DEFAULT_PLUGINDIR = "",
            .H5_HAVE_ATTRIBUTE = true,
            .H5_HAVE_SYS_STAT_H = true,
        },
    );

    if (t.os.tag == .windows) {
        header.addValues(.{
            .H5_HAVE_WINDOWS = true,
            .H5_HAVE_MINGW = true,
            .H5_HAVE_WIN32_API = true,
            .H5_HAVE_WINDOW_PATH = true,
            .H5_SIZEOF_TIME_T = 8,
            .H5_SIZEOF_OFF_T = 4,
        });
    } else {
        header.addValues(.{
            .H5_HAVE_UNISTD_H = true,
            .H5_HAVE_SYS_FILE_H = true,
            .H5_HAVE_FSEEKO = true,
            .H5_SIZEOF_SSIZE_T = 8,
            .H5_SIZEOF_OFF_T = 8,
            .H5_SIZEOF_TIME_T = 8,
            .H5_HAVE_DIRENT_H = true,
            .H5_HAVE_DLFCN_H = true,
            .H5_HAVE_FCNTL = true,
            .H5_HAVE_FLOCK = true,
        });
        if (t.os.tag == .macos) {
            header.addValues(.{
                .H5_HAVE_DARWIN = true,
            });
        }
    }

    return header;
}

const c_flags = [_][]const u8{
    "-std=c11",
    "-Wall",
    "-Warray-bounds",
    "-Wcast-qual",
    "-Wconversion",
    "-Wdouble-promotion",
    "-Wextra",
    "-Wformat=2",
    "-Wframe-larger-than=16384",
    "-Wimplicit-fallthrough",
    "-Wnull-dereference",
    "-Wunused-const-variable",
    "-Wwrite-strings",
    "-Wpedantic",
    "-Wvolatile-register-var",
    "-Wno-c++-compat",
    "-Wbad-function-cast",
    "-Wimplicit-function-declaration",
    "-Wincompatible-pointer-types",
    "-Wmissing-declarations",
    "-Wpacked",
    "-Wshadow",
    "-Wswitch",
    "-Wno-error=incompatible-pointer-types-discards-qualifiers",
    "-Wunused-function",
    "-Wunused-variable",
    "-Wunused-parameter",
    "-Wcast-align",
    "-Wno-missing-noreturn",
};

const hdf5_c_sources = [_][]const u8{
    // H5 core
    "H5.c",
    "H5checksum.c",
    "H5dbg.c",
    "H5mpi.c",
    "H5system.c",
    "H5timer.c",
    "H5trace.c",
    // H5A — attributes
    "H5A.c",
    "H5Abtree2.c",
    "H5Adense.c",
    "H5Adeprec.c",
    "H5Aint.c",
    "H5Atest.c",
    // H5AC — metadata cache
    "H5AC.c",
    "H5ACdbg.c",
    "H5ACmpio.c",
    "H5ACproxy_entry.c",
    // H5B — B-trees
    "H5B.c",
    "H5Bcache.c",
    "H5Bdbg.c",
    // H5B2 — v2 B-trees
    "H5B2.c",
    "H5B2cache.c",
    "H5B2dbg.c",
    "H5B2hdr.c",
    "H5B2int.c",
    "H5B2internal.c",
    "H5B2leaf.c",
    "H5B2stat.c",
    "H5B2test.c",
    // H5C — cache
    "H5C.c",
    "H5Cdbg.c",
    "H5Centry.c",
    "H5Cepoch.c",
    "H5Cimage.c",
    "H5Cint.c",
    "H5Clog.c",
    "H5Clog_json.c",
    "H5Clog_trace.c",
    "H5Cmpio.c",
    "H5Cprefetched.c",
    "H5Cquery.c",
    "H5Ctag.c",
    "H5Ctest.c",
    // H5CX — context
    "H5CX.c",
    // H5D — datasets
    "H5D.c",
    "H5Dbtree.c",
    "H5Dbtree2.c",
    "H5Dchunk.c",
    "H5Dcompact.c",
    "H5Dcontig.c",
    "H5Ddbg.c",
    "H5Ddeprec.c",
    "H5Dearray.c",
    "H5Defl.c",
    "H5Dfarray.c",
    "H5Dfill.c",
    "H5Dint.c",
    "H5Dio.c",
    "H5Dlayout.c",
    "H5Dmpio.c",
    "H5Dnone.c",
    "H5Doh.c",
    "H5Dscatgath.c",
    "H5Dselect.c",
    "H5Dsingle.c",
    "H5Dtest.c",
    "H5Dvirtual.c",
    // H5E — errors
    "H5E.c",
    "H5Edeprec.c",
    "H5Eint.c",
    // H5EA — extensible arrays
    "H5EA.c",
    "H5EAcache.c",
    "H5EAdbg.c",
    "H5EAdblkpage.c",
    "H5EAdblock.c",
    "H5EAhdr.c",
    "H5EAiblock.c",
    "H5EAint.c",
    "H5EAsblock.c",
    "H5EAstat.c",
    "H5EAtest.c",
    // H5ES — event sets
    "H5ES.c",
    "H5ESevent.c",
    "H5ESint.c",
    "H5ESlist.c",
    // H5F — files
    "H5F.c",
    "H5Faccum.c",
    "H5Fcwfs.c",
    "H5Fdbg.c",
    "H5Fdeprec.c",
    "H5Fefc.c",
    "H5Ffake.c",
    "H5Fint.c",
    "H5Fio.c",
    "H5Fmount.c",
    "H5Fmpi.c",
    "H5Fquery.c",
    "H5Fsfile.c",
    "H5Fspace.c",
    "H5Fsuper.c",
    "H5Fsuper_cache.c",
    "H5Ftest.c",
    // H5FA — fixed arrays
    "H5FA.c",
    "H5FAcache.c",
    "H5FAdbg.c",
    "H5FAdblkpage.c",
    "H5FAdblock.c",
    "H5FAhdr.c",
    "H5FAint.c",
    "H5FAstat.c",
    "H5FAtest.c",
    // H5FD — file drivers
    "H5FD.c",
    "H5FDcore.c",
    "H5FDdirect.c",
    "H5FDfamily.c",
    "H5FDhdfs.c",
    "H5FDint.c",
    "H5FDlog.c",
    "H5FDmirror.c",
    "H5FDmpi.c",
    "H5FDmpio.c",
    "H5FDmulti.c",
    "H5FDmulti_int.c",
    "H5FDonion.c",
    "H5FDonion_header.c",
    "H5FDonion_history.c",
    "H5FDonion_index.c",
    "H5FDros3.c",
    "H5FDros3_s3comms.c",
    "H5FDsec2.c",
    "H5FDspace.c",
    "H5FDsplitter.c",
    "H5FDstdio.c",
    "H5FDstdio_int.c",
    "H5FDtest.c",
    "H5FDwindows.c",
    // H5FL — free lists
    "H5FL.c",
    // H5FO — open object info
    "H5FO.c",
    // H5FS — free space
    "H5FS.c",
    "H5FScache.c",
    "H5FSdbg.c",
    "H5FSint.c",
    "H5FSsection.c",
    "H5FSstat.c",
    "H5FStest.c",
    // H5G — groups
    "H5G.c",
    "H5Gbtree2.c",
    "H5Gcache.c",
    "H5Gcompact.c",
    "H5Gdense.c",
    "H5Gdeprec.c",
    "H5Gent.c",
    "H5Gint.c",
    "H5Glink.c",
    "H5Gloc.c",
    "H5Gname.c",
    "H5Gnode.c",
    "H5Gobj.c",
    "H5Goh.c",
    "H5Groot.c",
    "H5Gstab.c",
    "H5Gtest.c",
    "H5Gtraverse.c",
    // H5HF — fractal heap
    "H5HF.c",
    "H5HFbtree2.c",
    "H5HFcache.c",
    "H5HFdbg.c",
    "H5HFdblock.c",
    "H5HFdtable.c",
    "H5HFhdr.c",
    "H5HFhuge.c",
    "H5HFiblock.c",
    "H5HFiter.c",
    "H5HFman.c",
    "H5HFsection.c",
    "H5HFspace.c",
    "H5HFstat.c",
    "H5HFtest.c",
    "H5HFtiny.c",
    // H5HG — global heap
    "H5HG.c",
    "H5HGcache.c",
    "H5HGdbg.c",
    "H5HGquery.c",
    // H5HL — local heap
    "H5HL.c",
    "H5HLcache.c",
    "H5HLdbg.c",
    "H5HLdblk.c",
    "H5HLint.c",
    "H5HLprfx.c",
    // H5I — identifiers
    "H5I.c",
    "H5Idbg.c",
    "H5Ideprec.c",
    "H5Iint.c",
    "H5Itest.c",
    // H5L — links
    "H5L.c",
    "H5Ldeprec.c",
    "H5Lexternal.c",
    "H5Lint.c",
    // H5M — maps
    "H5M.c",
    // H5MF — file memory management
    "H5MF.c",
    "H5MFaggr.c",
    "H5MFdbg.c",
    "H5MFsection.c",
    // H5MM — memory management
    "H5MM.c",
    // H5O — object headers
    "H5O.c",
    "H5Oainfo.c",
    "H5Oalloc.c",
    "H5Oattr.c",
    "H5Oattribute.c",
    "H5Obogus.c",
    "H5Obtreek.c",
    "H5Ocache.c",
    "H5Ocache_image.c",
    "H5Ochunk.c",
    "H5Ocont.c",
    "H5Ocopy.c",
    "H5Ocopy_ref.c",
    "H5Odbg.c",
    "H5Odeleted.c",
    "H5Odeprec.c",
    "H5Odrvinfo.c",
    "H5Odtype.c",
    "H5Oefl.c",
    "H5Ofill.c",
    "H5Oflush.c",
    "H5Ofsinfo.c",
    "H5Oginfo.c",
    "H5Oint.c",
    "H5Olayout.c",
    "H5Olinfo.c",
    "H5Olink.c",
    "H5Omessage.c",
    "H5Omtime.c",
    "H5Oname.c",
    "H5Onull.c",
    "H5Opline.c",
    "H5Orefcount.c",
    "H5Osdspace.c",
    "H5Oshared.c",
    "H5Oshmesg.c",
    "H5Ostab.c",
    "H5Otest.c",
    "H5Ounknown.c",
    // H5P — property lists
    "H5P.c",
    "H5Pacpl.c",
    "H5Pdapl.c",
    "H5Pdcpl.c",
    "H5Pdeprec.c",
    "H5Pdxpl.c",
    "H5Pencdec.c",
    "H5Pfapl.c",
    "H5Pfcpl.c",
    "H5Pfmpl.c",
    "H5Pgcpl.c",
    "H5Pint.c",
    "H5Plapl.c",
    "H5Plcpl.c",
    "H5Pmapl.c",
    "H5Pmcpl.c",
    "H5Pocpl.c",
    "H5Pocpypl.c",
    "H5Pstrcpl.c",
    "H5Ptest.c",
    // H5PB — page buffering
    "H5PB.c",
    // H5PL — plugins
    "H5PL.c",
    "H5PLint.c",
    "H5PLpath.c",
    "H5PLplugin_cache.c",
    // H5R — references
    "H5R.c",
    "H5Rdeprec.c",
    "H5Rint.c",
    // H5RS — reference-counted strings
    "H5RS.c",
    // H5RT — reference tracking
    "H5RT.c",
    // H5S — dataspaces
    "H5S.c",
    "H5Sall.c",
    "H5Sdbg.c",
    "H5Sdeprec.c",
    "H5Shyper.c",
    "H5Smpio.c",
    "H5Snone.c",
    "H5Spoint.c",
    "H5Sselect.c",
    "H5Stest.c",
    // H5SL — skip lists
    "H5SL.c",
    // H5SM — shared messages
    "H5SM.c",
    "H5SMbtree2.c",
    "H5SMcache.c",
    "H5SMmessage.c",
    "H5SMtest.c",
    // H5T — datatypes
    "H5T.c",
    "H5Tarray.c",
    "H5Tbit.c",
    "H5Tcommit.c",
    "H5Tcomplex.c",
    "H5Tcompound.c",
    "H5Tconv.c",
    "H5Tconv_array.c",
    "H5Tconv_bitfield.c",
    "H5Tconv_complex.c",
    "H5Tconv_compound.c",
    "H5Tconv_enum.c",
    "H5Tconv_float.c",
    "H5Tconv_integer.c",
    "H5Tconv_reference.c",
    "H5Tconv_string.c",
    "H5Tconv_vlen.c",
    "H5Tcset.c",
    "H5Tdbg.c",
    "H5Tdeprec.c",
    "H5Tenum.c",
    "H5Tfields.c",
    "H5Tfixed.c",
    "H5Tfloat.c",
    "H5Tinit_float.c",
    "H5Tnative.c",
    "H5Toffset.c",
    "H5Toh.c",
    "H5Topaque.c",
    "H5Torder.c",
    "H5Tpad.c",
    "H5Tprecis.c",
    "H5Tref.c",
    "H5Tstrpad.c",
    "H5Tvisit.c",
    "H5Tvlen.c",
    // H5TS — threading stubs
    "H5TS.c",
    "H5TSatomic.c",
    "H5TSbarrier.c",
    "H5TSc11.c",
    "H5TScond.c",
    "H5TSint.c",
    "H5TSkey.c",
    "H5TSmutex.c",
    "H5TSonce.c",
    "H5TSpool.c",
    "H5TSpthread.c",
    "H5TSrec_rwlock.c",
    "H5TSrwlock.c",
    "H5TSsemaphore.c",
    "H5TSthread.c",
    "H5TSwin.c",
    // H5UC — reference counting
    "H5UC.c",
    // H5VL — virtual object layer
    "H5VL.c",
    "H5VLcallback.c",
    "H5VLdyn_ops.c",
    "H5VLint.c",
    "H5VLnative.c",
    "H5VLnative_attr.c",
    "H5VLnative_blob.c",
    "H5VLnative_dataset.c",
    "H5VLnative_datatype.c",
    "H5VLnative_file.c",
    "H5VLnative_group.c",
    "H5VLnative_link.c",
    "H5VLnative_introspect.c",
    "H5VLnative_object.c",
    "H5VLnative_token.c",
    "H5VLpassthru.c",
    "H5VLpassthru_int.c",
    "H5VLquery.c",
    "H5VLtest.c",
    // H5VM — vector/array math
    "H5VM.c",
    // H5WB — wrapped buffers
    "H5WB.c",
    // H5Z — filters
    "H5Z.c",
    "H5Zdeflate.c",
    "H5Zfletcher32.c",
    "H5Znbit.c",
    "H5Zscaleoffset.c",
    "H5Zshuffle.c",
    "H5Zszip.c",
    "H5Ztrans.c",
};
