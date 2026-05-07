#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const NSInteger kDongleVendorID = 0x05ac;
static const NSInteger kDongleProductID = 0x024f;
static const NSInteger kWiredVendorID = 0x0c45;
static const NSInteger kWiredProductID = 0x800a;
static NSString * const kRGBModeDefaultsKey = @"RGBMode";
static NSString * const kRGBBrightnessDefaultsKey = @"RGBBrightness";
static NSString * const kRGBSpeedDefaultsKey = @"RGBSpeed";
static NSString * const kRGBDirectionDefaultsKey = @"RGBDirection";
static NSString * const kRGBColorDefaultsKey = @"RGBColor";
static NSString * const kRGBColorfulDefaultsKey = @"RGBColorful";
static NSString * const kKeyResponseLevelDefaultsKey = @"KeyResponseLevel";
static NSString * const kSleepTimeDefaultsKey = @"SleepTime";
static NSString * const kGameModeEnabledDefaultsKey = @"GameModeEnabled";
static BOOL gRawHIDPermissionDenied = NO;

typedef NS_ENUM(NSInteger, ScreenFitMode) {
    ScreenFitContain = 0,
    ScreenFitCover = 1,
    ScreenFitStretch = 2,
};

typedef void (^ScreenUploadProgressHandler)(uint16_t sentChunks, uint16_t totalChunks);

static NSString *ScreenFitModeTitle(ScreenFitMode fitMode) {
    switch (fitMode) {
        case ScreenFitCover:
            return @"Fill";
        case ScreenFitStretch:
            return @"Stretch";
        case ScreenFitContain:
        default:
            return @"Fit";
    }
}

static NSString *ScreenFitModeArgument(ScreenFitMode fitMode) {
    switch (fitMode) {
        case ScreenFitCover:
            return @"cover";
        case ScreenFitStretch:
            return @"stretch";
        case ScreenFitContain:
        default:
            return @"contain";
    }
}

@interface HIDEndpoint : NSObject
@property(nonatomic) NSInteger vendorID;
@property(nonatomic) NSInteger productID;
@property(nonatomic) NSInteger usagePage;
@property(nonatomic) NSInteger usage;
@property(nonatomic) NSInteger maxInputReportSize;
@property(nonatomic) NSInteger maxOutputReportSize;
@property(nonatomic) NSInteger maxFeatureReportSize;
@property(nonatomic) NSInteger locationID;
@property(nonatomic, copy) NSString *product;
@property(nonatomic, copy) NSString *transport;
@property(nonatomic, copy) NSString *batteryKey;
@property(nonatomic, strong) NSNumber *batteryPercent;
@end

@implementation HIDEndpoint
@end

@interface BatteryReading : NSObject
@property(nonatomic) NSInteger percent;
@property(nonatomic, copy) NSString *source;
@property(nonatomic, copy) NSString *detail;
@end

@implementation BatteryReading
@end

static NSInteger NumberValue(NSDictionary *properties, NSString *key, NSInteger fallback) {
    id value = properties[key];
    if ([value respondsToSelector:@selector(integerValue)]) {
        return [value integerValue];
    }
    return fallback;
}

static NSString *StringValue(NSDictionary *properties, NSString *key, NSString *fallback) {
    id value = properties[key];
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        return value;
    }
    return fallback;
}

static NSString *Hex4(NSInteger value) {
    return [NSString stringWithFormat:@"0x%04lx", (long)value];
}

static NSString *DeviceIDString(NSInteger vendorID, NSInteger productID) {
    return [NSString stringWithFormat:@"%04lX:%04lX", (long)vendorID, (long)productID];
}

static NSInteger ClampInteger(NSInteger value, NSInteger lower, NSInteger upper) {
    if (value < lower) {
        return lower;
    }
    if (value > upper) {
        return upper;
    }
    return value;
}

static NSString *RGBColorHexString(NSInteger color) {
    return [NSString stringWithFormat:@"0x%06lX", (long)(color & 0xffffff)];
}

static NSString *RGBColorDisplayString(NSInteger color) {
    return [NSString stringWithFormat:@"#%06lX", (long)(color & 0xffffff)];
}

static NSColor *NSColorFromRGBInteger(NSInteger color) {
    return [NSColor colorWithSRGBRed:((color >> 16) & 0xff) / 255.0
                               green:((color >> 8) & 0xff) / 255.0
                                blue:(color & 0xff) / 255.0
                               alpha:1.0];
}

static NSInteger RGBIntegerFromNSColor(NSColor *color) {
    NSColor *srgbColor = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: color;
    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;
    CGFloat alpha = 1.0;
    [srgbColor getRed:&red green:&green blue:&blue alpha:&alpha];
    NSInteger r = ClampInteger((NSInteger)llround(red * 255.0), 0, 255);
    NSInteger g = ClampInteger((NSInteger)llround(green * 255.0), 0, 255);
    NSInteger b = ClampInteger((NSInteger)llround(blue * 255.0), 0, 255);
    return (r << 16) | (g << 8) | b;
}

static NSArray<NSDictionary<NSString *, id> *> *RGBModeDefinitions(void) {
    return @[
        @{@"title": @"Static", @"mode": @1},
        @{@"title": @"SingleOn", @"mode": @2},
        @{@"title": @"SingleOff", @"mode": @3},
        @{@"title": @"Glittering", @"mode": @4},
        @{@"title": @"Falling", @"mode": @5},
        @{@"title": @"Colourful", @"mode": @6},
        @{@"title": @"Breath", @"mode": @7},
        @{@"title": @"Spectrum", @"mode": @8},
        @{@"title": @"Outward", @"mode": @9},
        @{@"title": @"Scrolling", @"mode": @10},
        @{@"title": @"Rolling", @"mode": @11},
        @{@"title": @"Rotating", @"mode": @12},
        @{@"title": @"Explode", @"mode": @13},
        @{@"title": @"Launch", @"mode": @14},
        @{@"title": @"Ripples", @"mode": @15},
        @{@"title": @"Flowing", @"mode": @16},
        @{@"title": @"Pulsating", @"mode": @17},
        @{@"title": @"Tilt", @"mode": @18},
        @{@"title": @"Shuttle", @"mode": @19}
    ];
}

static NSString *RGBModeTitleForMode(NSInteger mode) {
    if (mode == 0) {
        return @"LED Off";
    }
    for (NSDictionary<NSString *, id> *modeInfo in RGBModeDefinitions()) {
        if ([modeInfo[@"mode"] integerValue] == mode) {
            return modeInfo[@"title"];
        }
    }
    return [NSString stringWithFormat:@"Mode %ld", (long)mode];
}

static NSString *RGBDirectionTitle(NSInteger direction) {
    switch (direction) {
        case 0:
            return @"Right";
        case 1:
            return @"Down";
        case 2:
            return @"Left";
        case 3:
            return @"Up";
        default:
            return [NSString stringWithFormat:@"Direction %ld", (long)direction];
    }
}

static NSString *RGBSettingsSummary(NSInteger mode, NSInteger brightness, NSInteger speed, NSInteger direction, NSInteger color, BOOL colorful) {
    NSString *colorText = colorful ? @"Colorful" : RGBColorDisplayString(color);
    return [NSString stringWithFormat:@"%@  B%ld  S%ld  %@  %@", RGBModeTitleForMode(mode), (long)brightness, (long)speed, RGBDirectionTitle(direction), colorText];
}

static NSString *KeyResponseLevelName(NSInteger level) {
    switch (level) {
        case 1:
            return @"Fastest";
        case 2:
            return @"Balanced";
        case 3:
            return @"Stable";
        case 4:
            return @"Conservative";
        case 5:
            return @"Max Stability";
        default:
            return @"Unknown";
    }
}

static NSString *KeyResponse2GTiming(NSInteger level) {
    switch (level) {
        case 1:
            return @"5-6 ms";
        case 2:
            return @"7-9 ms";
        case 3:
            return @"10-12 ms";
        case 4:
            return @"15-17 ms";
        case 5:
            return @"19-21 ms";
        default:
            return @"unknown";
    }
}

static NSString *KeyResponseLevelTitle(NSInteger level) {
    return [NSString stringWithFormat:@"Level %ld %@ - 2.4G %@", (long)level, KeyResponseLevelName(level), KeyResponse2GTiming(level)];
}

static NSString *KeyResponseSettingsSummary(NSInteger level) {
    return [NSString stringWithFormat:@"Level %ld %@  2.4G %@", (long)level, KeyResponseLevelName(level), KeyResponse2GTiming(level)];
}

static NSString *SleepTimeTitle(NSInteger sleepTime) {
    switch (sleepTime) {
        case 0:
            return @"No Sleep";
        case 1:
            return @"1 min";
        case 2:
            return @"5 min";
        case 3:
            return @"30 min";
        default:
            return [NSString stringWithFormat:@"Value %ld", (long)sleepTime];
    }
}

static NSString *PerformanceSettingsSummary(NSInteger level, NSInteger sleepTime) {
    return [NSString stringWithFormat:@"%@  Sleep %@", KeyResponseSettingsSummary(level), SleepTimeTitle(sleepTime)];
}

static BOOL IsDongleEndpoint(HIDEndpoint *endpoint) {
    return endpoint.vendorID == kDongleVendorID && endpoint.productID == kDongleProductID;
}

static BOOL IsWiredEndpoint(HIDEndpoint *endpoint) {
    return endpoint.vendorID == kWiredVendorID && endpoint.productID == kWiredProductID;
}

static BOOL IsF75Endpoint(HIDEndpoint *endpoint) {
    return IsDongleEndpoint(endpoint) || IsWiredEndpoint(endpoint);
}

static NSString *FriendlyUsage(HIDEndpoint *endpoint) {
    if (endpoint.usagePage == 0x0001 && endpoint.usage == 0x0006) {
        return @"Keyboard";
    }
    if (endpoint.usagePage == 0x0001 && endpoint.usage == 0x0002) {
        return @"Mouse";
    }
    if (endpoint.usagePage == 0x000c) {
        return @"Media keys";
    }
    if (endpoint.usagePage == 0xff59 && endpoint.usage == 0x61) {
        return @"Vendor channel";
    }
    if (endpoint.usagePage == 0xff60 && endpoint.usage == 0x61) {
        return @"Raw HID channel";
    }
    return @"HID interface";
}

static NSNumber *PercentFromObject(id value, id maxValue) {
    if (!value) {
        return nil;
    }

    double current = -1.0;
    if ([value respondsToSelector:@selector(doubleValue)]) {
        current = [value doubleValue];
    } else if ([value isKindOfClass:[NSString class]]) {
        NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        current = [[trimmed stringByReplacingOccurrencesOfString:@"%" withString:@""] doubleValue];
    }

    if (current < 0.0) {
        return nil;
    }

    if (maxValue && [maxValue respondsToSelector:@selector(doubleValue)] && [maxValue doubleValue] > 0.0) {
        current = (current / [maxValue doubleValue]) * 100.0;
    } else if (current > 0.0 && current <= 1.0) {
        current *= 100.0;
    }

    NSInteger rounded = (NSInteger)llround(current);
    if (rounded < 0 || rounded > 100) {
        return nil;
    }
    return @(rounded);
}

static NSNumber *BatteryPercentFromProperties(NSDictionary *properties, NSString **sourceKey) {
    NSArray<NSString *> *directKeys = @[
        @"BatteryPercent",
        @"BatteryPercentage",
        @"Battery Percentage",
        @"BatteryLevel",
        @"Battery Level",
        @"BatteryCapacity",
        @"Battery Capacity",
        @"PercentRemaining",
        @"CurrentCapacity"
    ];

    for (NSString *key in directKeys) {
        NSNumber *percent = PercentFromObject(properties[key], nil);
        if (percent) {
            if (sourceKey) {
                *sourceKey = key;
            }
            return percent;
        }
    }

    NSNumber *current = PercentFromObject(properties[@"CurrentCapacity"], properties[@"MaxCapacity"]);
    if (current) {
        if (sourceKey) {
            *sourceKey = @"CurrentCapacity/MaxCapacity";
        }
        return current;
    }

    return nil;
}

