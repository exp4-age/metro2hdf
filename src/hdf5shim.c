#include "hdf5shim.h"
hid_t zig_h5t_int(void) { return H5T_NATIVE_INT; }
hid_t zig_h5t_string(void) { return H5T_C_S1; }
