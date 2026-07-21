const std = @import("std");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

pub fn build(b: *std.Build) !void {
    const zlib_dep = b.dependency("zlib", .{});
    const hdf5_dep = b.dependency("hdf5", .{});

    // Convenience step for building and running metro2hdf
    const run_step = b.step("run", "Run metro2hdf");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "metro2hdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
        }),
    });

    // Build and link hdf5
    const hdf5_native = buildHdf5(b, hdf5_dep, zlib_dep, target, optimize);
    exe.root_module.linkLibrary(hdf5_native);
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/hdf5lib.c"),
        .flags = &.{"-std=c11"},
    });
    exe.root_module.addIncludePath(b.path("src"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Build binary releases
    const release_step = b.step("release", "Build binary release");

    for (targets) |t| {
        // Define the output directory for each target
        const dest_subdir = try t.zigTriple(b.allocator);

        const release = b.addExecutable(.{
            .name = "metro2hdf",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .link_libc = true,
                .target = b.resolveTargetQuery(t),
                .optimize = .ReleaseFast,
            }),
        });

        // Build and link hdf5 for the target
        const hdf5 = buildHdf5(b, hdf5_dep, zlib_dep, b.resolveTargetQuery(t), .ReleaseFast);
        release.root_module.linkLibrary(hdf5);
        release.root_module.addCSourceFile(.{
            .file = b.path("src/hdf5lib.c"),
            .flags = &.{"-std=c11"},
        });
        release.root_module.addIncludePath(b.path("src"));

        const target_output = b.addInstallArtifact(release, .{
            .dest_dir = .{
                .override = .{
                    .custom = dest_subdir,
                },
            },
        });
        release_step.dependOn(&target_output.step);

        // Add the metro2hdf README
        const readme_path = try std.fmt.allocPrint(b.allocator, "{s}/README.md", .{dest_subdir});
        const readme = b.addInstallFile(b.path("README.md"), readme_path);
        release_step.dependOn(&readme.step);

        // Add the metro2hdf license
        const license_path = try std.fmt.allocPrint(b.allocator, "{s}/LICENSE", .{dest_subdir});
        const license = b.addInstallFile(b.path("LICENSE"), license_path);
        release_step.dependOn(&license.step);

        // Add the hdf5 license
        const hdf5_license_path = try std.fmt.allocPrint(b.allocator, "{s}/vendor/hdf5/LICENSE", .{dest_subdir});
        const hdf5_license = b.addInstallFile(hdf5_dep.path("LICENSE"), hdf5_license_path);
        release_step.dependOn(&hdf5_license.step);

        // Add the zlib license
        const zlib_license_path = try std.fmt.allocPrint(b.allocator, "{s}/vendor/zlib/LICENSE", .{dest_subdir});
        const zlib_license = b.addInstallFile(zlib_dep.path("LICENSE"), zlib_license_path);
        release_step.dependOn(&zlib_license.step);
    }
}