static NSArray<HIDEndpoint *> *ScanHIDEndpoints(void) {
    NSMutableArray<HIDEndpoint *> *endpoints = [NSMutableArray array];
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDInterface"), &iterator);
    if (result != KERN_SUCCESS) {
        return endpoints;
    }

    io_registry_entry_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator))) {
        CFMutableDictionaryRef cfProperties = NULL;
        if (IORegistryEntryCreateCFProperties(service, &cfProperties, kCFAllocatorDefault, kNilOptions) == KERN_SUCCESS && cfProperties) {
            NSDictionary *properties = CFBridgingRelease(cfProperties);
            HIDEndpoint *endpoint = [[HIDEndpoint alloc] init];
            endpoint.vendorID = NumberValue(properties, @"VendorID", -1);
            endpoint.productID = NumberValue(properties, @"ProductID", -1);
            endpoint.usagePage = NumberValue(properties, @"PrimaryUsagePage", -1);
            endpoint.usage = NumberValue(properties, @"PrimaryUsage", -1);
            endpoint.maxInputReportSize = NumberValue(properties, @"MaxInputReportSize", 0);
            endpoint.maxOutputReportSize = NumberValue(properties, @"MaxOutputReportSize", 0);
            endpoint.maxFeatureReportSize = NumberValue(properties, @"MaxFeatureReportSize", 0);
            endpoint.locationID = NumberValue(properties, @"LocationID", 0);
            endpoint.product = StringValue(properties, @"Product", @"Unknown");
            endpoint.transport = StringValue(properties, @"Transport", @"Unknown");

            NSString *batteryKey = nil;
            endpoint.batteryPercent = BatteryPercentFromProperties(properties, &batteryKey);
            endpoint.batteryKey = batteryKey;

            if (IsF75Endpoint(endpoint)) {
                [endpoints addObject:endpoint];
            }
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);
    [endpoints sortUsingComparator:^NSComparisonResult(HIDEndpoint *a, HIDEndpoint *b) {
        if (a.vendorID != b.vendorID) {
            return a.vendorID < b.vendorID ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.productID != b.productID) {
            return a.productID < b.productID ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.usagePage != b.usagePage) {
            return a.usagePage < b.usagePage ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.usage != b.usage) {
            return a.usage < b.usage ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    return endpoints;
}

static BOOL NameLooksLikeF75PowerSource(NSString *name) {
    NSString *lower = [name lowercaseString];
    if ([lower containsString:@"internalbattery"]) {
        return NO;
    }
    return [lower containsString:@"aula"] ||
        [lower containsString:@"f75"] ||
        [lower containsString:@"2.4g dongle"] ||
        [lower containsString:@"keyboard"];
}

static BatteryReading *BatteryFromPowerSources(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) {
        return nil;
    }

    CFArrayRef cfSources = IOPSCopyPowerSourcesList(info);
    NSArray *sources = cfSources ? CFBridgingRelease(cfSources) : @[];
    BatteryReading *reading = nil;

    for (id source in sources) {
        NSDictionary *description = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, (__bridge CFTypeRef)source);
        if (![description isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSString *name = description[@kIOPSNameKey] ?: description[@"Name"] ?: @"Unknown";
        NSString *type = description[@kIOPSTypeKey] ?: description[@"Type"] ?: @"";
        if (!NameLooksLikeF75PowerSource(name) || [[type lowercaseString] containsString:@"internal"]) {
            continue;
        }

        NSNumber *percent = PercentFromObject(description[@kIOPSCurrentCapacityKey], description[@kIOPSMaxCapacityKey]);
        if (!percent) {
            continue;
        }

        reading = [[BatteryReading alloc] init];
        reading.percent = [percent integerValue];
        reading.source = name;

        NSString *state = description[@kIOPSPowerSourceStateKey] ?: @"";
        NSNumber *charging = description[@kIOPSIsChargingKey];
        if ([charging respondsToSelector:@selector(boolValue)] && [charging boolValue]) {
            reading.detail = @"charging";
        } else if ([state length] > 0) {
            reading.detail = [state lowercaseString];
        } else {
            reading.detail = @"power source";
        }
        break;
    }

    CFRelease(info);
    return reading;
}

typedef struct {
    BOOL seen;
    NSInteger percent;
    uint8_t *buffer;
    CFIndex bufferLength;
    BOOL debug;
} BatteryQueryContext;

static CFMutableDictionaryRef HIDMatchDictionary(NSInteger vendorID, NSInteger productID, NSInteger usagePage) {
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (!dict) {
        return NULL;
    }

    int vendor = (int)vendorID;
    int product = (int)productID;
    int page = (int)usagePage;
    CFNumberRef vendorRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor);
    CFNumberRef productRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
    CFNumberRef pageRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);

    if (vendorRef) {
        CFDictionarySetValue(dict, CFSTR(kIOHIDVendorIDKey), vendorRef);
        CFRelease(vendorRef);
    }
    if (productRef) {
        CFDictionarySetValue(dict, CFSTR(kIOHIDProductIDKey), productRef);
        CFRelease(productRef);
    }
    if (pageRef) {
        CFDictionarySetValue(dict, CFSTR(kIOHIDDeviceUsagePageKey), pageRef);
        CFRelease(pageRef);
    }

    return dict;
}

static NSInteger HIDIntProperty(IOHIDDeviceRef device, CFStringRef key, NSInteger fallback) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return fallback;
    }

    NSInteger out = fallback;
    CFNumberGetValue((CFNumberRef)value, kCFNumberNSIntegerType, &out);
    return out;
}

static void BatteryInputCallback(
    void *context,
    IOReturn result,
    void *sender,
    IOHIDReportType type,
    uint32_t reportID,
    uint8_t *report,
    CFIndex reportLength
) {
    (void)sender;
    (void)type;
    (void)reportID;

    BatteryQueryContext *query = (BatteryQueryContext *)context;
    if (query && query->debug) {
        fprintf(stderr, "battery callback result=0x%08x len=%ld", result, (long)reportLength);
        for (CFIndex i = 0; report && i < reportLength; i++) {
            fprintf(stderr, " %02x", report[i]);
        }
        fprintf(stderr, "\n");
    }
    if (!query || reportLength < 4 || !report) {
        return;
    }

    if (report[0] == 0x20 && report[1] == 0x01 && report[3] > 0 && report[3] <= 100) {
        query->seen = YES;
        query->percent = report[3];
    }
}

static BatteryReading *BatteryFromAulaRawHID(void) {
    gRawHIDPermissionDenied = NO;
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!manager) {
        return nil;
    }

    BatteryReading *reading = nil;
    CFSetRef deviceSet = NULL;
    IOHIDDeviceRef *devices = NULL;
    BatteryQueryContext context = {0};
    context.debug = getenv("AULA_F75_DEBUG") != NULL;
    IOHIDDeviceRef device = NULL;

    CFMutableDictionaryRef match = HIDMatchDictionary(kDongleVendorID, kDongleProductID, 0xff60);
    if (!match) {
        CFRelease(manager);
        return nil;
    }

    IOHIDManagerSetDeviceMatching(manager, match);
    CFRelease(match);

    IOReturn openResult = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (context.debug) {
        fprintf(stderr, "battery manager open=0x%08x\n", openResult);
    }
    if (openResult != kIOReturnSuccess) {
        if (openResult == kIOReturnNotPermitted) {
            gRawHIDPermissionDenied = YES;
        }
        CFRelease(manager);
        return nil;
    }

    deviceSet = IOHIDManagerCopyDevices(manager);
    if (context.debug) {
        fprintf(stderr, "battery matched devices=%ld\n", deviceSet ? (long)CFSetGetCount(deviceSet) : 0L);
    }
    if (!deviceSet || CFSetGetCount(deviceSet) == 0) {
        goto cleanup;
    }

    CFIndex count = CFSetGetCount(deviceSet);
    devices = calloc((size_t)count, sizeof(IOHIDDeviceRef));
    if (!devices) {
        goto cleanup;
    }
    CFSetGetValues(deviceSet, (const void **)devices);
    device = devices[0];

    NSInteger inputSize = HIDIntProperty(device, CFSTR(kIOHIDMaxInputReportSizeKey), 32);
    if (inputSize < 32) {
        inputSize = 32;
    }
    context.bufferLength = (CFIndex)inputSize;
    context.buffer = calloc((size_t)context.bufferLength, sizeof(uint8_t));
    if (!context.buffer) {
        goto cleanup;
    }

    IOHIDDeviceRegisterInputReportCallback(
        device,
        context.buffer,
        context.bufferLength,
        BatteryInputCallback,
        &context
    );
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    uint8_t payload[32] = {0};
    payload[0] = 0x20;
    payload[1] = 0x01;
    payload[31] = 0x21;
    IOReturn writeResult = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, payload, sizeof(payload));
    if (context.debug) {
        fprintf(stderr, "battery write=0x%08x\n", writeResult);
    }
    if (writeResult == kIOReturnSuccess) {
        CFAbsoluteTime stopAt = CFAbsoluteTimeGetCurrent() + 1.25;
        while (!context.seen && CFAbsoluteTimeGetCurrent() < stopAt) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        }
    }

    if (context.seen) {
        reading = [[BatteryReading alloc] init];
        reading.percent = context.percent;
        reading.source = @"2.4G raw HID";
        reading.detail = @"AULA 0x20/0x01";
    }

cleanup:
    if (device) {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    }
    free(context.buffer);
    free(devices);
    if (deviceSet) {
        CFRelease(deviceSet);
    }
    IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
    CFRelease(manager);
    return reading;
}

static BatteryReading *BatteryFromEndpoints(NSArray<HIDEndpoint *> *endpoints) {
    BOOL hasDongle = NO;
    for (HIDEndpoint *endpoint in endpoints) {
        hasDongle = hasDongle || IsDongleEndpoint(endpoint);
    }
    if (hasDongle) {
        BatteryReading *rawReading = BatteryFromAulaRawHID();
        if (rawReading) {
            return rawReading;
        }
    }

    for (HIDEndpoint *endpoint in endpoints) {
        if (endpoint.batteryPercent) {
            BatteryReading *reading = [[BatteryReading alloc] init];
            reading.percent = [endpoint.batteryPercent integerValue];
            reading.source = endpoint.product;
            reading.detail = endpoint.batteryKey ?: @"IORegistry";
            return reading;
        }
    }

    return BatteryFromPowerSources();
}

static NSString *ConnectionLabel(NSArray<HIDEndpoint *> *endpoints) {
    BOOL hasDongle = NO;
    BOOL hasWired = NO;
    for (HIDEndpoint *endpoint in endpoints) {
        hasDongle = hasDongle || IsDongleEndpoint(endpoint);
        hasWired = hasWired || IsWiredEndpoint(endpoint);
    }

    if (hasWired && hasDongle) {
        return @"USB wired + 2.4G dongle";
    }
    if (hasWired) {
        return @"USB wired";
    }
    if (hasDongle) {
        return @"2.4G dongle";
    }
    return @"Not connected";
}

static NSString *EndpointTitle(HIDEndpoint *endpoint) {
    return [NSString stringWithFormat:@"%@ %@/%@ in %ld out %ld feature %ld",
        FriendlyUsage(endpoint),
        Hex4(endpoint.usagePage),
        Hex4(endpoint.usage),
        (long)endpoint.maxInputReportSize,
        (long)endpoint.maxOutputReportSize,
        (long)endpoint.maxFeatureReportSize
    ];
}

static NSString *ShortTimeString(NSDate *date) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterNoStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    return [formatter stringFromDate:date];
}

static NSMenuItem *DisabledMenuItem(NSString *title) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    return item;
}

static NSImage *SymbolImage(NSString *name, CGFloat size) {
    NSImage *image = nil;
    if ([NSImage respondsToSelector:@selector(imageWithSystemSymbolName:accessibilityDescription:)]) {
        image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    }
    if (image) {
        image.template = YES;
        image.size = NSMakeSize(size, size);
    }
    return image;
}

static void SetMenuItemSymbol(NSMenuItem *item, NSString *symbolName) {
    NSImage *image = SymbolImage(symbolName, 16.0);
    if (image) {
        item.image = image;
    }
}

static NSMenuItem *DisabledMenuItemWithSymbol(NSString *title, NSString *symbolName) {
    NSMenuItem *item = DisabledMenuItem(title);
    SetMenuItemSymbol(item, symbolName);
    return item;
}

static NSImage *StatusKeyboardIcon(void) {
    NSImage *image = nil;
    if ([NSImage respondsToSelector:@selector(imageWithSystemSymbolName:accessibilityDescription:)]) {
        image = [NSImage imageWithSystemSymbolName:@"keyboard" accessibilityDescription:@"Aula F75 Max"];
    }
    if (!image) {
        image = [[NSImage alloc] initWithSize:NSMakeSize(18.0, 18.0)];
        [image lockFocus];
        [[NSColor labelColor] setStroke];
        NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2.0, 4.0, 14.0, 10.0) xRadius:2.0 yRadius:2.0];
        body.lineWidth = 1.3;
        [body stroke];
        for (NSInteger row = 0; row < 2; row++) {
            for (NSInteger col = 0; col < 4; col++) {
                NSRect keyRect = NSMakeRect(4.0 + (CGFloat)col * 2.6, 6.0 + (CGFloat)row * 3.0, 1.4, 1.4);
                NSBezierPath *key = [NSBezierPath bezierPathWithRect:keyRect];
                key.lineWidth = 0.8;
                [key stroke];
            }
        }
        [image unlockFocus];
    }
    image.template = YES;
    image.size = NSMakeSize(18.0, 18.0);
    return image;
}

static NSURL *LegacyLaunchAgentURL(void) {
    NSArray<NSURL *> *libraryURLs = [[NSFileManager defaultManager] URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask];
    NSURL *libraryURL = [libraryURLs firstObject];
    if (!libraryURL) {
        return nil;
    }
    return [[libraryURL URLByAppendingPathComponent:@"LaunchAgents" isDirectory:YES] URLByAppendingPathComponent:@"local.aula.f75bar.login.plist"];
}

static BOOL LegacyLaunchAgentEnabled(void) {
    NSURL *url = LegacyLaunchAgentURL();
    return url && [[NSFileManager defaultManager] fileExistsAtPath:url.path];
}

static BOOL RemoveLegacyLaunchAgent(NSString **message) {
    NSURL *url = LegacyLaunchAgentURL();
    if (!url || ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        return YES;
    }

    NSError *error = nil;
    if ([[NSFileManager defaultManager] removeItemAtURL:url error:&error]) {
        return YES;
    }
    if (message) {
        *message = [NSString stringWithFormat:@"Could not remove LaunchAgent: %@", error.localizedDescription ?: @"unknown error"];
    }
    return NO;
}

static BOOL WriteLegacyLaunchAgent(NSString **message) {
    NSURL *url = LegacyLaunchAgentURL();
    NSURL *bundleURL = [NSBundle mainBundle].bundleURL;
    if (!url || !bundleURL) {
        if (message) {
            *message = @"Could not resolve the LaunchAgent or app bundle path";
        }
        return NO;
    }

    NSDictionary *plist = @{
        @"Label": @"local.aula.f75bar.login",
        @"ProgramArguments": @[@"/usr/bin/open", @"-g", bundleURL.path],
        @"RunAtLoad": @YES,
        @"KeepAlive": @NO
    };

    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    if (!data) {
        if (message) {
            *message = [NSString stringWithFormat:@"Could not create LaunchAgent plist: %@", error.localizedDescription ?: @"unknown error"];
        }
        return NO;
    }

    NSURL *directoryURL = [url URLByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:&error]) {
        if (message) {
            *message = [NSString stringWithFormat:@"Could not create LaunchAgents folder: %@", error.localizedDescription ?: @"unknown error"];
        }
        return NO;
    }

    if (![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
        if (message) {
            *message = [NSString stringWithFormat:@"Could not write LaunchAgent: %@", error.localizedDescription ?: @"unknown error"];
        }
        return NO;
    }

    if (message) {
        *message = @"Launch at Login enabled";
    }
    return YES;
}

static BOOL LaunchAtLoginEnabled(void) {
    if (@available(macOS 13.0, *)) {
        SMAppServiceStatus status = [SMAppService mainAppService].status;
        if (status == SMAppServiceStatusEnabled) {
            return YES;
        }
    }
    return LegacyLaunchAgentEnabled();
}

static BOOL SetLaunchAtLoginEnabled(BOOL enabled, NSString **message) {
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        SMAppService *service = [SMAppService mainAppService];
        SMAppServiceStatus status = service.status;

        if (enabled) {
            if (status == SMAppServiceStatusEnabled) {
                RemoveLegacyLaunchAgent(nil);
                if (message) {
                    *message = @"Launch at Login already enabled";
                }
                return YES;
            }

            if ([service registerAndReturnError:&error]) {
                if (message) {
                    *message = @"Launch at Login enabled";
                }
                if (service.status == SMAppServiceStatusRequiresApproval) {
                    return WriteLegacyLaunchAgent(message);
                }
                RemoveLegacyLaunchAgent(nil);
                return YES;
            }
        } else {
            BOOL serviceOK = YES;
            if (status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval) {
                serviceOK = [service unregisterAndReturnError:&error];
            }
            BOOL legacyOK = RemoveLegacyLaunchAgent(message);
            if (serviceOK && legacyOK) {
                if (message) {
                    *message = @"Launch at Login disabled";
                }
                return YES;
            }
            if (message && error) {
                *message = [NSString stringWithFormat:@"Could not disable Launch at Login: %@", error.localizedDescription ?: @"unknown error"];
            }
            return NO;
        }
    }

    if (enabled) {
        return WriteLegacyLaunchAgent(message);
    }
    BOOL ok = RemoveLegacyLaunchAgent(message);
    if (ok && message) {
        *message = @"Launch at Login disabled";
    }
    return ok;
}

