#import "ObjCExceptionCatcher.h"

BOOL AVObjCTry(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            info[@"exceptionName"] = exception.name;
            *error = [NSError errorWithDomain:@"ObjCException" code:1 userInfo:info];
        }
        return NO;
    }
}
