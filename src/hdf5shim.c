#include "hdf5shim.h"
hid_t zig_h5t_int(void) { return H5T_NATIVE_INT; }
hid_t zig_h5t_f64(void) { return H5T_IEEE_F64LE; }
hid_t zig_h5t_string(void) { return H5T_C_S1; }
hid_t shim_H5P_LINK_CREATE(void) { return H5P_LINK_CREATE; }