static BOOL HasWiredScreenEndpoints(NSArray<HIDEndpoint *> *endpoints) {
    BOOL hasControl = NO;
    BOOL hasScreenPipe = NO;
    for (HIDEndpoint *endpoint in endpoints) {
        if (!IsWiredEndpoint(endpoint)) {
            continue;
        }
        hasControl = hasControl || endpoint.usagePage == 0xff13;
        hasScreenPipe = hasScreenPipe || endpoint.usagePage == 0xff68;
    }
    return hasControl && hasScreenPipe;
}

static BOOL HasDongleRawEndpoint(NSArray<HIDEndpoint *> *endpoints) {
    for (HIDEndpoint *endpoint in endpoints) {
        if (IsDongleEndpoint(endpoint) && endpoint.usagePage == 0xff60 && endpoint.maxOutputReportSize >= 32) {
            return YES;
        }
    }
    return NO;
}

typedef struct {
    IOHIDManagerRef manager;
    IOHIDDeviceRef control;
    IOHIDDeviceRef screenPipe;
    uint8_t *controlInputBuffer;
    CFIndex controlInputBufferLength;
    uint8_t *screenInputBuffer;
    CFIndex screenInputBufferLength;
    uint8_t lastScreenReport[64];
    CFIndex lastScreenReportLength;
    uint64_t screenReportCounter;
} ScreenHIDContext;

static void ScreenInputCallback(
    void *context,
    IOReturn result,
    void *sender,
    IOHIDReportType type,
    uint32_t reportID,
    uint8_t *report,
    CFIndex reportLength
) {
    (void)result;
    (void)type;
    (void)reportID;

    (void)sender;

    ScreenHIDContext *screenContext = (ScreenHIDContext *)context;
    if (!screenContext || !report || reportLength <= 0) {
        return;
    }

    CFIndex copyLength = MIN(reportLength, (CFIndex)sizeof(screenContext->lastScreenReport));
    memcpy(screenContext->lastScreenReport, report, (size_t)copyLength);
    screenContext->lastScreenReportLength = copyLength;
    screenContext->screenReportCounter++;
}

static void CloseScreenHID(ScreenHIDContext *context) {
    if (context->control) {
        IOHIDDeviceUnscheduleFromRunLoop(context->control, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(context->control);
    }
    if (context->screenPipe) {
        IOHIDDeviceUnscheduleFromRunLoop(context->screenPipe, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(context->screenPipe);
    }
    free(context->controlInputBuffer);
    free(context->screenInputBuffer);
    if (context->manager) {
        IOHIDManagerClose(context->manager, kIOHIDOptionsTypeNone);
        CFRelease(context->manager);
    }
    memset(context, 0, sizeof(*context));
}

static BOOL OpenScreenHID(ScreenHIDContext *context, NSString **message) {
    memset(context, 0, sizeof(*context));
    context->manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!context->manager) {
        if (message) {
            *message = @"Could not create HID manager";
        }
        return NO;
    }

    CFMutableArrayRef matches = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    CFMutableDictionaryRef controlMatch = HIDMatchDictionary(kWiredVendorID, kWiredProductID, 0xff13);
    CFMutableDictionaryRef screenMatch = HIDMatchDictionary(kWiredVendorID, kWiredProductID, 0xff68);
    if (controlMatch) {
        CFArrayAppendValue(matches, controlMatch);
        CFRelease(controlMatch);
    }
    if (screenMatch) {
        CFArrayAppendValue(matches, screenMatch);
        CFRelease(screenMatch);
    }
    IOHIDManagerSetDeviceMatchingMultiple(context->manager, matches);
    CFRelease(matches);

    IOReturn openResult = IOHIDManagerOpen(context->manager, kIOHIDOptionsTypeNone);
    if (openResult != kIOReturnSuccess) {
        if (message) {
            *message = [NSString stringWithFormat:@"Screen HID open failed 0x%08x", openResult];
        }
        CloseScreenHID(context);
        return NO;
    }

    CFSetRef deviceSet = IOHIDManagerCopyDevices(context->manager);
    if (!deviceSet || CFSetGetCount(deviceSet) == 0) {
        if (message) {
            *message = @"No wired screen HID endpoints";
        }
        if (deviceSet) {
            CFRelease(deviceSet);
        }
        CloseScreenHID(context);
        return NO;
    }

    CFIndex count = CFSetGetCount(deviceSet);
    IOHIDDeviceRef *devices = calloc((size_t)count, sizeof(IOHIDDeviceRef));
    if (!devices) {
        CFRelease(deviceSet);
        CloseScreenHID(context);
        if (message) {
            *message = @"Could not allocate HID list";
        }
        return NO;
    }

    CFSetGetValues(deviceSet, (const void **)devices);
    for (CFIndex i = 0; i < count; i++) {
        NSInteger usagePage = HIDIntProperty(devices[i], CFSTR(kIOHIDPrimaryUsagePageKey), -1);
        if (usagePage == 0xff13 && !context->control) {
            context->control = (IOHIDDeviceRef)CFRetain(devices[i]);
        } else if (usagePage == 0xff68 && !context->screenPipe) {
            context->screenPipe = (IOHIDDeviceRef)CFRetain(devices[i]);
        }
    }
    free(devices);
    CFRelease(deviceSet);

    if (!context->control || !context->screenPipe) {
        if (message) {
            *message = @"Missing screen control or image pipe";
        }
        CloseScreenHID(context);
        return NO;
    }

    NSInteger controlInputSize = HIDIntProperty(context->control, CFSTR(kIOHIDMaxInputReportSizeKey), 64);
    if (controlInputSize < 1) {
        controlInputSize = 64;
    }
    context->controlInputBufferLength = (CFIndex)controlInputSize;
    context->controlInputBuffer = calloc((size_t)context->controlInputBufferLength, sizeof(uint8_t));
    if (!context->controlInputBuffer) {
        if (message) {
            *message = @"Could not allocate screen control buffer";
        }
        CloseScreenHID(context);
        return NO;
    }
    IOHIDDeviceRegisterInputReportCallback(
        context->control,
        context->controlInputBuffer,
        context->controlInputBufferLength,
        ScreenInputCallback,
        context
    );
    IOHIDDeviceScheduleWithRunLoop(context->control, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    NSInteger screenInputSize = HIDIntProperty(context->screenPipe, CFSTR(kIOHIDMaxInputReportSizeKey), 64);
    if (screenInputSize < 1) {
        screenInputSize = 64;
    }
    context->screenInputBufferLength = (CFIndex)screenInputSize;
    context->screenInputBuffer = calloc((size_t)context->screenInputBufferLength, sizeof(uint8_t));
    if (!context->screenInputBuffer) {
        if (message) {
            *message = @"Could not allocate screen image buffer";
        }
        CloseScreenHID(context);
        return NO;
    }
    IOHIDDeviceRegisterInputReportCallback(
        context->screenPipe,
        context->screenInputBuffer,
        context->screenInputBufferLength,
        ScreenInputCallback,
        context
    );
    IOHIDDeviceScheduleWithRunLoop(context->screenPipe, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    return YES;
}

static NSString *HexPreview(const uint8_t *bytes, CFIndex length, CFIndex maxLength) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    CFIndex count = MIN(length, maxLength);
    for (CFIndex i = 0; i < count; i++) {
        [parts addObject:[NSString stringWithFormat:@"%02x", bytes[i]]];
    }
    return [parts componentsJoinedByString:@" "];
}

static void LogScreenFeatureAckIfDebug(IOHIDDeviceRef control, const uint8_t *command, CFIndex commandLength) {
    if (!getenv("AULA_F75_DEBUG")) {
        return;
    }

    IOReturn lastResult = kIOReturnSuccess;
    CFIndex lastLength = 0;
    uint8_t lastAck[64] = {0};
    BOOL acknowledged = NO;
    for (NSUInteger attempt = 0; attempt < 5; attempt++) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.04, false);

        CFIndex ackLength = sizeof(lastAck);
        memset(lastAck, 0, sizeof(lastAck));
        lastResult = IOHIDDeviceGetReport(control, kIOHIDReportTypeFeature, 0, lastAck, &ackLength);
        lastLength = ackLength;
        if (lastResult == kIOReturnSuccess && ackLength >= 4 && lastAck[3] == 0x01) {
            acknowledged = YES;
            break;
        }
    }

    fprintf(
        stderr,
        "screen feature command=%s ack=%s result=0x%08x len=%ld bytes=%s\n",
        [HexPreview(command, commandLength, 16) UTF8String],
        acknowledged ? "yes" : "no",
        lastResult,
        (long)lastLength,
        [HexPreview(lastAck, lastLength, 16) UTF8String]
    );
}

static BOOL SendScreenFeature(IOHIDDeviceRef control, const uint8_t *bytes, CFIndex length, NSString **message) {
    uint8_t payload[64] = {0};
    if (length > (CFIndex)sizeof(payload)) {
        length = (CFIndex)sizeof(payload);
    }
    memcpy(payload, bytes, (size_t)length);

    IOReturn result = IOHIDDeviceSetReport(control, kIOHIDReportTypeFeature, 0, payload, sizeof(payload));
    if (result != kIOReturnSuccess) {
        if (message) {
            *message = [NSString stringWithFormat:@"Screen feature write failed 0x%08x", result];
        }
        return NO;
    }

    LogScreenFeatureAckIfDebug(control, payload, sizeof(payload));
    return YES;
}

static BOOL LastScreenReportIsChunkAck(ScreenHIDContext *context) {
    return context->lastScreenReportLength >= 3;
}

static BOOL WaitForScreenChunkAck(ScreenHIDContext *context, uint64_t beforeCounter, NSTimeInterval timeoutSeconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while ([deadline timeIntervalSinceNow] > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, false);
        if (context->screenReportCounter != beforeCounter && LastScreenReportIsChunkAck(context)) {
            return YES;
        }
    }
    return NO;
}

static void LogScreenChunkIfDebug(ScreenHIDContext *context, const uint8_t *chunk, uint16_t index, uint16_t total, IOReturn result, BOOL acknowledged) {
    if (!getenv("AULA_F75_DEBUG")) {
        return;
    }
    if (total > 16 && index != 1 && index != total && index % 16 != 0 && result == kIOReturnSuccess && acknowledged) {
        return;
    }

    fprintf(
        stderr,
        "screen chunk %u/%u result=0x%08x ack=%s first16=%s lastInput=%s\n",
        index,
        total,
        result,
        acknowledged ? "yes" : "no",
        [HexPreview(chunk, 4096, 16) UTF8String],
        [HexPreview(context->lastScreenReport, context->lastScreenReportLength, 16) UTF8String]
    );
}

static BOOL SendScreenChunkWithAck(ScreenHIDContext *context, const uint8_t *chunk, uint16_t index, uint16_t total, NSString **message) {
    uint64_t beforeCounter = context->screenReportCounter;
    IOReturn result = IOHIDDeviceSetReport(
        context->screenPipe,
        kIOHIDReportTypeOutput,
        0,
        chunk,
        4096
    );
    if (result != kIOReturnSuccess) {
        if (message) {
            *message = [NSString stringWithFormat:@"Screen image chunk %u failed 0x%08x", index, result];
        }
        LogScreenChunkIfDebug(context, chunk, index, total, result, NO);
        return NO;
    }

    BOOL acknowledged = WaitForScreenChunkAck(context, beforeCounter, 0.35);
    LogScreenChunkIfDebug(context, chunk, index, total, result, acknowledged);
    if (!acknowledged) {
        if (message) {
            *message = [NSString stringWithFormat:@"Native screen upload chunk %u ack timed out", index];
        }
        return NO;
    }

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, false);
    return YES;
}

static uint16_t RGB565(uint8_t r, uint8_t g, uint8_t b) {
    return (uint16_t)(((uint16_t)(r & 0xf8) << 8) | ((uint16_t)(g & 0xfc) << 3) | (b >> 3));
}

static void WriteRGB565Pixel(uint8_t *stream, size_t offset, uint16_t color) {
    stream[offset] = (uint8_t)(color & 0xff);
    stream[offset + 1] = (uint8_t)(color >> 8);
}

static void WriteRainbowPixel(uint8_t *stream, size_t pixelOffset, NSUInteger x, NSUInteger y) {
    const NSUInteger width = 128;
    const NSUInteger height = 128;
    uint8_t r = (uint8_t)((x * 255) / (width - 1));
    uint8_t g = (uint8_t)((y * 255) / (height - 1));
    uint8_t b = (uint8_t)(255 - ((x + y) * 255) / ((width - 1) + (height - 1)));

    if (x < 4 || y < 4 || x >= width - 4 || y >= height - 4 || x == y || x + y == width - 1) {
        r = 255;
        g = 255;
        b = 255;
    }
    WriteRGB565Pixel(stream, pixelOffset, RGB565(r, g, b));
}

static CGRect ScreenDrawRect(CGFloat sourceWidth, CGFloat sourceHeight, ScreenFitMode fitMode) {
    const CGFloat targetWidth = 128.0;
    const CGFloat targetHeight = 128.0;
    if (sourceWidth <= 0.0 || sourceHeight <= 0.0) {
        return CGRectMake(0, 0, targetWidth, targetHeight);
    }

    CGSize drawSize = CGSizeMake(targetWidth, targetHeight);
    if (fitMode != ScreenFitStretch) {
        CGFloat scaleX = targetWidth / sourceWidth;
        CGFloat scaleY = targetHeight / sourceHeight;
        CGFloat scale = fitMode == ScreenFitCover ? MAX(scaleX, scaleY) : MIN(scaleX, scaleY);
        drawSize = CGSizeMake(sourceWidth * scale, sourceHeight * scale);
    }

    return CGRectMake((targetWidth - drawSize.width) / 2.0, (targetHeight - drawSize.height) / 2.0, drawSize.width, drawSize.height);
}

