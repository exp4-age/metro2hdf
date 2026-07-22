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
      --verbose                   write processed runs and channels
                                  to stdout
      --help                      show this help and exit

HPTDC OPTIONS
      --hptdc-rebuild-tables      force rebuild of step tables by
                                  searching for scan and step markers

HPTDC OPTIONS (GRPS mode)
      --hptdc-event-type={EP,EI}  type of recorded particles
                                  (default: "EP")

HPTDC OPTIONS (HITS mode)
      --hptdc-hit-filter=FILTER   specify a filter for the tdc
                                  channels (default: "01111111")
      --hptdc-hit-mcp=NUM         tdc channel number of the MCP
                                  (default: 6) from 0 to 7
```

### Example

```bash
metro2hdf --glob="raw/*" --output-dir="events" --verbose
```

> 🛈 On Windows the equivalent glob string would be `"raw\\*"`.

### Processing HPTDC data

HPTDC data (`.tdc` files) are processed based on the HPTDC mode:

Coincidence data (HPTDC `GRPS` mode) is sorted into events by
accumulating all particles detected in between two bunch markers.
This replaces the previously used separate `sort_events` program.
All coincidences up to `9E9P` are processed. Higher coincidences
are currently not supported.

> ⚠️ This version of `metro2hdf` uses the naming convention `{m}E{n}P`!
> If `m` or `n` is `0`, the corresponding particle is omitted, e.g. `3E`.

Non-coincidence data (HPTDC `HITS` mode) is also sorted into events, but
instead using the MCP channel as the start of an event. If a channel
triggered multiple times before the next MCP signal the additional
signals are discarded and the first time is used.

> ⚠️ For the metro `dld_rd` device the data in `dld_rd#raw` may not
> match the processed `HITS` data because of a bug in metro!

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
