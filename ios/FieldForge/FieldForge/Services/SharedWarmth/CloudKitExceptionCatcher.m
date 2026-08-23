#import "CloudKitExceptionCatcher.h"

BOOL FFCatchException(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            if (exception.reason) {
                info[NSLocalizedDescriptionKey] = exception.reason;
            }
            *error = [NSError errorWithDomain:exception.name ?: @"CKException"
                                         code:0
                                     userInfo:info];
        }
        return NO;
    }
}