static NSBitmapImageRep *BitmapRepForScreenImage(NSImage *image, ScreenFitMode fitMode) {
    if (!image || image.size.width <= 0 || image.size.height <= 0) {
        return nil;
    }

    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
        pixelsWide:128
        pixelsHigh:128
        bitsPerSample:8
        samplesPerPixel:4
        hasAlpha:YES
        isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:128 * 4
        bitsPerPixel:32
    ];
    if (!bitmap) {
        return nil;
    }

    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext setCurrentContext:context];
    [[NSColor blackColor] setFill];
    NSRectFill(NSMakeRect(0, 0, 128, 128));

    CGRect fitRect = ScreenDrawRect(image.size.width, image.size.height, fitMode);
    NSRect drawRect = NSMakeRect(fitRect.origin.x, fitRect.origin.y, fitRect.size.width, fitRect.size.height);
    [image drawInRect:drawRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}

static uint8_t *CreateScreenStream(NSImage *image, uint8_t frameCount, uint8_t frameDelay, ScreenFitMode fitMode, size_t *streamLength, uint16_t *chunkCount) {
    const size_t width = 128;
    const size_t height = 128;
    const size_t headerLength = 256;
    const size_t frameBytes = width * height * 2;
    const size_t payloadLength = headerLength + ((size_t)frameCount * frameBytes);
    const size_t chunks = (payloadLength + 4095) / 4096;
    const size_t paddedLength = chunks * 4096;
    uint8_t *stream = malloc(paddedLength);
    if (!stream) {
        return NULL;
    }

    memset(stream, 0x00, paddedLength);
    stream[0] = frameCount;
    for (uint8_t i = 0; i < frameCount; i++) {
        stream[1 + i] = frameDelay;
    }

    NSBitmapImageRep *bitmap = BitmapRepForScreenImage(image, fitMode);
    for (uint8_t frame = 0; frame < frameCount; frame++) {
        size_t frameOffset = headerLength + ((size_t)frame * frameBytes);
        for (NSUInteger y = 0; y < height; y++) {
            for (NSUInteger x = 0; x < width; x++) {
                size_t pixelOffset = frameOffset + ((y * width + x) * 2);
                if (!bitmap) {
                    WriteRainbowPixel(stream, pixelOffset, x, y);
                    continue;
                }

                NSColor *color = [[bitmap colorAtX:(NSInteger)x y:(NSInteger)y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
                uint8_t r = (uint8_t)llround(MAX(0.0, MIN(1.0, color.redComponent)) * 255.0);
                uint8_t g = (uint8_t)llround(MAX(0.0, MIN(1.0, color.greenComponent)) * 255.0);
                uint8_t b = (uint8_t)llround(MAX(0.0, MIN(1.0, color.blueComponent)) * 255.0);
                WriteRGB565Pixel(stream, pixelOffset, RGB565(r, g, b));
            }
        }
    }

    *streamLength = paddedLength;
    *chunkCount = (uint16_t)chunks;
    return stream;
}

static uint8_t DelayByteFromGIFProperties(NSDictionary *properties) {
    NSDictionary *gif = properties[(NSString *)kCGImagePropertyGIFDictionary];
    NSNumber *delay = gif[(NSString *)kCGImagePropertyGIFUnclampedDelayTime] ?: gif[(NSString *)kCGImagePropertyGIFDelayTime];
    double seconds = [delay respondsToSelector:@selector(doubleValue)] ? [delay doubleValue] : 0.01;
    if (seconds <= 0.0) {
        seconds = 0.01;
    }

    NSInteger value = (NSInteger)llround(seconds * 500.0); // Keyboard delay units are about 2 ms.
    if (value < 1) {
        value = 1;
    } else if (value > 255) {
        value = 255;
    }
    return (uint8_t)value;
}

static void WriteCGImageToScreenFrame(uint8_t *stream, size_t frameOffset, CGImageRef image, ScreenFitMode fitMode) {
    const size_t width = 128;
    const size_t height = 128;
    const size_t bytesPerPixel = 4;
    const size_t bytesPerRow = width * bytesPerPixel;
    uint8_t *rgba = calloc(width * height, bytesPerPixel);
    if (!rgba) {
        return;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        rgba,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    if (!context) {
        CGColorSpaceRelease(colorSpace);
        free(rgba);
        return;
    }

    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));

    CGRect drawRect = ScreenDrawRect((CGFloat)CGImageGetWidth(image), (CGFloat)CGImageGetHeight(image), fitMode);
    CGContextDrawImage(context, drawRect, image);

    for (NSUInteger y = 0; y < height; y++) {
        for (NSUInteger x = 0; x < width; x++) {
            size_t rgbaOffset = ((y * width) + x) * bytesPerPixel;
            size_t pixelOffset = frameOffset + ((y * width + x) * 2);
            WriteRGB565Pixel(stream, pixelOffset, RGB565(rgba[rgbaOffset], rgba[rgbaOffset + 1], rgba[rgbaOffset + 2]));
        }
    }

    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(rgba);
}

static uint8_t *CreateScreenStreamFromURL(
    NSURL *url,
    uint8_t stillFrameCount,
    uint8_t stillFrameDelay,
    uint8_t maxAnimatedFrames,
    BOOL loopAnimated,
    ScreenFitMode fitMode,
    size_t *streamLength,
    uint16_t *chunkCount,
    uint8_t *actualFrameCount,
    BOOL *animated,
    size_t *sourceFrameCountOut,
    NSString **message
) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) {
        if (message) {
            *message = @"Could not read image source";
        }
        return NULL;
    }

    size_t sourceCount = CGImageSourceGetCount(source);
    BOOL isAnimated = sourceCount > 1;
    uint8_t frameCount = isAnimated ? (loopAnimated ? maxAnimatedFrames : (uint8_t)MIN(sourceCount, (size_t)maxAnimatedFrames)) : stillFrameCount;
    if (frameCount < 1) {
        frameCount = 1;
    }
    const size_t width = 128;
    const size_t height = 128;
    const size_t headerLength = 256;
    const size_t frameBytes = width * height * 2;
    const size_t payloadLength = headerLength + ((size_t)frameCount * frameBytes);
    const size_t chunks = (payloadLength + 4095) / 4096;
    const size_t paddedLength = chunks * 4096;

    uint8_t *stream = malloc(paddedLength);
    if (!stream) {
        CFRelease(source);
        if (message) {
            *message = @"Could not allocate image stream";
        }
        return NULL;
    }
    memset(stream, 0x00, paddedLength);
    stream[0] = frameCount;

    for (uint8_t frame = 0; frame < frameCount; frame++) {
        size_t sourceIndex = isAnimated ? (loopAnimated ? ((size_t)frame % sourceCount) : (size_t)frame) : 0;
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, sourceIndex, NULL));
        stream[1 + frame] = isAnimated ? DelayByteFromGIFProperties(properties ?: @{}) : stillFrameDelay;

        CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, sourceIndex, NULL);
        if (!cgImage) {
            continue;
        }

        size_t frameOffset = headerLength + ((size_t)frame * frameBytes);
        WriteCGImageToScreenFrame(stream, frameOffset, cgImage, fitMode);
        CGImageRelease(cgImage);
    }

    CFRelease(source);
    *streamLength = paddedLength;
    *chunkCount = (uint16_t)chunks;
    if (actualFrameCount) {
        *actualFrameCount = frameCount;
    }
    if (animated) {
        *animated = isAnimated;
    }
    if (sourceFrameCountOut) {
        *sourceFrameCountOut = sourceCount;
    }
    return stream;
}

static BOOL UploadScreenStream(uint8_t *stream, uint16_t chunkCount, uint8_t frameCount, NSString *label, ScreenUploadProgressHandler progressHandler, NSString **message) {
    ScreenHIDContext context;
    if (!OpenScreenHID(&context, message)) {
        return NO;
    }

    const uint8_t beginCommand[] = {0x04, 0x18};
    uint8_t metadataCommand[10] = {0};
    metadataCommand[0] = 0x04;
    metadataCommand[1] = 0x72;
    metadataCommand[2] = 0x01;
    metadataCommand[8] = (uint8_t)(chunkCount & 0xff);
    metadataCommand[9] = (uint8_t)(chunkCount >> 8);
    const uint8_t exitCommand[] = {0x04, 0x02};

    BOOL ok = SendScreenFeature(context.control, beginCommand, sizeof(beginCommand), message);
    if (ok) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
        ok = SendScreenFeature(context.control, metadataCommand, sizeof(metadataCommand), message);
    }
    if (ok) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }

    for (uint16_t i = 0; ok && i < chunkCount; i++) {
        if (!SendScreenChunkWithAck(&context, stream + ((size_t)i * 4096), i + 1, chunkCount, message)) {
            ok = NO;
            break;
        }
        if (progressHandler) {
            progressHandler(i + 1, chunkCount);
        }
    }

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    SendScreenFeature(context.control, exitCommand, sizeof(exitCommand), NULL);
    CloseScreenHID(&context);

    if (ok && message) {
        *message = [NSString stringWithFormat:@"Uploaded %@ (%u frame%@)", label, frameCount, frameCount == 1 ? @"" : @"s"];
    }
    return ok;
}

static BOOL UploadScreenBootAnimation(NSImage *image, uint8_t frameCount, uint8_t frameDelay, ScreenUploadProgressHandler progressHandler, NSString **message) {
    size_t streamLength = 0;
    uint16_t chunkCount = 0;
    uint8_t *stream = CreateScreenStream(image, frameCount, frameDelay, ScreenFitContain, &streamLength, &chunkCount);
    if (!stream) {
        if (message) {
            *message = @"Could not build screen frame data";
        }
        return NO;
    }

    BOOL ok = UploadScreenStream(stream, chunkCount, frameCount, @"screen animation", progressHandler, message);
    free(stream);
    (void)streamLength;
    return ok;
}

static NSString *TailString(NSString *string, NSUInteger maxLength) {
    if ([string length] <= maxLength) {
        return string;
    }
    return [string substringFromIndex:[string length] - maxLength];
}

static NSURL *ProbeExecutableURL(void) {
    NSURL *bundleExecutableURL = [NSBundle mainBundle].executableURL;
    NSURL *bundledURL = [[bundleExecutableURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"F75Probe"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:bundledURL.path]) {
        return bundledURL;
    }

    NSURL *siblingURL = [[[[NSBundle mainBundle] bundleURL] URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"F75Probe"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:siblingURL.path]) {
        return siblingURL;
    }

    return bundledURL ?: siblingURL;
}

static BOOL RunProbeScreenUploadFallback(NSURL *url, ScreenFitMode fitMode, uint8_t maxAnimatedFrames, NSString **message) {
    NSURL *probeURL = ProbeExecutableURL();
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:probeURL.path]) {
        if (message) {
            *message = [NSString stringWithFormat:@"Screen upload helper was not found at %@", probeURL.path];
        }
        return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = probeURL;
    task.currentDirectoryURL = [probeURL URLByDeletingLastPathComponent];
    task.arguments = @[
        @"--wired",
        @"--screen-upload-image", url.path,
        @"--screen-loop-fill",
        @"--screen-max-frames", [NSString stringWithFormat:@"%u", maxAnimatedFrames],
        @"--screen-fit", ScreenFitModeArgument(fitMode),
        @"--screen-pixel-format", @"rgb565le",
        @"--screen-pixel-layout", @"row",
        @"--screen-slot", @"1",
        @"--screen-chunk-ack",
        @"--screen-chunk-delay", @"0.005",
        @"--seconds", @"1"
    ];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        if (message) {
            *message = [NSString stringWithFormat:@"Screen upload helper could not start: %@", exception.reason ?: exception.name];
        }
        return NO;
    }

    NSData *outputData = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    if (task.terminationStatus == 0) {
        if (message) {
            *message = [NSString stringWithFormat:@"Uploaded screen animation (%@)", ScreenFitModeTitle(fitMode)];
        }
        return YES;
    }

    if (message) {
        NSString *tail = TailString([output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]], 360);
        *message = [NSString stringWithFormat:@"Screen upload helper failed (%d)%@", task.terminationStatus, [tail length] > 0 ? [NSString stringWithFormat:@": %@", tail] : @""];
    }
    return NO;
}

static BOOL RunProbeRGBMode(NSInteger mode, NSInteger brightness, NSInteger speed, NSInteger direction, NSInteger color, BOOL colorful, NSString *modeTitle, NSString **message) {
    if (mode < 0 || mode > 31) {
        if (message) {
            *message = [NSString stringWithFormat:@"RGB mode %ld is outside the supported probe range", (long)mode];
        }
        return NO;
    }
    brightness = ClampInteger(brightness, 1, 5);
    speed = ClampInteger(speed, 1, 5);
    direction = ClampInteger(direction, 0, 3);
    color = ClampInteger(color, 0, 0xffffff);

    NSURL *probeURL = ProbeExecutableURL();
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:probeURL.path]) {
        if (message) {
            *message = [NSString stringWithFormat:@"Keyboard helper was not found at %@", probeURL.path];
        }
        return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = probeURL;
    task.currentDirectoryURL = [probeURL URLByDeletingLastPathComponent];
    task.arguments = @[
        @"--dongle",
        @"--rgb-led-mode", [NSString stringWithFormat:@"%ld", (long)mode],
        @"--rgb-page", @"0xff60",
        @"--rgb-brightness", [NSString stringWithFormat:@"%ld", (long)brightness],
        @"--rgb-speed", [NSString stringWithFormat:@"%ld", (long)speed],
        @"--rgb-direction", [NSString stringWithFormat:@"%ld", (long)direction],
        @"--rgb-color", RGBColorHexString(color),
        @"--rgb-colorful", colorful ? @"1" : @"0",
        @"--seconds", @"1"
    ];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        if (message) {
            *message = [NSString stringWithFormat:@"F75Probe could not start: %@", exception.reason ?: exception.name];
        }
        return NO;
    }

    NSData *outputData = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    if (task.terminationStatus == 0) {
        if (message) {
            NSString *title = [modeTitle length] > 0 ? modeTitle : RGBModeTitleForMode(mode);
            NSString *colorText = colorful ? @"Colorful" : RGBColorDisplayString(color);
            *message = [NSString stringWithFormat:@"RGB lighting set: %@  B%ld  S%ld  %@  %@", title, (long)brightness, (long)speed, RGBDirectionTitle(direction), colorText];
        }
        return YES;
    }

    if (message) {
        NSString *tail = TailString([output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]], 360);
        *message = [NSString stringWithFormat:@"RGB mode failed (%d)%@", task.terminationStatus, [tail length] > 0 ? [NSString stringWithFormat:@": %@", tail] : @""];
    }
    return NO;
}

