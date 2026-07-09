//
//  CVirtualHID.h
//  Exposes IOKit's IOHIDUserDevice API to Swift. These symbols exist in
//  IOKit.framework but their header (IOHIDUserDevice.h) is SPI — not shipped in
//  the public SDK — so we forward-declare them here. They link at runtime.
//

#ifndef CVirtualHID_h
#define CVirtualHID_h

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>
#include <stdint.h>

typedef struct __IOHIDUserDevice *IOHIDUserDeviceRef;

IOHIDUserDeviceRef IOHIDUserDeviceCreate(CFAllocatorRef allocator, CFDictionaryRef properties);

IOReturn IOHIDUserDeviceHandleReport(IOHIDUserDeviceRef device,
                                     const uint8_t *report,
                                     CFIndex reportLength);

#endif /* CVirtualHID_h */
