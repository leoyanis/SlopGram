#import <substrate.h>
#import "InstagramHeaders.h"
#import "Tweak.h"
#import "Utils.h"

///////////////////////////////////////////////////////////

// * Tweak version *
NSString *SCIVersionString = @"SlopGram 1.0";

// Tweak setup
%hook IGInstagramAppDelegate
- (_Bool)application:(UIApplication *)application willFinishLaunchingWithOptions:(id)arg2 {
    // Keep the default Instagram navigation design
    [[NSUserDefaults standardUserDefaults] setValue:@(NO) forKey:@"instagram.override.project.lucent.navigation"];

    return %orig;
}
- (_Bool)application:(UIApplication *)application didFinishLaunchingWithOptions:(id)arg2 {
    %orig;

    NSLog(@"[SlopGram] Cleaning cache...");
    [SCIUtils cleanCache];

    return true;
}
%end

// Disable sending modded insta bug reports
%hook IGWindow
- (void)showDebugMenu {
    return;
}
%end

%hook IGBugReportUploader
- (id)initWithNetworker:(id)arg1
         pandoGraphQLService:(id)arg2
             analyticsLogger:(id)arg3
                userDefaults:(id)arg4
         launcherSetProvider:(id)arg5
shouldPersistLastBugReportId:(id)arg6
{
    return nil;
}
%end

/////////////////////////////////////////////////////////////////////////////

// Story tray ads
%hook IGMainStoryTrayDataSource
- (id)allItemsForTrayUsingCachedValue:(BOOL)cached {
    NSArray *originalObjs = %orig(cached);
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (IGStoryTrayViewModel *obj in originalObjs) {
        // "New!" account id is 3538572169
        if ([obj isKindOfClass:%c(IGStoryTrayViewModel)] && (obj.isUnseenNux == YES || [obj.pk isEqualToString:@"3538572169"])) {
            NSLog(@"[SlopGram] Removing ads: story tray");

            continue;
        }

        [filteredObjs addObject:obj];
    }

    return [filteredObjs copy];
}
%end
