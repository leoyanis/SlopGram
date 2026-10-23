// Fixes for things that break when Instagram is re-signed with someone else's developer account.
// Nothing here is about doomscrolling.
//
// - Login: Instagram keeps its session in keychain groups owned by Meta's team ("MH9GU9K5PX.*").
//   A re-signed app can't touch those, so every save fails and you're logged out on restart.
//   We drop the group from every keychain call, so items land in the app's own group.
// - App groups: same story for the shared "group.com.burbn.instagram" folder; we hand out a
//   private folder instead.
// - TestFlight nag: a re-signed app has a sandbox receipt, which Instagram reads as "TestFlight
//   build" and keeps asking you to update. We report a normal App Store receipt name and refuse
//   to show anything TestFlight-flavoured.
%config(generator=internal)

#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#include <string.h>

// MARK: Keychain

static OSStatus (*SGOrigItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*SGOrigItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*SGOrigItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*SGOrigItemDelete)(CFDictionaryRef);

static int SGKeychainRewrites = 0;

// Returns a +1 copy without the access group, or NULL if there was nothing to remove
static CFDictionaryRef SGWithoutGroup(CFDictionaryRef dict) {
    if (!dict || !CFDictionaryContainsKey(dict, kSecAttrAccessGroup)) return NULL;
    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dict);
    CFDictionaryRemoveValue(copy, kSecAttrAccessGroup);
    __atomic_add_fetch(&SGKeychainRewrites, 1, __ATOMIC_RELAXED);
    return copy;
}

static OSStatus SGItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    CFDictionaryRef fixed = SGWithoutGroup(attributes);
    OSStatus status = SGOrigItemAdd(fixed ?: attributes, result);
    if (fixed) CFRelease(fixed);
    return status;
}

static OSStatus SGItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    CFDictionaryRef fixed = SGWithoutGroup(query);
    OSStatus status = SGOrigItemCopyMatching(fixed ?: query, result);
    if (fixed) CFRelease(fixed);
    return status;
}

static OSStatus SGItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    CFDictionaryRef fixedQuery = SGWithoutGroup(query);
    CFDictionaryRef fixedAttributes = SGWithoutGroup(attributes);
    OSStatus status = SGOrigItemUpdate(fixedQuery ?: query, fixedAttributes ?: attributes);
    if (fixedQuery) CFRelease(fixedQuery);
    if (fixedAttributes) CFRelease(fixedAttributes);
    return status;
}

static OSStatus SGItemDelete(CFDictionaryRef query) {
    CFDictionaryRef fixed = SGWithoutGroup(query);
    OSStatus status = SGOrigItemDelete(fixed ?: query);
    if (fixed) CFRelease(fixed);
    return status;
}

// MARK: Symbol rebinding
//
// A stock iPhone won't let us patch code, but each image calls system functions through a table
// of pointers that we can rewrite (the fishhook technique). Only images inside the app bundle are
// touched; the originals come from dlsym, so lazy binding can never undo a rewrite.

struct SGRebinding {
    const char *name;
    void *replacement;
};

static const struct SGRebinding SGRebindings[] = {
    { "SecItemAdd", (void *)SGItemAdd },
    { "SecItemCopyMatching", (void *)SGItemCopyMatching },
    { "SecItemUpdate", (void *)SGItemUpdate },
    { "SecItemDelete", (void *)SGItemDelete },
};
static const size_t SGRebindingCount = sizeof(SGRebindings) / sizeof(SGRebindings[0]);