static BOOL RunProbeKeyResponseLevel(NSInteger level, NSInteger sleepTime, NSString **message) {
    if (level < 1 || level > 5) {
        if (message) {
            *message = [NSString stringWithFormat:@"Key response level %ld is outside the driver range 1..5", (long)level];
        }
        return NO;
    }
    if (sleepTime < 0 || sleepTime > 3) {
        if (message) {
            *message = [NSString stringWithFormat:@"Sleep time value %ld is outside the mapped driver range 0..3", (long)sleepTime];
        }
        return NO;
    }

    NSURL *probeURL = ProbeExecutableURL();
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:probeURL.path]) {
        if (message) {
            *message = [NSString stringWithFormat:@"Keyboard helper was not found at %@", probeURL.path];
        }
        return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = probeURL;
    task.currentDirectoryURL = [probeURL URLByDeletingLastPathComponent];
    task.arguments = @[
        @"--dongle",
        @"--key-response-level", [NSString stringWithFormat:@"%ld", (long)level],
        @"--key-response-fn-switch", @"1",
        @"--key-response-sleep-time", [NSString stringWithFormat:@"%ld", (long)sleepTime],
        @"--key-response-page", @"0xff60",
        @"--key-response-no-commit",
        @"--seconds", @"1"
    ];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        if (message) {
            *message = [NSString stringWithFormat:@"F75Probe could not start: %@", exception.reason ?: exception.name];
        }
        return NO;
    }

    NSData *outputData = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    if (task.terminationStatus == 0) {
        if (message) {
            *message = [NSString stringWithFormat:@"Performance set: %@", PerformanceSettingsSummary(level, sleepTime)];
        }
        return YES;
    }

    if (message) {
        NSString *tail = TailString([output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]], 360);
        *message = [NSString stringWithFormat:@"Performance mode failed (%d)%@", task.terminationStatus, [tail length] > 0 ? [NSString stringWithFormat:@": %@", tail] : @""];
    }
    return NO;
}

static BOOL RunProbeRestoreCommandKey(NSInteger level, NSInteger sleepTime, NSString **message) {
    NSString *probeMessage = nil;
    BOOL ok = RunProbeKeyResponseLevel(level, sleepTime, &probeMessage);
    if (message) {
        if (ok) {
            *message = [NSString stringWithFormat:@"Command key restore sent: Fn layer unlocked, %@", PerformanceSettingsSummary(level, sleepTime)];
        } else {
            *message = probeMessage ?: @"Command key restore failed";
        }
    }
    return ok;
}

static BOOL RunProbeActualGameMode(BOOL enabled, NSInteger level, NSInteger sleepTime, NSString **message) {
    if (level < 1 || level > 5) {
        if (message) {
            *message = [NSString stringWithFormat:@"Key response level %ld is outside the driver range 1..5", (long)level];
        }
        return NO;
    }
    if (sleepTime < 0 || sleepTime > 3) {
        if (message) {
            *message = [NSString stringWithFormat:@"Sleep time value %ld is outside the mapped driver range 0..3", (long)sleepTime];
        }
        return NO;
    }

    NSURL *probeURL = ProbeExecutableURL();
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:probeURL.path]) {
        if (message) {
            *message = [NSString stringWithFormat:@"Keyboard helper was not found at %@", probeURL.path];
        }
        return NO;
    }

    NSString *enabledValue = enabled ? @"1" : @"0";
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = probeURL;
    task.currentDirectoryURL = [probeURL URLByDeletingLastPathComponent];
    task.arguments = @[
        @"--dongle",
        @"--game-mode", enabledValue,
        @"--game-response-level", [NSString stringWithFormat:@"%ld", (long)level],
        @"--game-fn-switch", @"1",
        @"--game-sleep-time", [NSString stringWithFormat:@"%ld", (long)sleepTime],
        @"--game-disable-win", enabledValue,
        @"--game-disable-alttab", enabledValue,
        @"--game-disable-altf4", enabledValue,
        @"--game-page", @"0xff60",
        @"--seconds", @"1"
    ];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        if (message) {
            *message = [NSString stringWithFormat:@"F75Probe could not start: %@", exception.reason ?: exception.name];
        }
        return NO;
    }

    NSData *outputData = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    if (task.terminationStatus == 0) {
        if (message) {
            *message = [NSString stringWithFormat:@"Game Mode %@: %@",
                        enabled ? @"enabled" : @"disabled",
                        PerformanceSettingsSummary(level, sleepTime)];
        }
        return YES;
    }

    if (message) {
        NSString *tail = TailString([output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]], 360);
        *message = [NSString stringWithFormat:@"Actual Game Mode failed (%d)%@", task.terminationStatus, [tail length] > 0 ? [NSString stringWithFormat:@": %@", tail] : @""];
    }
    return NO;
}

static BOOL UploadScreenAnimationFromURL(NSURL *url, ScreenFitMode fitMode, uint8_t maxAnimatedFrames, ScreenUploadProgressHandler progressHandler, NSString **message) {
    size_t streamLength = 0;
    uint16_t chunkCount = 0;
    uint8_t frameCount = 0;
    BOOL animated = NO;
    size_t sourceFrameCount = 0;
    uint8_t *stream = CreateScreenStreamFromURL(
        url,
        1,
        255,
        maxAnimatedFrames,
        YES,
        fitMode,
        &streamLength,
        &chunkCount,
        &frameCount,
        &animated,
        &sourceFrameCount,
        message
    );
    if (!stream) {
        return NO;
    }

    NSString *label = animated ?
        [NSString stringWithFormat:@"GIF screen animation (%zu source frame%@, %@)", sourceFrameCount, sourceFrameCount == 1 ? @"" : @"s", ScreenFitModeTitle(fitMode)] :
        [NSString stringWithFormat:@"image screen animation (%@)", ScreenFitModeTitle(fitMode)];
    NSString *nativeMessage = nil;
    BOOL ok = UploadScreenStream(stream, chunkCount, frameCount, label, progressHandler, &nativeMessage);
    free(stream);
    (void)streamLength;
    if (!ok && [nativeMessage containsString:@"ack timed out"]) {
        NSString *fallbackMessage = nil;
        ok = RunProbeScreenUploadFallback(url, fitMode, maxAnimatedFrames, &fallbackMessage);
        if (message) {
            *message = ok ? fallbackMessage : [NSString stringWithFormat:@"%@; %@", nativeMessage, fallbackMessage ?: @"fallback did not return a message"];
        }
        return ok;
    }
    if (message) {
        *message = nativeMessage;
    }
    return ok;
}

static BOOL UploadScreenBootAnimationFromURL(NSURL *url, NSString **message) {
    return UploadScreenAnimationFromURL(url, ScreenFitContain, 255, nil, message);
}

static BOOL SyncScreenTime(NSString **message) {
    ScreenHIDContext context;
    if (!OpenScreenHID(&context, message)) {
        return NO;
    }

    NSDateComponents *components = [[NSCalendar currentCalendar] components:
        NSCalendarUnitYear |
        NSCalendarUnitMonth |
        NSCalendarUnitDay |
        NSCalendarUnitHour |
        NSCalendarUnitMinute |
        NSCalendarUnitSecond |
        NSCalendarUnitWeekday
        fromDate:[NSDate date]];

    const uint8_t beginCommand[] = {0x04, 0x18};
    const uint8_t selectCommand[] = {0x04, 0x28, 0, 0, 0, 0, 0, 0, 0x01};
    const uint8_t exitCommand[] = {0x04, 0x02};
    uint8_t timeCommand[64] = {0};
    timeCommand[0] = 0x00;
    timeCommand[1] = 0x01;
    timeCommand[2] = 0x5a;
    timeCommand[3] = (uint8_t)(components.year >= 2000 ? components.year - 2000 : components.year % 100);
    timeCommand[4] = (uint8_t)components.month;
    timeCommand[5] = (uint8_t)components.day;
    timeCommand[6] = (uint8_t)components.hour;
    timeCommand[7] = (uint8_t)components.minute;
    timeCommand[8] = (uint8_t)components.second;
    timeCommand[10] = (uint8_t)(components.weekday > 0 ? components.weekday - 1 : 0);
    timeCommand[62] = 0xaa;
    timeCommand[63] = 0x55;

    BOOL ok = SendScreenFeature(context.control, beginCommand, sizeof(beginCommand), message) &&
        SendScreenFeature(context.control, selectCommand, sizeof(selectCommand), message) &&
        SendScreenFeature(context.control, timeCommand, sizeof(timeCommand), message) &&
        SendScreenFeature(context.control, exitCommand, sizeof(exitCommand), message);

    CloseScreenHID(&context);
    if (ok && message) {
        *message = @"Screen time synced";
    }
    return ok;
}

static void PrintDump(void) {
    NSArray<HIDEndpoint *> *endpoints = ScanHIDEndpoints();
    BatteryReading *battery = BatteryFromEndpoints(endpoints);
    printf("Connection: %s\n", [ConnectionLabel(endpoints) UTF8String]);
    if (battery) {
        printf("Battery: %ld%% (%s, %s)\n", (long)battery.percent, [battery.source UTF8String], [battery.detail UTF8String]);
    } else {
        printf("Battery: unavailable\n");
    }
    printf("Endpoints: %ld\n", (long)[endpoints count]);
    for (HIDEndpoint *endpoint in endpoints) {
        printf(
            " - %s %s product=%s transport=%s location=0x%08lx id=%s\n",
            [EndpointTitle(endpoint) UTF8String],
            [IsDongleEndpoint(endpoint) ? @"2.4G" : @"USB" UTF8String],
            [endpoint.product UTF8String],
            [endpoint.transport UTF8String],
            (long)endpoint.locationID,
            [DeviceIDString(endpoint.vendorID, endpoint.productID) UTF8String]
        );
    }
}

@interface ScreenManagerWindowController : NSWindowController
@property(nonatomic, copy) void (^statusUpdateHandler)(NSString *status);
@property(nonatomic, strong) NSURL *selectedURL;
@property(nonatomic, strong) NSImageView *previewView;
@property(nonatomic, strong) NSTextField *fileLabel;
@property(nonatomic, strong) NSTextField *detailsLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSPopUpButton *fitPopup;
@property(nonatomic, strong) NSTextField *frameField;
@property(nonatomic, strong) NSStepper *frameStepper;
@property(nonatomic, strong) NSProgressIndicator *progressIndicator;
@property(nonatomic, strong) NSButton *uploadButton;
@end

@implementation ScreenManagerWindowController

static NSTextField *Label(NSString *text, NSRect frame) {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = text ?: @"";
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.font = [NSFont systemFontOfSize:13.0];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

static NSTextField *StyledLabel(NSString *text, NSRect frame, NSFont *font, NSColor *color) {
    NSTextField *label = Label(text, frame);
    label.font = font ?: [NSFont systemFontOfSize:13.0];
    label.textColor = color ?: [NSColor labelColor];
    return label;
}

static NSView *PanelView(NSRect frame) {
    NSView *view = [[NSView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [[NSColor controlBackgroundColor] CGColor];
    view.layer.cornerRadius = 14.0;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = [[NSColor separatorColor] CGColor];
    return view;
}

static NSString *ScreenImageDetails(NSURL *url) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) {
        return @"No image selected";
    }

    size_t frameCount = CGImageSourceGetCount(source);
    size_t width = 0;
    size_t height = 0;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSNumber *pixelWidth = properties[(NSString *)kCGImagePropertyPixelWidth];
    NSNumber *pixelHeight = properties[(NSString *)kCGImagePropertyPixelHeight];
    if ([pixelWidth respondsToSelector:@selector(unsignedIntegerValue)]) {
        width = [pixelWidth unsignedIntegerValue];
    }
    if ([pixelHeight respondsToSelector:@selector(unsignedIntegerValue)]) {
        height = [pixelHeight unsignedIntegerValue];
    }
    CFRelease(source);

    NSString *kind = frameCount > 1 ? @"GIF" : @"Image";
    return [NSString stringWithFormat:@"%@: %zux%zu, %zu frame%@", kind, width, height, frameCount, frameCount == 1 ? @"" : @"s"];
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 680, 430)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView)
        backing:NSBackingStoreBuffered
        defer:NO
    ];
    self = [super initWithWindow:window];
    if (!self) {
        return nil;
    }

    window.title = @"Aula F75 Screen Manager";
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.movableByWindowBackground = YES;
    window.releasedWhenClosed = NO;

    NSView *content = window.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = [[NSColor windowBackgroundColor] CGColor];

    NSImageView *appIconView = [[NSImageView alloc] initWithFrame:NSMakeRect(24, 360, 38, 38)];
    appIconView.image = [NSImage imageNamed:@"AulaF75Bar"] ?: StatusKeyboardIcon();
    appIconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [content addSubview:appIconView];

    [content addSubview:StyledLabel(@"Aula F75 Max", NSMakeRect(72, 374, 260, 24), [NSFont boldSystemFontOfSize:20.0], [NSColor labelColor])];
    [content addSubview:StyledLabel(@"Screen uploads, RGB lighting, and live keyboard status.", NSMakeRect(72, 352, 420, 20), [NSFont systemFontOfSize:13.0], [NSColor secondaryLabelColor])];

    [content addSubview:PanelView(NSMakeRect(24, 32, 276, 304))];
    [content addSubview:PanelView(NSMakeRect(324, 32, 332, 304))];

    [content addSubview:StyledLabel(@"Screen Preview", NSMakeRect(48, 304, 180, 20), [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold], [NSColor labelColor])];
    [content addSubview:StyledLabel(@"128 x 128 upload target", NSMakeRect(48, 282, 200, 18), [NSFont systemFontOfSize:12.0], [NSColor secondaryLabelColor])];

    self.previewView = [[NSImageView alloc] initWithFrame:NSMakeRect(62, 90, 200, 200)];
    self.previewView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.previewView.wantsLayer = YES;
    self.previewView.layer.backgroundColor = [[NSColor blackColor] CGColor];
    self.previewView.layer.borderColor = [[NSColor separatorColor] CGColor];
    self.previewView.layer.borderWidth = 1.0;
    self.previewView.layer.cornerRadius = 12.0;
    self.previewView.layer.masksToBounds = YES;
    [content addSubview:self.previewView];

    [content addSubview:StyledLabel(@"Tip: switch the keyboard to wired USB before uploading.", NSMakeRect(48, 58, 228, 18), [NSFont systemFontOfSize:12.0], [NSColor secondaryLabelColor])];

    [content addSubview:StyledLabel(@"Upload", NSMakeRect(348, 304, 180, 20), [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold], [NSColor labelColor])];
    [content addSubview:StyledLabel(@"Use a GIF for animation or a still image for a static screen.", NSMakeRect(348, 282, 272, 18), [NSFont systemFontOfSize:12.0], [NSColor secondaryLabelColor])];

    NSButton *chooseButton = [[NSButton alloc] initWithFrame:NSMakeRect(348, 242, 172, 32)];
    chooseButton.title = @"Choose Image/GIF";
    chooseButton.image = SymbolImage(@"photo.on.rectangle", 16.0);
    chooseButton.imagePosition = NSImageLeft;
    chooseButton.bezelStyle = NSBezelStyleRounded;
    chooseButton.target = self;
    chooseButton.action = @selector(chooseFile:);
    [content addSubview:chooseButton];

    self.fileLabel = StyledLabel(@"No file selected", NSMakeRect(348, 212, 276, 20), [NSFont systemFontOfSize:13.0], [NSColor labelColor]);
    [content addSubview:self.fileLabel];

    self.detailsLabel = Label(@"GIF uploads loop-fill up to 255 frames.", NSMakeRect(348, 190, 276, 20));
    [content addSubview:self.detailsLabel];

    [content addSubview:StyledLabel(@"Fit", NSMakeRect(348, 154, 72, 22), [NSFont systemFontOfSize:13.0], [NSColor labelColor])];
    self.fitPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(430, 150, 126, 28) pullsDown:NO];
    [self.fitPopup addItemsWithTitles:@[@"Fit", @"Fill", @"Stretch"]];
    [content addSubview:self.fitPopup];

    [content addSubview:StyledLabel(@"GIF frames", NSMakeRect(348, 116, 80, 22), [NSFont systemFontOfSize:13.0], [NSColor labelColor])];
    self.frameField = StyledLabel(@"255", NSMakeRect(430, 116, 44, 22), [NSFont monospacedDigitSystemFontOfSize:13.0 weight:NSFontWeightRegular], [NSColor labelColor]);
    self.frameField.alignment = NSTextAlignmentRight;
    [content addSubview:self.frameField];

    self.frameStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(482, 112, 22, 28)];
    self.frameStepper.minValue = 1;
    self.frameStepper.maxValue = 255;
    self.frameStepper.integerValue = 255;
    self.frameStepper.target = self;
    self.frameStepper.action = @selector(frameStepperChanged:);
    [content addSubview:self.frameStepper];

    self.uploadButton = [[NSButton alloc] initWithFrame:NSMakeRect(348, 72, 132, 32)];
    self.uploadButton.title = @"Upload";
    self.uploadButton.image = SymbolImage(@"arrow.up.square", 16.0);
    self.uploadButton.imagePosition = NSImageLeft;
    self.uploadButton.bezelStyle = NSBezelStyleRounded;
    self.uploadButton.enabled = NO;
    self.uploadButton.target = self;
    self.uploadButton.action = @selector(upload:);
    [content addSubview:self.uploadButton];

    self.progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(348, 48, 276, 12)];
    self.progressIndicator.indeterminate = NO;
    self.progressIndicator.minValue = 0.0;
    self.progressIndicator.maxValue = 100.0;
    self.progressIndicator.doubleValue = 0.0;
    [content addSubview:self.progressIndicator];

    self.statusLabel = Label(@"Switch to wired USB mode before uploading.", NSMakeRect(348, 24, 276, 18));
    [content addSubview:self.statusLabel];

    return self;
}

