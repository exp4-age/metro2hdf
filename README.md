# metro2hdf

Group metro measurement files by run and write to a single hdf5 file per run.

> ⚠️ The hdf5 file structure may differ from the python version of `metro2hdf`!

## Installation

### Download a binary release

Prebuilt binaries are available on the
[releases page](https://github.com/exp4-age/metro2hdf/releases).
Download and extract the archive for your platform, then run the binary
from the command line.

### Build with zig

Install [zig](https://ziglang.org/download/) version 0.16.0 and then
clone and build:

```bash
git clone https://github.com/exp4-age/metro2hdf.git
cd metro2hdf
zig build -Doptimize=ReleaseFast run -- --glob="raw/*"
```

## Usage

```console
Usage: metro2hdf [OPTIONS]...

  -o, --output-dir=DIR            write hdf5 files into the specified
                                  directory (default: ".")
      --glob=GLOB                 glob string for selecting metro run
                                  files (default: "*")
  -e, --exclude=CHANNEL           exclude matching channels from
                                  processing (can be a glob string)
  -i, --include=CHANNEL           include only matching channels in
                                  the processing
      --replace                   overwrite existing files
      --help                      show this help and exit

HDF5 OPTIONS (only affects specific channels)
      --chunk-size=SIZE           chunk size (bytes) used when
                                  writing compressed datasets
                                  (default: 1e5)
      --compress=LEVEL            use gzip compression with specified
                                  level (default: 4) from 0 to 9
                                  (no compression to max compression)

HPTDC OPTIONS (GRPS mode only)
      --hptdc-decode-words        decode words generated in certain
                                  operation modes (4 bytes per word)
                                  into its type and argument
                                  (8 bytes per word)
      --hptdc-sort-events         decode words and sort events
      --hptdc-event-type={EP,EI}  type of recorded particles
                                  (default: "EP")
```

### Processing HPTDC data

HPTDC data (`.tdc` files) is written to the hdf5 file without
processing by default.
Coincidence data (HPTDC `GRPS` mode) may be either decoded by
adding the argument `--hptdc-decode-words` or sorted into
coincidence events by adding `--hptdc-sort-events`.
This replaces the previously used separate `sort_events` program.
All coincidences up to `9E9P` are processed. Higher coincidences
are currently not supported.

> ⚠️ This version of `metro2hdf` uses the naming convention `{m}E{n}P`!
> If `m` or `n` is `0`, the corresponding particle is omitted, e.g. `3E`.

### HDF5 data structure

The data in the hdf5 file is organized by scan index and step value.
In case of a single measurement without steps this will look like this:

```console
/
├─ 0                        <- scan index
|  ├─ 0.0                   <- step value
|  |  ├─ 1E                 <- coincidence events
|  |  ├─ 2E
|  |  ├─ 2E1P
|  |  ├─ ...
|  |  ├─ flowmeter#a1       <- continuous metro data channel
|  |  ├─ photodiode#value
|  |  ├─ ...
|  ├─ by_idx                <- access data by step index instead of step value
|  |  ├─ 0                  <- step index
|  |  |  ├─ 1E              <- points to the same dataset as "0/0.0/1E"
|  |  |  ├─ ...
```

### Exclude channels

Channels may be excluded by either listing the unwanted channels
`--exclude="channel"` or including only the desired channels with
`--include="channel"`. Multiple channels may be excluded / included:
`-i="channel1" -i="channel2"`. The given strings are `glob` matched
with the detected channels, e.g. `-e="coinc2_rd!*"` skips most
coincidence data channels, which are useful during data acquisition
but usually not used in data evaluation. In order to only get the
sorted events `-i="coinc2_rd#groups"` can be used.

The include list (if not empty) is matched first, any 'surviving'
channels are then tested for matches in the exclude list.
