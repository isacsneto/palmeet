#import "ObjCExceptions.h"

BOOL PMCatchObjCException(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"app.palmeet.ObjCException"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason, @"name": exception.name}];
        }
        return NO;
    }
}
