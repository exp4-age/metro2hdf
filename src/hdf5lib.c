#include "hdf5lib.h"

// Type macros
hid_t ZIG_H5T_NATIVE_UCHAR(void) { return H5T_NATIVE_UCHAR; }
hid_t ZIG_H5T_NATIVE_USHORT(void) { return H5T_NATIVE_USHORT; }
hid_t ZIG_H5T_NATIVE_INT(void) { return H5T_NATIVE_INT; }
hid_t ZIG_H5T_NATIVE_LLONG(void) { return H5T_NATIVE_LLONG; }
hid_t ZIG_H5T_IEEE_F64LE(void) { return H5T_IEEE_F64LE; }
hid_t ZIG_H5T_C_S1(void) { return H5T_C_S1; }

// Property list macros
hid_t ZIG_H5P_LINK_CREATE(void) { return H5P_LINK_CREATE; }
hid_t ZIG_H5P_DATASET_CREATE(void) { return H5P_DATASET_CREATE; }
