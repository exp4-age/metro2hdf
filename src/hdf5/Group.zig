const Group = @This();

const std = @import("std");
const hdf5 = @import("libhdf5");

id: hdf5.hid_t = -1,

pub fn close(self: *@This()) void {
    if (self.id < 0) return;
    if (hdf5.H5Gclose(self.id) >= 0) self.id = -1;
}
