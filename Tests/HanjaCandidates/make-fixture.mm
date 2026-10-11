#import <Foundation/Foundation.h>
#include <dlfcn.h>

// Isolated fixture creation only. Never opens the real user's dictionary.
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 5) return 2;
        NSURL *url = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) return 2;
        void *lib = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW | RTLD_LOCAL);
        if (!lib) return 2;
        auto package = (bool(*)(CFURLRef,CFDictionaryRef))dlsym(lib,"IDXCreateDictionaryPackage");
        auto create = (CFTypeRef(*)(CFAllocatorRef,CFURLRef,CFStringRef))dlsym(lib,"IDXCreateIndexObject");
        auto add = (uint32_t(*)(CFTypeRef,CFStringRef,CFDataRef,CFDictionaryRef))dlsym(lib,"IDXAddRecord");
        if (!package || !create || !add || !package((__bridge CFURLRef)url,NULL)) return 2;
        CFTypeRef index = create(NULL,(__bridge CFURLRef)url,NULL);
        if (!index) return 2;
        // Foundation Process uses filesystem representations for argv, which
        // can decompose Hangul. stdin lookup requests retain their exact form.
        NSString *key = [@(argv[2]) precomposedStringWithCanonicalMapping];
        NSString *candidate = [@(argv[3]) precomposedStringWithCanonicalMapping];
        NSString *record = strcmp(argv[4],"invalid") == 0 ? candidate : [NSString stringWithFormat:@"%@\t%@",key,candidate];
        NSData *data = [record dataUsingEncoding:NSUTF16BigEndianStringEncoding];
        uint32_t identifier = add(index,(__bridge CFStringRef)key,(__bridge CFDataRef)data,NULL);
        CFRelease(index);
        dlclose(lib);
        return identifier ? 0 : 2;
    }
}