- (void)chooseFile:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = NO;
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray arrayWithArray:@[
        UTTypePNG,
        UTTypeJPEG,
        UTTypeGIF,
        UTTypeBMP,
        UTTypeTIFF
    ]];
    UTType *webpType = [UTType typeWithFilenameExtension:@"webp"];
    if (webpType) {
        [contentTypes addObject:webpType];
    }
    panel.allowedContentTypes = contentTypes;

    if ([panel runModal] != NSModalResponseOK) {
        return;
    }

    self.selectedURL = panel.URL;
    self.previewView.image = [[NSImage alloc] initWithContentsOfURL:self.selectedURL];
    self.fileLabel.stringValue = self.selectedURL.lastPathComponent ?: @"Selected image";
    self.detailsLabel.stringValue = ScreenImageDetails(self.selectedURL);
    self.progressIndicator.doubleValue = 0.0;
    self.statusLabel.stringValue = @"Ready to upload.";
    self.uploadButton.enabled = YES;
}

- (void)frameStepperChanged:(id)sender {
    (void)sender;
    self.frameField.stringValue = [NSString stringWithFormat:@"%ld", (long)self.frameStepper.integerValue];
}

- (ScreenFitMode)selectedFitMode {
    NSInteger index = self.fitPopup.indexOfSelectedItem;
    if (index == 1) {
        return ScreenFitCover;
    }
    if (index == 2) {
        return ScreenFitStretch;
    }
    return ScreenFitContain;
}

- (void)setUploading:(BOOL)uploading {
    self.uploadButton.enabled = !uploading && self.selectedURL != nil;
    self.fitPopup.enabled = !uploading;
    self.frameStepper.enabled = !uploading;
}

- (void)upload:(id)sender {
    (void)sender;
    if (!self.selectedURL) {
        [self chooseFile:nil];
        if (!self.selectedURL) {
            return;
        }
    }

    NSURL *url = self.selectedURL;
    ScreenFitMode fitMode = [self selectedFitMode];
    uint8_t maxFrames = (uint8_t)MAX(1, MIN(255, self.frameStepper.integerValue));
    self.progressIndicator.doubleValue = 0.0;
    self.statusLabel.stringValue = @"Building 128 x 128 stream...";
    [self setUploading:YES];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *message = nil;
            BOOL ok = UploadScreenAnimationFromURL(
                url,
                fitMode,
                maxFrames,
                ^(uint16_t sentChunks, uint16_t totalChunks) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        double progress = totalChunks == 0 ? 0.0 : ((double)sentChunks / (double)totalChunks) * 100.0;
                        self.progressIndicator.doubleValue = progress;
                        self.statusLabel.stringValue = [NSString stringWithFormat:@"Uploading chunk %u/%u", sentChunks, totalChunks];
                    });
                },
                &message
            );

            dispatch_async(dispatch_get_main_queue(), ^{
                self.progressIndicator.doubleValue = ok ? 100.0 : self.progressIndicator.doubleValue;
                self.statusLabel.stringValue = message ?: (ok ? @"Upload complete" : @"Upload failed");
                [self setUploading:NO];
                if (self.statusUpdateHandler) {
                    self.statusUpdateHandler(self.statusLabel.stringValue);
                }
            });
        }
    });
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *lastAppStatus;
@property(nonatomic, copy) NSString *lastScreenStatus;
@property(nonatomic, copy) NSString *lastRGBStatus;
@property(nonatomic, copy) NSString *lastKeyResponseStatus;
@property(nonatomic, strong) ScreenManagerWindowController *screenManager;
@property(nonatomic, strong) NSMutableArray<NSString *> *batteryHistory;
@property(nonatomic) NSInteger lastBatteryPercent;
@property(nonatomic) BOOL lowBatteryNotified;
@property(nonatomic) NSInteger rgbMode;
@property(nonatomic) NSInteger rgbBrightness;
@property(nonatomic) NSInteger rgbSpeed;
@property(nonatomic) NSInteger rgbDirection;
@property(nonatomic) NSInteger rgbColor;
@property(nonatomic) BOOL rgbColorful;
@property(nonatomic) NSInteger keyResponseLevel;
@property(nonatomic) NSInteger sleepTime;
@property(nonatomic) BOOL gameModeEnabled;
@property(nonatomic) BOOL gameModeStateKnown;
@end

@implementation AppDelegate

- (void)loadRGBSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.rgbMode = [defaults objectForKey:kRGBModeDefaultsKey] ? [defaults integerForKey:kRGBModeDefaultsKey] : 11;
    self.rgbBrightness = [defaults objectForKey:kRGBBrightnessDefaultsKey] ? [defaults integerForKey:kRGBBrightnessDefaultsKey] : 5;
    self.rgbSpeed = [defaults objectForKey:kRGBSpeedDefaultsKey] ? [defaults integerForKey:kRGBSpeedDefaultsKey] : 3;
    self.rgbDirection = [defaults objectForKey:kRGBDirectionDefaultsKey] ? [defaults integerForKey:kRGBDirectionDefaultsKey] : 0;
    self.rgbColor = [defaults objectForKey:kRGBColorDefaultsKey] ? [defaults integerForKey:kRGBColorDefaultsKey] : 0x0000ff;
    self.rgbColorful = [defaults objectForKey:kRGBColorfulDefaultsKey] ? [defaults boolForKey:kRGBColorfulDefaultsKey] : YES;

    self.rgbMode = ClampInteger(self.rgbMode, 0, 31);
    self.rgbBrightness = ClampInteger(self.rgbBrightness, 1, 5);
    self.rgbSpeed = ClampInteger(self.rgbSpeed, 1, 5);
    self.rgbDirection = ClampInteger(self.rgbDirection, 0, 3);
    self.rgbColor = ClampInteger(self.rgbColor, 0, 0xffffff);
}

- (void)saveRGBSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:self.rgbMode forKey:kRGBModeDefaultsKey];
    [defaults setInteger:self.rgbBrightness forKey:kRGBBrightnessDefaultsKey];
    [defaults setInteger:self.rgbSpeed forKey:kRGBSpeedDefaultsKey];
    [defaults setInteger:self.rgbDirection forKey:kRGBDirectionDefaultsKey];
    [defaults setInteger:self.rgbColor forKey:kRGBColorDefaultsKey];
    [defaults setBool:self.rgbColorful forKey:kRGBColorfulDefaultsKey];
}

- (void)loadKeyResponseSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.keyResponseLevel = [defaults objectForKey:kKeyResponseLevelDefaultsKey] ? [defaults integerForKey:kKeyResponseLevelDefaultsKey] : 1;
    self.sleepTime = [defaults objectForKey:kSleepTimeDefaultsKey] ? [defaults integerForKey:kSleepTimeDefaultsKey] : 1;
    self.gameModeStateKnown = [defaults objectForKey:kGameModeEnabledDefaultsKey] != nil;
    self.gameModeEnabled = self.gameModeStateKnown ? [defaults boolForKey:kGameModeEnabledDefaultsKey] : NO;
    self.keyResponseLevel = ClampInteger(self.keyResponseLevel, 1, 5);
    self.sleepTime = ClampInteger(self.sleepTime, 0, 3);
}

- (void)saveKeyResponseSettings {
    [NSUserDefaults.standardUserDefaults setInteger:self.keyResponseLevel forKey:kKeyResponseLevelDefaultsKey];
    [NSUserDefaults.standardUserDefaults setInteger:self.sleepTime forKey:kSleepTimeDefaultsKey];
}