fn buildZLib(
    b: *std.Build,
    zlib_dep: *std.Build.Dependency,
    t: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const zlib = b.addLibrary(.{
        .name = "z",
        .version = .{.major = 1, .minor = 3, .patch = 2},
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = t,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    zlib.root_module.addCSourceFiles(.{
        .root = zlib_dep.path(""),
        .files = &zlib_c_sources,
        .flags = &.{ "-std=c99" },
    });
    zlib.root_module.addCMacro("HAVE_SYS_TYPES_H", "1");
    zlib.root_module.addCMacro("HAVE_STDINT_H", "1");
    zlib.root_module.addCMacro("HAVE_STDDEF_H", "1");
    zlib.root_module.addCMacro("HAVE_UNISTD_H", "1");
    zlib.root_module.addIncludePath(zlib_dep.path(""));
    zlib.installHeadersDirectory(zlib_dep.path(""), "", .{});

    return zlib;
}

fn buildHdf5(
    b: *std.Build,
    hdf5_dep: *std.Build.Dependency,
    zlib_dep: *std.Build.Dependency,
    t: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const zlib = buildZLib(b, zlib_dep, t, optimize);

    const hdf5_lib = b.addLibrary(.{
        .name = "hdf5",
        .version = .{ .major = 2, .minor = 1, .patch = 1 },
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = t,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const hdf5_configh = configureHdf5(b, hdf5_dep, hdf5_lib.version.?, t);
    hdf5_lib.root_module.addConfigHeader(hdf5_configh);

    hdf5_lib.root_module.addCSourceFiles(.{
        .root = hdf5_dep.path("src"),
        .files = &hdf5_c_sources,
        .flags = &c_flags,
    });

    hdf5_lib.root_module.addCSourceFile(.{
        .file = b.path("hdf5_config/H5build_settings.c"),
        .flags = &c_flags,
    });

    if (t.result.os.tag == .linux) {
        hdf5_lib.root_module.addCMacro("_POSIX_C_SOURCE", "200809L");
        hdf5_lib.root_module.addCMacro("_GNU_SOURCE", "");
    }

    // Include paths: HDF5 source headers + our config directory
    hdf5_lib.root_module.addIncludePath(hdf5_dep.path("src"));
    hdf5_lib.root_module.addIncludePath(hdf5_dep.path("src/H5FDsubfiling"));
    hdf5_lib.installHeadersDirectory(hdf5_dep.path("src"), "", .{});
    hdf5_lib.installHeadersDirectory(hdf5_dep.path("src/H5FDsubfiling"), "", .{});
    hdf5_lib.installConfigHeader(hdf5_configh);

    // Link zlib
    hdf5_lib.root_module.linkLibrary(zlib);

    return hdf5_lib;
}

fn configureHdf5(
    b: *std.Build,
    hdf5_dep: *std.Build.Dependency,
    version: std.SemanticVersion,
    t: std.Build.ResolvedTarget,
) *std.Build.Step.ConfigHeader {
    var header = b.addConfigHeader(
        .{ .style = .{ .cmake = hdf5_dep.path("src/H5pubconf.h.in") } },
        .{
            .H5_HAVE_WINDOWS = if (t.result.os.tag == .windows) true else null,
            .H5_HAVE_MINGW = if (t.result.isMinGW()) true else null,
            .H5_HAVE_WIN32_API = if (t.result.os.tag == .windows) true else null,
            .H5_HAVE_VISUAL_STUDIO = null,
            .H5_DEFAULT_PLUGINDIR = b.fmt("{s}/local/plugin", .{b.install_prefix}),
            .H5_DISABLE_SOME_LDOUBLE_CONV = if (t.result.cpu.arch == .powerpc64le) true else null,
            .H5_FC_DUMMY_MAIN = null,
            .H5_FC_DUMMY_MAIN_EQ_F77 = null,
            .H5_FC_FUNC = "H5_FC_FUNC(name,NAME) name ## _",
            .H5_FC_FUNC_ = "H5_FC_FUNC_(name,NAME) name ## _",
            .H5_FORTRAN_C_BOOL_IS_UNIQUE = null,
            .H5_FORTRAN_HAVE_C_SIZEOF = null,
            .H5_FORTRAN_HAVE_SIZEOF = null,
            .H5_FORTRAN_HAVE_STORAGE_SIZE = null,
            .H5_FORTRAN_HAVE_CHAR_ALLOC = null,
            .H5_FORTRAN_SIZEOF_LONG_DOUBLE = null,
            .CMAKE_Fortran_COMPILER_ID = null,
            .H5_H5CONFIG_F_NUM_IKIND = null,
            .H5_H5CONFIG_F_IKIND = null,
            .H5_H5CONFIG_F_NUM_RKIND = null,
            .H5_H5CONFIG_F_RKIND = null,
            .H5_H5CONFIG_F_RKIND_SIZEOF = null,
            .H5_HAVE_ALARM = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_ARPA_INET_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_ASPRINTF = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_ATTRIBUTE = true,
            .H5_HAVE_C99_COMPLEX_NUMBERS = true,
            .H5_HAVE_CLOCK_GETTIME = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_COMPLEX_NUMBERS = true,
            .H5_HAVE_CURL_H = null,
            .H5_HAVE_DARWIN = t.result.os.tag == .macos,
            .H5_HAVE_DIRECT = null,
            .H5_HAVE_DIRENT_H = true,
            .H5_HAVE_DLFCN_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_EMBEDDED_LIBINFO = true,
            .H5_HAVE_FABSF16 = null,
            .H5_HAVE_FCNTL = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_FILTER_DEFLATE = true,
            .H5_HAVE_FILTER_SZIP = null,
            .H5_HAVE__FLOAT16 = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_FLOAT128 = null,
            .H5_HAVE_FLOCK = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_FORK = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_FSEEKO = null,
            .H5_HAVE_Fortran_INTEGER_SIZEOF_16 = null,
            .H5_HAVE_GETCONSOLESCREENBUFFERINFO = null,
            .H5_HAVE_GETHOSTNAME = true,
            .H5_HAVE_GETRUSAGE = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_GETTEXTINFO = null,
            .H5_HAVE_GETTIMEOFDAY = true,
            .H5_HAVE_HDFS_H = null,
            .H5_HAVE_INSTRUMENTED_LIBRARY = null,
            .H5_HAVE_IOC_VFD = null,
            .H5_HAVE_IOCTL = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_LIBCRYPTO = null,
            .H5_HAVE_LIBCURL = null,
            .H5_HAVE_LIBDL = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_LIBHDFS = null,
            .H5_HAVE_LIBJVM = null,
            .H5_HAVE_LIBM = true,
            .H5_HAVE_LIBPTHREAD = null,
            .H5_HAVE_LIBSZ = null,
            .H5_HAVE_LIBWS2_32 = null,
            .H5_HAVE_LIBZ = true,
            .H5_HAVE_MAP_API = null,
            .H5_HAVE_MIRROR_VFD = null,
            .H5_HAVE_MPI_MULTI_LANG_Comm = null,
            .H5_HAVE_MPI_MULTI_LANG_Info = null,
            .H5_HAVE_NETDB_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_NETINET_IN_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_OPENSSL_EVP_H = null,
            .H5_HAVE_OPENSSL_HMAC_H = null,
            .H5_HAVE_OPENSSL_SHA_H = null,
            .H5_HAVE_PARALLEL = null,
            .H5_HAVE_MPI_F08 = null,
            .H5_HAVE_PARALLEL_FILTERED_WRITES = null,
            .H5_HAVE_PREADWRITE = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_PTHREAD_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_PTHREAD_BARRIER = null,
            .H5_HAVE_PWD_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_QSORT_REENTRANT = true,
            .H5_HAVE_ROS3_VFD = null,
            .H5_HAVE_STAT_ST_BLOCKS = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_STRCASESTR = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_STRDUP = true,
            .H5_HAVE_STRUCT_TEXT_INFO = null,
            .H5_HAVE_STRUCT_VIDEOCONFIG = null,
            .H5_HAVE_SUBFILING_VFD = null,
            .H5_HAVE_STDATOMIC_H = true,
            .H5_HAVE_SYMLINK = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_SYS_FILE_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_SYS_IOCTL_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_SYS_RESOURCE_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_SYS_SOCKET_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_SYS_STAT_H = true,
            .H5_HAVE_SYS_TIME_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_SZLIB_H = null,
            .H5_HAVE_THREADSAFE = null,
            .H5_HAVE_CONCURRENCY = null,
            .H5_HAVE_THREADS = true,
            .H5_HAVE_TIMEZONE = true,
            .H5_HAVE_TIOCGETD = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_TIOCGWINSZ = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_TMPFILE = true,
            .H5_HAVE_TM_GMTOFF = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_UNISTD_H = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_VASPRINTF = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_WAITPID = if (t.result.os.tag == .windows) null else true,
            .H5_HAVE_WIN_THREADS = if (t.result.os.tag == .windows) true else null,
            .H5_HAVE_C11_THREADS = null,
            .H5_HAVE_WINDOW_PATH = if (t.result.os.tag == .windows) true else null,
            .H5_HAVE_ZLIB_H = true,
            .H5_HAVE_ZLIBNG_H = null,
            .H5_HAVE__GETVIDEOCONFIG = null,
            .H5_HAVE__SCRSIZE = null,
            .H5_IGNORE_DISABLED_FILE_LOCKS = true,
            .H5_INCLUDE_HL = true,
            .H5_DIMENSION_SCALES_WITH_NEW_REF = null,
            .H5_LDOUBLE_TO_FLOAT16_CORRECT = if (t.result.os.tag == .windows) null else true,
            .H5_LDOUBLE_TO_LLONG_ACCURATE = true,
            .H5_LDOUBLE_TO_LONG_SPECIAL = null,
            .H5_LLONG_TO_LDOUBLE_CORRECT = true,
            .H5_LONG_TO_LDOUBLE_SPECIAL = null,
            .H5_LT_OBJDIR = null,
            .H5_NO_DEPRECATED_SYMBOLS = null,
            // package information
            .HDF5_PACKAGE = "hdf5",
            .HDF5_PACKAGE_BUGREPORT = "help@hdfgroup.org",
            .HDF5_PACKAGE_NAME = "HDF5",
            .HDF5_PACKAGE_STRING = b.fmt("HDF5 v{d}.{d}.{d}", .{ version.major, version.minor, version.patch }),
            .HDF5_PACKAGE_TARNAME = "hdf5",
            .HDF5_PACKAGE_URL = "https://www.hdf5group.org",
            .HDF5_PACKAGE_VERSION_STRING = b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch }),
            // platform specific sizeof
            .H5_PAC_C_MAX_REAL_PRECISION = null,
            .H5_PAC_FC_MAX_REAL_PRECISION = null,
            .H5_SIZEOF_BOOL = t.result.cTypeByteSize(.char),
            .H5_SIZEOF_CHAR = t.result.cTypeByteSize(.char),
            .H5_SIZEOF_DOUBLE = t.result.cTypeByteSize(.double),
            .H5_SIZEOF_DOUBLE_COMPLEX = 2 * t.result.cTypeByteSize(.double),
            .H5_SIZEOF_FLOAT = t.result.cTypeByteSize(.float),
            .H5_SIZEOF_FLOAT_COMPLEX = 2 * t.result.cTypeByteSize(.float),
            .H5_SIZEOF_INT = t.result.cTypeByteSize(.int),
            .H5_SIZEOF_INT16_T = 2,
            .H5_SIZEOF_INT32_T = 4,
            .H5_SIZEOF_INT64_T = 8,
            .H5_SIZEOF_INT8_T = 1,
            .H5_SIZEOF_INT_FAST64_T = 8,
            .H5_SIZEOF_INT_FAST8_T = 1,
            .H5_SIZEOF_INT_LEAST16_T = 2,
            .H5_SIZEOF_INT_LEAST32_T = 4,
            .H5_SIZEOF_INT_LEAST64_T = 8,
            .H5_SIZEOF_INT_LEAST8_T = 1,
            .H5_SIZEOF_SIZE_T = t.result.ptrBitWidth() / 8,
            .H5_SIZEOF_LONG = t.result.cTypeByteSize(.long),
            .H5_SIZEOF_LONG_LONG = t.result.cTypeByteSize(.longlong),
            .H5_SIZEOF_LONG_DOUBLE = t.result.cTypeByteSize(.longdouble),
            .H5_SIZEOF_LONG_DOUBLE_COMPLEX = 2 * t.result.cTypeByteSize(.longdouble),
            .H5_SIZEOF_OFF_T = t.result.ptrBitWidth() / 8,
            .H5_SIZEOF_PTRDIFF_T = t.result.ptrBitWidth() / 8,
            .H5_SIZEOF_SHORT = t.result.cTypeByteSize(.short),
            .H5_SIZEOF_UINT16_T = 2,
            .H5_SIZEOF_UINT32_T = 4,
            .H5_SIZEOF_UINT64_T = 8,
            .H5_SIZEOF_UINT8_T = 1,
            .H5_SIZEOF_UINT_FAST64_T = 8,
            .H5_SIZEOF_UINT_FAST8_T = 1,
            .H5_SIZEOF_UINT_LEAST16_T = 2,
            .H5_SIZEOF_UINT_LEAST32_T = 4,
            .H5_SIZEOF_UINT_LEAST64_T = 8,
            .H5_SIZEOF_UINT_LEAST8_T = 1,
            .H5_SIZEOF_UNSIGNED = t.result.cTypeByteSize(.uint),
            // api version info
            .H5_STRICT_FORMAT_CHECKS = null,
            .H5_USE_16_API_DEFAULT = null,
            .H5_USE_18_API_DEFAULT = null,
            .H5_USE_110_API_DEFAULT = null,
            .H5_USE_112_API_DEFAULT = null,
            .H5_USE_114_API_DEFAULT = null,
            .H5_USE_200_API_DEFAULT = true,
            .H5_USE_FILE_LOCKING = true,
            .H5_USING_MEMCHECKER = null,
            .H5_VERSION = b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch }),
            .H5_WANT_DATA_ACCURACY = true,
            .H5_WANT_DCONV_EXCEPTION = true,
            .H5_SHOW_ALL_WARNINGS = null,
            .H5_WORDS_BIGENDIANR = if (t.result.cpu.arch.endian() == .big) true else null,
            .H5__FILE_OFFSET_BITS = null,
            .H5__LARGE_FILES = null,
            .H5_off_t = null,
            .H5_ssize_t = null,
        },
    );

    if (t.result.os.tag == .windows) {
        header.addValues(.{
            .H5_SIZEOF_INT_FAST16_T = 4,
            .H5_SIZEOF_INT_FAST32_T = 4,
            .H5_SIZEOF_SSIZE_T = null,
            .H5_SIZEOF_TIME_T = 8,
            .H5_SIZEOF_UINT_FAST16_T = 4,
            .H5_SIZEOF_UINT_FAST32_T = 4,
            .H5_SIZEOF__FLOAT16 = 0,
        });
    } else {
        header.addValues(.{
            .H5_SIZEOF_INT_FAST16_T = 8,
            .H5_SIZEOF_INT_FAST32_T = 8,
            .H5_SIZEOF_SSIZE_T = t.result.ptrBitWidth() / 8,
            .H5_SIZEOF_TIME_T = t.result.cTypeByteSize(.long),
            .H5_SIZEOF_UINT_FAST16_T = 8,
            .H5_SIZEOF_UINT_FAST32_T = 8,
            .H5_SIZEOF__FLOAT16 = 2,
        });

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
    "-Wformat",
    "-Wno-missing-noreturn",
};

const zlib_c_sources = [_][]const u8{
    "adler32.c",
    "compress.c",
    "crc32.c",
    "deflate.c",
    "gzclose.c",
    "gzlib.c",
    "gzread.c",
    "gzwrite.c",
    "inflate.c",
    "infback.c",
    "inftrees.c",
    "inffast.c",
    "trees.c",
    "uncompr.c",
    "zutil.c",
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
