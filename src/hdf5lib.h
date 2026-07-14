#pragma once
#include <hdf5.h>

// Type macros
hid_t ZIG_H5T_NATIVE_UCHAR(void);
hid_t ZIG_H5T_NATIVE_USHORT(void);
hid_t ZIG_H5T_NATIVE_UINT(void);
hid_t ZIG_H5T_NATIVE_INT(void);
hid_t ZIG_H5T_NATIVE_LLONG(void);
hid_t ZIG_H5T_IEEE_F64LE(void);
hid_t ZIG_H5T_C_S1(void);

// Property list macros
hid_t ZIG_H5P_LINK_CREATE(void);
hid_t ZIG_H5P_DATASET_CREATE(void);