static void SGRebindSection(const struct section_64 *section, intptr_t slide, const struct nlist_64 *symtab,
                            const char *strtab, const uint32_t *indirect) {
    const uint32_t *indices = indirect + section->reserved1;
    void **slots = (void **)((uintptr_t)slide + section->addr);
    size_t count = section->size / sizeof(void *);

    for (size_t i = 0; i < count; i++) {
        uint32_t index = indices[i];
        if (index & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        const char *name = strtab + symtab[index].n_un.n_strx;
        if (name[0] != '_') continue;

        for (size_t r = 0; r < SGRebindingCount; r++) {
            if (strcmp(name + 1, SGRebindings[r].name) != 0) continue;
            if (slots[i] == SGRebindings[r].replacement) break;

            // __DATA_CONST is read-only once dyld is done with it
            vm_address_t page = (vm_address_t)&slots[i] & ~(vm_address_t)(vm_page_size - 1);
            kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, false,
                                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            if (kr == KERN_SUCCESS) {
                slots[i] = SGRebindings[r].replacement;
                if (strcmp(section->segname, "__DATA") != 0) {
                    vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ);
                }
            }
            break;
        }
    }
}

static void SGRebindImage(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname || !strstr(info.dli_fname, ".app/")) return;
    if (mh->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *header = (const struct mach_header_64 *)mh;

    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtabCmd = NULL;
    const struct dysymtab_command *dysymtabCmd = NULL;

    uintptr_t cursor = (uintptr_t)header + sizeof(*header);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT) == 0) {
            linkedit = (const struct segment_command_64 *)lc;
        } else if (lc->cmd == LC_SYMTAB) {
            symtabCmd = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtabCmd = (const struct dysymtab_command *)lc;
        }
        cursor += lc->cmdsize;
    }
    if (!linkedit || !symtabCmd || !dysymtabCmd || !dysymtabCmd->nindirectsyms) return;

    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(base + symtabCmd->symoff);
    const char *strtab = (const char *)(base + symtabCmd->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtabCmd->indirectsymoff);

    cursor = (uintptr_t)header + sizeof(*header);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        cursor += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)lc;
        // arm64 only: __AUTH_CONST holds signed pointers on arm64e, which Instagram doesn't ship
        if (strcmp(segment->segname, "__DATA") != 0 && strcmp(segment->segname, "__DATA_CONST") != 0) continue;

        const struct section_64 *sections = (const struct section_64 *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++) {
            uint32_t type = sections[s].flags & SECTION_TYPE;
            if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
                SGRebindSection(&sections[s], slide, symtab, strtab, indirect);
            }
        }
    }
}

// MARK: App groups

static NSURL *SGPrivateGroupFolder(NSString *group) {
    NSURL *library = [[NSFileManager defaultManager] URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *folder = [[library URLByAppendingPathComponent:@"SGAppGroups" isDirectory:YES]
                     URLByAppendingPathComponent:group isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return folder;
}

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)group {
    return group.length ? SGPrivateGroupFolder(group) : %orig(group);
}
%end

// MARK: TestFlight nag

static BOOL SGIsTestFlightNag(UIViewController *vc) {
    if ([NSStringFromClass([vc class]) rangeOfString:@"TestFlight" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([vc isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vc;
        NSString *text = [NSString stringWithFormat:@"%@ %@", alert.title ?: @"", alert.message ?: @""];
        if ([text rangeOfString:@"TestFlight" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

%hook NSBundle
- (NSURL *)appStoreReceiptURL {
    NSURL *url = %orig;
    if ([url.lastPathComponent isEqualToString:@"sandboxReceipt"]) {
        return [[url URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"receipt"];
    }
    return url;
}
%end

%hook UIViewController
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    if (vc && SGIsTestFlightNag(vc)) {
        if (completion) completion();
        return;
    }
    %orig(vc, animated, completion);
}
%end

%ctor {
    SGOrigItemAdd = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemAdd");
    SGOrigItemCopyMatching = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    SGOrigItemUpdate = (OSStatus (*)(CFDictionaryRef, CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemUpdate");
    SGOrigItemDelete = (OSStatus (*)(CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemDelete");
    if (SGOrigItemAdd && SGOrigItemCopyMatching && SGOrigItemUpdate && SGOrigItemDelete) {
        _dyld_register_func_for_add_image(SGRebindImage);
    }
    %init;
}

// For the simulator harness
extern "C" int SGKeychainRewriteCount(void) {
    return __atomic_load_n(&SGKeychainRewrites, __ATOMIC_RELAXED);
}