- (void)saveGameModeSettings {
    self.gameModeStateKnown = YES;
    [NSUserDefaults.standardUserDefaults setBool:self.gameModeEnabled forKey:kGameModeEnabledDefaultsKey];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.batteryHistory = [NSMutableArray array];
    self.lastBatteryPercent = -1;
    [self loadRGBSettings];
    [self loadKeyResponseSettings];
    NSImage *appIcon = [NSImage imageNamed:@"AulaF75Bar"];
    if (appIcon) {
        NSApp.applicationIconImage = appIcon;
    }
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = StatusKeyboardIcon();
    self.statusItem.button.imagePosition = NSImageLeft;
    self.statusItem.button.toolTip = @"Aula F75 Max";
    [self refresh:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
}

- (void)recordBatteryReading:(BatteryReading *)battery connection:(NSString *)connection {
    if (!self.batteryHistory) {
        self.batteryHistory = [NSMutableArray array];
    }
    if (!battery) {
        return;
    }

    if (battery.percent == self.lastBatteryPercent && [self.batteryHistory count] > 0) {
        return;
    }

    self.lastBatteryPercent = battery.percent;
    NSString *entry = [NSString stringWithFormat:@"%@  %ld%%  %@", ShortTimeString([NSDate date]), (long)battery.percent, connection ?: @"connected"];
    [self.batteryHistory insertObject:entry atIndex:0];
    while ([self.batteryHistory count] > 8) {
        [self.batteryHistory removeLastObject];
    }

    if (battery.percent > 25) {
        self.lowBatteryNotified = NO;
    } else if (!self.lowBatteryNotified) {
        self.lowBatteryNotified = YES;
        self.lastScreenStatus = [NSString stringWithFormat:@"Battery low: %ld%%", (long)battery.percent];
    }
}

- (void)refresh:(id)sender {
    (void)sender;

    NSArray<HIDEndpoint *> *endpoints = ScanHIDEndpoints();
    BatteryReading *battery = BatteryFromEndpoints(endpoints);
    NSString *connection = ConnectionLabel(endpoints);
    BOOL connected = [endpoints count] > 0;
    [self recordBatteryReading:battery connection:connection];

    if (!connected) {
        self.statusItem.button.title = @"off";
        self.statusItem.button.toolTip = @"Aula F75 Max: not connected";
    } else if (battery) {
        self.statusItem.button.title = [NSString stringWithFormat:@"%ld%%", (long)battery.percent];
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"Aula F75 Max: %ld%% via %@", (long)battery.percent, connection];
    } else if (gRawHIDPermissionDenied) {
        self.statusItem.button.title = @"auth";
        self.statusItem.button.toolTip = @"Aula F75 Max: Input Monitoring permission needed";
    } else {
        self.statusItem.button.title = @"?";
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"Aula F75 Max: battery unavailable via %@", connection];
    }

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Aula F75 Max"];
    [menu addItem:DisabledMenuItemWithSymbol(@"Aula F75 Max", @"keyboard")];
    [menu addItem:DisabledMenuItemWithSymbol([NSString stringWithFormat:@"Connection: %@", connection], @"antenna.radiowaves.left.and.right")];
    if (battery) {
        NSString *batterySymbol = battery.percent <= 25 ? @"battery.25" : (battery.percent <= 50 ? @"battery.50" : @"battery.100");
        [menu addItem:DisabledMenuItemWithSymbol([NSString stringWithFormat:@"Battery: %ld%%", (long)battery.percent], batterySymbol)];
        [menu addItem:DisabledMenuItem([NSString stringWithFormat:@"Source: %@ (%@)", battery.source, battery.detail])];
    } else if (connected) {
        [menu addItem:DisabledMenuItemWithSymbol(@"Battery: unavailable", @"battery.0")];
        if (gRawHIDPermissionDenied) {
            [menu addItem:DisabledMenuItem(@"Source: Input Monitoring permission needed")];
        } else {
            [menu addItem:DisabledMenuItem(@"Source: not exposed by macOS yet")];
        }
    } else {
        [menu addItem:DisabledMenuItemWithSymbol(@"Battery: unavailable", @"battery.0")];
    }
    if ([self.batteryHistory count] > 0) {
        NSMenuItem *historyItem = [[NSMenuItem alloc] initWithTitle:@"Battery History" action:nil keyEquivalent:@""];
        NSMenu *historyMenu = [[NSMenu alloc] initWithTitle:@"Battery History"];
        for (NSString *entry in self.batteryHistory) {
            [historyMenu addItem:DisabledMenuItem(entry)];
        }
        historyItem.submenu = historyMenu;
        [menu addItem:historyItem];
    }
    [menu addItem:DisabledMenuItem([NSString stringWithFormat:@"Updated: %@", ShortTimeString([NSDate date])])];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *screenItem = [[NSMenuItem alloc] initWithTitle:@"Screen" action:nil keyEquivalent:@""];
    SetMenuItemSymbol(screenItem, @"photo.on.rectangle");
    NSMenu *screenMenu = [[NSMenu alloc] initWithTitle:@"Screen"];
    BOOL screenReady = HasWiredScreenEndpoints(endpoints);
    [screenMenu addItem:DisabledMenuItem(screenReady ? @"USB screen endpoint ready" : @"USB wired mode required")];
    if ([self.lastScreenStatus length] > 0) {
        [screenMenu addItem:DisabledMenuItem([NSString stringWithFormat:@"Last: %@", self.lastScreenStatus])];
    }

    NSMenuItem *syncItem = [[NSMenuItem alloc] initWithTitle:@"Sync Screen Time" action:@selector(syncScreenTime:) keyEquivalent:@""];
    SetMenuItemSymbol(syncItem, @"clock.arrow.circlepath");
    syncItem.target = self;
    syncItem.enabled = screenReady;
    [screenMenu addItem:syncItem];

    NSMenuItem *managerItem = [[NSMenuItem alloc] initWithTitle:@"Open Screen Manager..." action:@selector(openScreenManager:) keyEquivalent:@""];
    SetMenuItemSymbol(managerItem, @"rectangle.and.pencil.and.ellipsis");
    managerItem.target = self;
    [screenMenu addItem:managerItem];

    screenItem.submenu = screenMenu;
    [menu addItem:screenItem];

    NSMenuItem *rgbItem = [[NSMenuItem alloc] initWithTitle:@"RGB Lighting" action:nil keyEquivalent:@""];
    SetMenuItemSymbol(rgbItem, @"lightbulb.led");
    NSMenu *rgbMenu = [[NSMenu alloc] initWithTitle:@"RGB Lighting"];
    BOOL rgbReady = HasDongleRawEndpoint(endpoints);
    [rgbMenu addItem:DisabledMenuItem(rgbReady ? @"2.4G RGB endpoint ready" : @"2.4G dongle required")];
    [rgbMenu addItem:DisabledMenuItem([NSString stringWithFormat:@"Current: %@", RGBSettingsSummary(self.rgbMode, self.rgbBrightness, self.rgbSpeed, self.rgbDirection, self.rgbColor, self.rgbColorful)])];
    if ([self.lastRGBStatus length] > 0) {
        [rgbMenu addItem:DisabledMenuItem([NSString stringWithFormat:@"Last: %@", self.lastRGBStatus])];
    }

    NSMenuItem *modeRootItem = [[NSMenuItem alloc] initWithTitle:@"Mode" action:nil keyEquivalent:@""];
    SetMenuItemSymbol(modeRootItem, @"circle.grid.cross");
    NSMenu *modeMenu = [[NSMenu alloc] initWithTitle:@"Mode"];
    NSArray<NSDictionary<NSString *, id> *> *primaryRGBModes = @[
        @{@"title": @"Default Rolling", @"mode": @11},
        @{@"title": @"LED Off", @"mode": @0}
    ];
    for (NSDictionary<NSString *, id> *modeInfo in primaryRGBModes) {
        NSString *title = modeInfo[@"title"];
        NSInteger mode = [modeInfo[@"mode"] integerValue];
        NSMenuItem *modeItem = [[NSMenuItem alloc] initWithTitle:title action:@selector(setRGBMode:) keyEquivalent:@""];
        modeItem.target = self;
        modeItem.tag = mode;
        modeItem.representedObject = title;
        modeItem.enabled = rgbReady;
        modeItem.state = self.rgbMode == mode ? NSControlStateValueOn : NSControlStateValueOff;
        [modeMenu addItem:modeItem];
    }

    [modeMenu addItem:[NSMenuItem separatorItem]];
    for (NSDictionary<NSString *, id> *modeInfo in RGBModeDefinitions()) {
        NSString *title = modeInfo[@"title"];
        NSInteger mode = [modeInfo[@"mode"] integerValue];
        if (mode == 11) {
            continue;
        }
        NSMenuItem *modeItem = [[NSMenuItem alloc] initWithTitle:title action:@selector(setRGBMode:) keyEquivalent:@""];
        modeItem.target = self;
        modeItem.tag = mode;
        modeItem.representedObject = title;
        modeItem.enabled = rgbReady;
        modeItem.state = self.rgbMode == mode ? NSControlStateValueOn : NSControlStateValueOff;
        [modeMenu addItem:modeItem];
    }
    modeRootItem.submenu = modeMenu;
    [rgbMenu addItem:modeRootItem];

    [rgbMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *brightnessItem = [[NSMenuItem alloc] initWithTitle:@"Brightness" action:nil keyEquivalent:@""];
    SetMenuItemSymbol(brightnessItem, @"sun.max");
    NSMenu *brightnessMenu = [[NSMenu alloc] initWithTitle:@"Brightness"];
    for (NSInteger level = 1; level <= 5; level++) {
        NSMenuItem *levelItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Level %ld", (long)level] action:@selector(setRGBBrightness:) keyEquivalent:@""];
        levelItem.target = self;
        levelItem.tag = level;
        levelItem.enabled = rgbReady;
        levelItem.state = self.rgbBrightness == level ? NSControlStateValueOn : NSControlStateValueOff;
        [brightnessMenu addItem:levelItem];
    }
    brightnessItem.submenu = brightnessMenu;
    [rgbMenu addItem:brightnessItem];

    NSMenuItem *speedItem = [[NSMenuItem alloc] initWithTitle:@"Speed" action:nil keyEquivalent:@""];
    SetMenuItemSymbol(speedItem, @"speedometer");
    NSMenu *speedMenu = [[NSMenu alloc] initWithTitle:@"Speed"];
    for (NSInteger level = 1; level <= 5; level++) {
        NSMenuItem *levelItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Level %ld", (long)level] action:@selector(setRGBSpeed:) keyEquivalent:@""];
        levelItem.target = self;
        levelItem.tag = level;
        levelItem.enabled = rgbReady;
        levelItem.state = self.rgbSpeed == level ? NSControlStateValueOn : NSControlStateValueOff;
        [speedMenu addItem:levelItem];
    }
    speedItem.submenu = speedMenu;
    [rgbMenu addItem:speedItem];

    NSMenuItem *directionItem = [[NSMenuItem alloc] initWithTitle:@"Direction" action:nil keyEquivalent:@""];
    SetMenuItemSymbol(directionItem, @"arrow.right");
    NSMenu *directionMenu = [[NSMenu alloc] initWithTitle:@"Direction"];
    for (NSInteger direction = 0; direction <= 3; direction++) {
        NSMenuItem *directionValueItem = [[NSMenuItem alloc] initWithTitle:RGBDirectionTitle(direction) action:@selector(setRGBDirection:) keyEquivalent:@""];
        directionValueItem.target = self;
        directionValueItem.tag = direction;
        directionValueItem.enabled = rgbReady;
        directionValueItem.state = self.rgbDirection == direction ? NSControlStateValueOn : NSControlStateValueOff;
        [directionMenu addItem:directionValueItem];
    }
    directionItem.submenu = directionMenu;
    [rgbMenu addItem:directionItem];

    NSMenuItem *colorfulItem = [[NSMenuItem alloc] initWithTitle:@"Colorful Animation" action:@selector(toggleRGBColorful:) keyEquivalent:@""];
    SetMenuItemSymbol(colorfulItem, @"sparkles");
    colorfulItem.target = self;
    colorfulItem.enabled = rgbReady;
    colorfulItem.state = self.rgbColorful ? NSControlStateValueOn : NSControlStateValueOff;
    [rgbMenu addItem:colorfulItem];

    NSMenuItem *colorItem = [[NSMenuItem alloc] initWithTitle:@"Fixed Color" action:nil keyEquivalent:@""];
    SetMenuItemSymbol(colorItem, @"paintpalette");
    NSMenu *colorMenu = [[NSMenu alloc] initWithTitle:@"Fixed Color"];
    [colorMenu addItem:DisabledMenuItem([NSString stringWithFormat:@"Selected: %@", RGBColorDisplayString(self.rgbColor)])];
    NSMenuItem *chooseColorItem = [[NSMenuItem alloc] initWithTitle:@"Choose Custom Color..." action:@selector(chooseRGBColor:) keyEquivalent:@""];
    SetMenuItemSymbol(chooseColorItem, @"eyedropper");
    chooseColorItem.target = self;
    chooseColorItem.enabled = rgbReady;
    [colorMenu addItem:chooseColorItem];
    [colorMenu addItem:[NSMenuItem separatorItem]];

    NSArray<NSDictionary<NSString *, id> *> *colorPresets = @[
        @{@"title": @"Blue", @"color": @0x0000ff},
        @{@"title": @"Red", @"color": @0xff0000},
        @{@"title": @"Green", @"color": @0x00ff00},
        @{@"title": @"White", @"color": @0xffffff},
        @{@"title": @"Purple", @"color": @0x9b5cff},
        @{@"title": @"Amber", @"color": @0xff9f00},
        @{@"title": @"Cyan", @"color": @0x00d5ff},
        @{@"title": @"Pink", @"color": @0xff4fb8}
    ];
    for (NSDictionary<NSString *, id> *preset in colorPresets) {
        NSInteger color = [preset[@"color"] integerValue];
        NSString *title = [NSString stringWithFormat:@"%@ %@", preset[@"title"], RGBColorDisplayString(color)];
        NSMenuItem *colorPresetItem = [[NSMenuItem alloc] initWithTitle:title action:@selector(setRGBColor:) keyEquivalent:@""];
        colorPresetItem.target = self;
        colorPresetItem.tag = color;
        colorPresetItem.representedObject = preset[@"color"];
        colorPresetItem.enabled = rgbReady;
        colorPresetItem.state = self.rgbColor == color ? NSControlStateValueOn : NSControlStateValueOff;
        [colorMenu addItem:colorPresetItem];
    }
    colorItem.submenu = colorMenu;
    [rgbMenu addItem:colorItem];

    rgbItem.submenu = rgbMenu;
    [menu addItem:rgbItem];

    NSMenuItem *performanceItem = [[NSMenuItem alloc] initWithTitle:@"Performance" action:nil keyEquivalent:@""];
    SetMenuItemSymbol(performanceItem, @"bolt");
    NSMenu *performanceMenu = [[NSMenu alloc] initWithTitle:@"Performance"];
    BOOL performanceReady = HasDongleRawEndpoint(endpoints);
    [performanceMenu addItem:DisabledMenuItem(performanceReady ? @"2.4G response endpoint ready" : @"2.4G dongle required")];
    [performanceMenu addItem:DisabledMenuItem([NSString stringWithFormat:@"Selected: %@", PerformanceSettingsSummary(self.keyResponseLevel, self.sleepTime)])];
    if ([self.lastKeyResponseStatus length] > 0) {
        [performanceMenu addItem:DisabledMenuItem([NSString stringWithFormat:@"Last: %@", self.lastKeyResponseStatus])];
    }
    [performanceMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *responseItem = [[NSMenuItem alloc] initWithTitle:@"Key Response" action:nil keyEquivalent:@""];
    SetMenuItemSymbol(responseItem, @"bolt.horizontal");
    NSMenu *responseMenu = [[NSMenu alloc] initWithTitle:@"Key Response"];
    for (NSInteger level = 1; level <= 5; level++) {
        NSMenuItem *levelItem = [[NSMenuItem alloc] initWithTitle:KeyResponseLevelTitle(level) action:@selector(selectKeyResponseLevel:) keyEquivalent:@""];
        levelItem.target = self;
        levelItem.tag = level;
        levelItem.enabled = performanceReady;
        levelItem.state = self.keyResponseLevel == level ? NSControlStateValueOn : NSControlStateValueOff;
        [responseMenu addItem:levelItem];
    }
    responseItem.submenu = responseMenu;
    [performanceMenu addItem:responseItem];

    NSMenuItem *sleepItem = [[NSMenuItem alloc] initWithTitle:@"Sleep Timeout" action:nil keyEquivalent:@""];
    SetMenuItemSymbol(sleepItem, @"moon");
    NSMenu *sleepMenu = [[NSMenu alloc] initWithTitle:@"Sleep Timeout"];
    NSArray<NSNumber *> *sleepValues = @[@0, @1, @2, @3];
    for (NSNumber *sleepNumber in sleepValues) {
        NSInteger sleepTime = [sleepNumber integerValue];
        NSMenuItem *sleepValueItem = [[NSMenuItem alloc] initWithTitle:SleepTimeTitle(sleepTime) action:@selector(selectSleepTime:) keyEquivalent:@""];
        sleepValueItem.target = self;
        sleepValueItem.tag = sleepTime;
        sleepValueItem.enabled = performanceReady;
        sleepValueItem.state = self.sleepTime == sleepTime ? NSControlStateValueOn : NSControlStateValueOff;
        [sleepMenu addItem:sleepValueItem];
    }
    sleepItem.submenu = sleepMenu;
    [performanceMenu addItem:sleepItem];

    NSMenuItem *gameModeItem = [[NSMenuItem alloc] initWithTitle:@"Game Mode" action:nil keyEquivalent:@""];
    SetMenuItemSymbol(gameModeItem, @"gamecontroller");
    NSMenu *gameModeMenu = [[NSMenu alloc] initWithTitle:@"Game Mode"];
    NSString *gameModeStatus = self.gameModeStateKnown ? (self.gameModeEnabled ? @"On" : @"Off") : @"Unknown";
    [gameModeMenu addItem:DisabledMenuItem([NSString stringWithFormat:@"Last selected: %@", gameModeStatus])];

    NSMenuItem *enableGameModeItem = [[NSMenuItem alloc] initWithTitle:@"Enable Game Mode" action:@selector(enableActualGameMode:) keyEquivalent:@""];
    SetMenuItemSymbol(enableGameModeItem, @"play.fill");
    enableGameModeItem.target = self;
    enableGameModeItem.enabled = performanceReady;
    enableGameModeItem.state = self.gameModeStateKnown && self.gameModeEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [gameModeMenu addItem:enableGameModeItem];

    NSMenuItem *disableGameModeItem = [[NSMenuItem alloc] initWithTitle:@"Disable Game Mode" action:@selector(disableActualGameMode:) keyEquivalent:@""];
    SetMenuItemSymbol(disableGameModeItem, @"stop.fill");
    disableGameModeItem.target = self;
    disableGameModeItem.enabled = performanceReady;
    disableGameModeItem.state = self.gameModeStateKnown && !self.gameModeEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [gameModeMenu addItem:disableGameModeItem];
    gameModeItem.submenu = gameModeMenu;
    [performanceMenu addItem:gameModeItem];

    NSMenuItem *restoreCommandItem = [[NSMenuItem alloc] initWithTitle:@"Restore Command Key / Clear Lock" action:@selector(restoreCommandKey:) keyEquivalent:@""];
    SetMenuItemSymbol(restoreCommandItem, @"command");
    restoreCommandItem.target = self;
    restoreCommandItem.enabled = performanceReady;
    [performanceMenu addItem:restoreCommandItem];
    performanceItem.submenu = performanceMenu;
    [menu addItem:performanceItem];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *launchAtLoginItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login" action:@selector(toggleLaunchAtLogin:) keyEquivalent:@""];
    SetMenuItemSymbol(launchAtLoginItem, @"power");
    launchAtLoginItem.target = self;
    launchAtLoginItem.state = LaunchAtLoginEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:launchAtLoginItem];
    if ([self.lastAppStatus length] > 0) {
        [menu addItem:DisabledMenuItem([NSString stringWithFormat:@"App: %@", self.lastAppStatus])];
    }
    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"Refresh" action:@selector(refresh:) keyEquivalent:@"r"];
    SetMenuItemSymbol(refreshItem, @"arrow.clockwise");
    [menu addItem:refreshItem];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    SetMenuItemSymbol(quitItem, @"xmark.circle");
    [menu addItem:quitItem];
    self.statusItem.menu = menu;
}

- (void)showAppResult:(NSString *)message success:(BOOL)success {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = success ? @"Aula F75 Bar" : @"Aula F75 Bar error";
    alert.informativeText = message ?: (success ? @"Done" : @"Unknown error");
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)toggleLaunchAtLogin:(id)sender {
    (void)sender;
    NSString *message = nil;
    BOOL enable = !LaunchAtLoginEnabled();
    BOOL ok = SetLaunchAtLoginEnabled(enable, &message);
    self.lastAppStatus = message ?: (ok ? @"Launch at Login updated" : @"Launch at Login failed");
    [self refresh:nil];
    if (!ok) {
        [self showAppResult:self.lastAppStatus success:NO];
    }
}

- (void)showScreenResult:(NSString *)message success:(BOOL)success {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = success ? @"Aula F75 screen upload" : @"Aula F75 screen error";
    alert.informativeText = message ?: (success ? @"Done" : @"Unknown error");
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)showRGBResult:(NSString *)message success:(BOOL)success {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = success ? @"Aula F75 RGB" : @"Aula F75 RGB error";
    alert.informativeText = message ?: (success ? @"Done" : @"Unknown error");
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)showKeyResponseResult:(NSString *)message success:(BOOL)success {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = success ? @"Aula F75 performance" : @"Aula F75 performance error";
    alert.informativeText = message ?: (success ? @"Done" : @"Unknown error");
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)applyCurrentRGBSettingsWithTitle:(NSString *)title {
    NSString *summary = RGBSettingsSummary(self.rgbMode, self.rgbBrightness, self.rgbSpeed, self.rgbDirection, self.rgbColor, self.rgbColorful);
    self.lastRGBStatus = [NSString stringWithFormat:@"Sending %@", title ?: summary];
    [self refresh:nil];

    NSInteger mode = self.rgbMode;
    NSInteger brightness = self.rgbBrightness;
    NSInteger speed = self.rgbSpeed;
    NSInteger direction = self.rgbDirection;
    NSInteger color = self.rgbColor;
    BOOL colorful = self.rgbColorful;
    NSString *modeTitle = title ?: RGBModeTitleForMode(mode);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *message = nil;
            BOOL ok = RunProbeRGBMode(mode, brightness, speed, direction, color, colorful, modeTitle, &message);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.lastRGBStatus = message ?: (ok ? @"RGB settings applied" : @"RGB settings failed");
                [self refresh:nil];
                if (!ok) {
                    [self showRGBResult:self.lastRGBStatus success:NO];
                }
            });
        }
    });
}

- (void)applyCurrentKeyResponseLevelWithTitle:(NSString *)title {
    NSInteger level = self.keyResponseLevel;
    NSInteger sleepTime = self.sleepTime;
    self.lastKeyResponseStatus = [NSString stringWithFormat:@"Sending %@", title ?: PerformanceSettingsSummary(level, sleepTime)];
    [self refresh:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *message = nil;
            BOOL ok = RunProbeKeyResponseLevel(level, sleepTime, &message);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.lastKeyResponseStatus = message ?: (ok ? @"Performance setting applied" : @"Performance setting failed");
                [self refresh:nil];
                if (!ok) {
                    [self showKeyResponseResult:self.lastKeyResponseStatus success:NO];
                }
            });
        }
    });
}

- (void)restoreCommandKey:(id)sender {
    (void)sender;
    NSInteger level = self.keyResponseLevel;
    NSInteger sleepTime = self.sleepTime;
    self.lastKeyResponseStatus = @"Sending Command key restore";
    [self refresh:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *message = nil;
            BOOL ok = RunProbeRestoreCommandKey(level, sleepTime, &message);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.lastKeyResponseStatus = message ?: (ok ? @"Command key restore sent" : @"Command key restore failed");
                [self refresh:nil];
                if (!ok) {
                    [self showKeyResponseResult:self.lastKeyResponseStatus success:NO];
                }
            });
        }
    });
}

- (void)setActualGameModeEnabled:(BOOL)enabled {
    NSInteger level = self.keyResponseLevel;
    NSInteger sleepTime = self.sleepTime;
    self.lastKeyResponseStatus = [NSString stringWithFormat:@"Sending Game Mode %@", enabled ? @"On" : @"Off"];
    [self refresh:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *message = nil;
            BOOL ok = RunProbeActualGameMode(enabled, level, sleepTime, &message);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) {
                    self.gameModeEnabled = enabled;
                    [self saveGameModeSettings];
                }
                self.lastKeyResponseStatus = message ?: (ok ? @"Game Mode applied" : @"Game Mode failed");
                [self refresh:nil];
                if (!ok) {
                    [self showKeyResponseResult:self.lastKeyResponseStatus success:NO];
                }
            });
        }
    });
}

- (void)enableActualGameMode:(id)sender {
    (void)sender;
    [self setActualGameModeEnabled:YES];
}

- (void)disableActualGameMode:(id)sender {
    (void)sender;
    [self setActualGameModeEnabled:NO];
}

- (void)setRGBMode:(id)sender {
    NSMenuItem *item = [sender isKindOfClass:[NSMenuItem class]] ? (NSMenuItem *)sender : nil;
    NSInteger mode = item ? item.tag : -1;
    NSString *title = [item.representedObject isKindOfClass:[NSString class]] ? item.representedObject : item.title;
    self.rgbMode = ClampInteger(mode, 0, 31);
    [self saveRGBSettings];
    [self applyCurrentRGBSettingsWithTitle:title];
}

- (void)setRGBBrightness:(id)sender {
    NSMenuItem *item = [sender isKindOfClass:[NSMenuItem class]] ? (NSMenuItem *)sender : nil;
    self.rgbBrightness = ClampInteger(item ? item.tag : self.rgbBrightness, 1, 5);
    [self saveRGBSettings];
    [self applyCurrentRGBSettingsWithTitle:@"brightness"];
}

- (void)setRGBSpeed:(id)sender {
    NSMenuItem *item = [sender isKindOfClass:[NSMenuItem class]] ? (NSMenuItem *)sender : nil;
    self.rgbSpeed = ClampInteger(item ? item.tag : self.rgbSpeed, 1, 5);
    [self saveRGBSettings];
    [self applyCurrentRGBSettingsWithTitle:@"speed"];
}

- (void)setRGBDirection:(id)sender {
    NSMenuItem *item = [sender isKindOfClass:[NSMenuItem class]] ? (NSMenuItem *)sender : nil;
    self.rgbDirection = ClampInteger(item ? item.tag : self.rgbDirection, 0, 3);
    [self saveRGBSettings];
    [self applyCurrentRGBSettingsWithTitle:[NSString stringWithFormat:@"direction %@", RGBDirectionTitle(self.rgbDirection)]];
}

- (void)toggleRGBColorful:(id)sender {
    (void)sender;
    self.rgbColorful = !self.rgbColorful;
    [self saveRGBSettings];
    [self applyCurrentRGBSettingsWithTitle:self.rgbColorful ? @"colorful animation" : @"fixed color"];
}

- (void)setRGBColor:(id)sender {
    NSMenuItem *item = [sender isKindOfClass:[NSMenuItem class]] ? (NSMenuItem *)sender : nil;
    NSNumber *colorNumber = [item.representedObject respondsToSelector:@selector(integerValue)] ? item.representedObject : nil;
    self.rgbColor = ClampInteger(colorNumber ? [colorNumber integerValue] : (item ? item.tag : self.rgbColor), 0, 0xffffff);
    self.rgbColorful = NO;
    [self saveRGBSettings];
    [self applyCurrentRGBSettingsWithTitle:[NSString stringWithFormat:@"fixed color %@", RGBColorDisplayString(self.rgbColor)]];
}

- (void)chooseRGBColor:(id)sender {
    (void)sender;

    NSColorWell *colorWell = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 240, 42)];
    colorWell.color = NSColorFromRGBInteger(self.rgbColor);

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Aula F75 RGB color";
    alert.informativeText = @"Choose a fixed LED color.";
    alert.accessoryView = colorWell;
    [alert addButtonWithTitle:@"Apply"];
    [alert addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    [colorWell activate:YES];

    if ([alert runModal] != NSAlertFirstButtonReturn) {
        [colorWell deactivate];
        return;
    }

    [colorWell deactivate];
    self.rgbColor = ClampInteger(RGBIntegerFromNSColor(colorWell.color), 0, 0xffffff);
    self.rgbColorful = NO;
    [self saveRGBSettings];
    [self applyCurrentRGBSettingsWithTitle:[NSString stringWithFormat:@"custom color %@", RGBColorDisplayString(self.rgbColor)]];
}

- (void)selectKeyResponseLevel:(id)sender {
    NSMenuItem *item = [sender isKindOfClass:[NSMenuItem class]] ? (NSMenuItem *)sender : nil;
    self.keyResponseLevel = ClampInteger(item ? item.tag : self.keyResponseLevel, 1, 5);
    [self saveKeyResponseSettings];
    [self applyCurrentKeyResponseLevelWithTitle:KeyResponseLevelTitle(self.keyResponseLevel)];
}

- (void)selectSleepTime:(id)sender {
    NSMenuItem *item = [sender isKindOfClass:[NSMenuItem class]] ? (NSMenuItem *)sender : nil;
    self.sleepTime = ClampInteger(item ? item.tag : self.sleepTime, 0, 3);
    [self saveKeyResponseSettings];
    [self applyCurrentKeyResponseLevelWithTitle:[NSString stringWithFormat:@"Sleep %@", SleepTimeTitle(self.sleepTime)]];
}

- (void)syncScreenTime:(id)sender {
    (void)sender;
    NSString *message = nil;
    BOOL ok = SyncScreenTime(&message);
    self.lastScreenStatus = message ?: (ok ? @"Screen time synced" : @"Screen time sync failed");
    [self refresh:nil];
    [self showScreenResult:self.lastScreenStatus success:ok];
}

- (void)openScreenManager:(id)sender {
    (void)sender;
    if (!self.screenManager) {
        self.screenManager = [[ScreenManagerWindowController alloc] init];
        __weak typeof(self) weakSelf = self;
        self.screenManager.statusUpdateHandler = ^(NSString *status) {
            weakSelf.lastScreenStatus = status;
            [weakSelf refresh:nil];
        };
    }
    [self.screenManager showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)uploadRainbowBootAnimation:(id)sender {
    (void)sender;
    self.lastScreenStatus = @"Uploading rainbow screen test...";
    [self refresh:nil];
    NSString *message = nil;
    BOOL ok = UploadScreenBootAnimation(nil, 8, 255, nil, &message);
    self.lastScreenStatus = message ?: (ok ? @"Uploaded rainbow screen test" : @"Rainbow upload failed");
    [self refresh:nil];
    [self showScreenResult:self.lastScreenStatus success:ok];
}

- (void)uploadImageBootAnimation:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = NO;
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray arrayWithArray:@[
        UTTypePNG,
        UTTypeJPEG,
        UTTypeGIF,
        UTTypeBMP,
        UTTypeTIFF
    ]];
    UTType *webpType = [UTType typeWithFilenameExtension:@"webp"];
    if (webpType) {
        [contentTypes addObject:webpType];
    }
    panel.allowedContentTypes = contentTypes;

    if ([panel runModal] != NSModalResponseOK) {
        return;
    }

    self.lastScreenStatus = @"Uploading screen image/GIF...";
    [self refresh:nil];
    NSString *message = nil;
    BOOL ok = UploadScreenBootAnimationFromURL(panel.URL, &message);
    self.lastScreenStatus = message ?: (ok ? @"Uploaded screen image/GIF" : @"Image upload failed");
    [self refresh:nil];
    [self showScreenResult:self.lastScreenStatus success:ok];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--dump") == 0) {
                PrintDump();
                return 0;
            }
            if (strcmp(argv[i], "--upload-screen") == 0 && i + 1 < argc) {
                NSString *path = [NSString stringWithUTF8String:argv[i + 1]];
                NSString *message = nil;
                BOOL ok = UploadScreenBootAnimationFromURL([NSURL fileURLWithPath:path], &message);
                printf("%s\n", [message ?: (ok ? @"Upload complete" : @"Upload failed") UTF8String]);
                return ok ? 0 : 1;
            }
            if (strcmp(argv[i], "--upload-rainbow") == 0) {
                NSString *message = nil;
                BOOL ok = UploadScreenBootAnimation(nil, 8, 255, nil, &message);
                printf("%s\n", [message ?: (ok ? @"Upload complete" : @"Upload failed") UTF8String]);
                return ok ? 0 : 1;
            }
        }

        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
